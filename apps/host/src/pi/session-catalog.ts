import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { join, relative, resolve } from "node:path";
import { SessionManager, type SessionEntry, type SessionHeader } from "@earendil-works/pi-coding-agent";
import { HostError } from "../errors.js";
import { sha256 } from "../util/id.js";

export type NativeSession = {
  id: string;
  path: string;
  cwd: string;
  title: string;
  messageCount: number;
  createdAt: string;
  updatedAt: string;
  readOnlyReason: string | null;
};

export type NativeWriteResult = {
  entryId: string;
  file: string;
  fingerprintBefore: string;
  fingerprintAfter: string;
};

async function walkJsonl(root: string): Promise<string[]> {
  const result: string[] = [];
  async function visit(path: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(path, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const child = join(path, entry.name);
      if (entry.isDirectory()) await visit(child);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) result.push(child);
    }
  }
  await visit(root);
  return result;
}

function titleFromEntries(entries: SessionEntry[], fallback: string): string {
  const info = [...entries].reverse().find((entry) => entry.type === "session_info" && entry.name);
  if (info && info.type === "session_info" && info.name) return info.name;
  const user = entries.find(
    (entry) => entry.type === "message" && (entry.message as { role?: string }).role === "user"
  );
  if (!user || user.type !== "message") return fallback;
  const content = (user.message as { content?: unknown }).content;
  if (typeof content === "string") return content.slice(0, 80);
  if (Array.isArray(content)) {
    const text = content.find((part) => (part as { type?: string }).type === "text") as
      | { text?: string }
      | undefined;
    if (text?.text) return text.text.slice(0, 80);
  }
  return fallback;
}

export class NativeSessionCatalog {
  constructor(private readonly roots: string[]) {}

  async scan(): Promise<NativeSession[]> {
    const paths = new Set<string>();
    for (const root of this.roots) {
      for (const path of await walkJsonl(resolve(root))) paths.add(path);
    }
    const sessions: NativeSession[] = [];
    for (const path of paths) {
      try {
        const manager = SessionManager.open(path);
        const header = manager.getHeader();
        if (!header || header.version !== 3) {
          sessions.push({
            id: path,
            path,
            cwd: header?.cwd ?? "",
            title: path,
            messageCount: 0,
            createdAt: new Date(0).toISOString(),
            updatedAt: new Date(0).toISOString(),
            readOnlyReason: "unsupported_session_version"
          });
          continue;
        }
        const fileStat = await stat(path);
        sessions.push({
          id: header.id,
          path,
          cwd: header.cwd,
          title: manager.getSessionName() ?? titleFromEntries(manager.getEntries(), header.id),
          messageCount: manager.getEntries().filter((entry) => entry.type === "message").length,
          createdAt: header.timestamp,
          updatedAt: fileStat.mtime.toISOString(),
          readOnlyReason: null
        });
      } catch {
        sessions.push({
          id: path,
          path,
          cwd: "",
          title: path,
          messageCount: 0,
          createdAt: new Date(0).toISOString(),
          updatedAt: new Date(0).toISOString(),
          readOnlyReason: "corrupt_or_unreadable"
        });
      }
    }
    return sessions.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  async open(sessionPath: string): Promise<SessionManager> {
    const manager = SessionManager.open(sessionPath);
    const header = manager.getHeader();
    if (!header || header.version !== 3) throw new HostError("SESSION_READ_ONLY", "unsupported session version");
    return manager;
  }

  async createFile(cwd: string, sessionDir: string, id: string, now = new Date()): Promise<string> {
    await mkdir(sessionDir, { recursive: true, mode: 0o700 });
    const stamp = now.toISOString().replace(/[:.]/g, "-");
    const path = join(sessionDir, `${stamp}_${id}.jsonl`);
    await writeFile(
      path,
      `${JSON.stringify({ type: "session", version: 3, id, timestamp: now.toISOString(), cwd })}\n`,
      { mode: 0o600, flag: "wx" }
    );
    return path;
  }

  /**
   * Append one entry and verify the write against the file identity captured
   * before it: same inode, grew by at least the new entry, and the old bytes are
   * still a byte-exact prefix. A mismatch means an external writer touched the
   * file, so the session goes read-only (contract §6.2 reasons).
   */
  private verifyAppend(
    beforeStat: { ino: number },
    beforeBytes: Buffer,
    afterStat: { ino: number },
    afterBytes: Buffer
  ): void {
    if (afterStat.ino !== beforeStat.ino) {
      throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
    }
    if (afterBytes.length <= beforeBytes.length) {
      throw new HostError("SESSION_READ_ONLY", "append_unverified");
    }
    if (!afterBytes.subarray(0, beforeBytes.length).equals(beforeBytes)) {
      throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
    }
  }

  async appendUserMessage(
    sessionPath: string,
    text: string,
    now = Date.now()
  ): Promise<NativeWriteResult> {
    const beforeStat = await stat(sessionPath);
    const beforeBytes = await readFile(sessionPath);
    const manager = await this.open(sessionPath);
    const entryId = manager.appendMessage({ role: "user", content: text, timestamp: now });
    const afterStat = await stat(sessionPath);
    const afterBytes = await readFile(sessionPath);
    this.verifyAppend(beforeStat, beforeBytes, afterStat, afterBytes);
    return {
      entryId,
      file: sessionPath,
      fingerprintBefore: sha256(beforeBytes),
      fingerprintAfter: sha256(afterBytes)
    };
  }

  async appendSessionInfo(sessionPath: string, title: string): Promise<string> {
    const beforeStat = await stat(sessionPath);
    const beforeBytes = await readFile(sessionPath);
    const manager = await this.open(sessionPath);
    const entryId = manager.appendSessionInfo(title);
    const afterStat = await stat(sessionPath);
    const afterBytes = await readFile(sessionPath);
    this.verifyAppend(beforeStat, beforeBytes, afterStat, afterBytes);
    return entryId;
  }

  async branch(sessionPath: string, fromEntryId: string): Promise<string> {
    const manager = await this.open(sessionPath);
    manager.branch(fromEntryId);
    const child = manager.createBranchedSession(fromEntryId);
    if (!child) throw new HostError("INTERNAL", "branch could not be created");
    return child;
  }

  async history(sessionPath: string): Promise<SessionEntry[]> {
    return (await this.open(sessionPath)).getEntries();
  }
}

export function nativeHeader(manager: SessionManager): SessionHeader | null {
  return manager.getHeader();
}

export function projectPathForSession(session: NativeSession): string {
  return session.cwd;
}

export function relativeSessionPath(root: string, path: string): string {
  return relative(resolve(root), resolve(path));
}
