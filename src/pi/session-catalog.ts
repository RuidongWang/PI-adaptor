import { createHash } from "node:crypto";
import { closeSync, constants, fstatSync, fsyncSync, lstatSync, openSync, readFileSync, readSync, realpathSync, statSync, unlinkSync, writeSync, type BigIntStats } from "node:fs";
import { mkdir, open, readdir, readFile, realpath, stat, writeFile } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { SessionManager, type FileEntry, type SessionEntry, type SessionHeader } from "@earendil-works/pi-coding-agent";
import { HostError } from "../errors.js";
import { publicAssistantMessage } from "../providers/runtime.js";
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

function sameVersion(left: BigIntStats, right: BigIntStats): boolean {
  return left.dev === right.dev && left.ino === right.ino && left.size === right.size
    && left.mtimeNs === right.mtimeNs && left.ctimeNs === right.ctimeNs;
}

export function messageText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => (part as { text?: unknown } | null)?.text)
    .filter((text): text is string => typeof text === "string")
    .join("");
}

async function readSession(path: string) {
  const canonical = await realpath(path);
  const file = await open(canonical, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  let bytes: Buffer;
  let version: BigIntStats;
  try {
    version = await file.stat({ bigint: true });
    if (!version.isFile()) throw new HostError("SESSION_READ_ONLY", "lease_unavailable");
    bytes = await file.readFile();
    if (!sameVersion(version, await file.stat({ bigint: true })) || BigInt(bytes.length) !== version.size
        || !sameVersion(version, await stat(path, { bigint: true }))) {
      throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
    }
  } finally {
    await file.close();
  }
  const entries: FileEntry[] = [];
  let incomplete = bytes.length === 0 || bytes[bytes.length - 1] !== 10;
  const ids = new Set<string>();
  for (const line of bytes.toString("utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const entry = JSON.parse(line) as FileEntry;
      if (!entry || typeof entry.type !== "string" || typeof entry.id !== "string" || !entry.id) throw new Error();
      if (entries.length === 0) {
        if (entry.type !== "session" || typeof entry.cwd !== "string" || typeof entry.timestamp !== "string") throw new Error();
      } else {
        if (entry.type === "session" || ids.has(entry.id) || (entry.parentId !== null && !ids.has(entry.parentId))) throw new Error();
        if (entry.type === "message" && (!entry.message || typeof entry.message.role !== "string")) throw new Error();
        ids.add(entry.id);
      }
      entries.push(entry);
    } catch {
      incomplete = true;
      if (entries.length === 0) break;
    }
  }
  const header = entries[0] as SessionHeader | undefined;
  const readOnlyReason = !header || incomplete ? "append_unverified"
    : header.version !== 3 ? "unsupported_session_version" : null;
  return { canonical, bytes, version, header, entries, readOnlyReason };
}

function syncDirectory(path: string): void {
  const directory = openSync(dirname(path), constants.O_RDONLY);
  try { fsyncSync(directory); } finally { closeSync(directory); }
}

function hashPrefix(fd: number, size: number, buffer: Buffer): string {
  const hash = createHash("sha256");
  for (let offset = 0; offset < size;) {
    const count = readSync(fd, buffer, 0, Math.min(buffer.length, size - offset), offset);
    if (count === 0) throw new HostError("SESSION_READ_ONLY", "append_unverified");
    hash.update(buffer.subarray(0, count));
    offset += count;
  }
  return hash.digest("hex");
}

export async function openNativeSessionForWrite(path: string, expectedId?: string): Promise<SessionManager> {
  let source: Awaited<ReturnType<typeof readSession>>;
  try {
    source = await readSession(path);
  } catch (error) {
    if (error instanceof HostError) throw error;
    throw new HostError("SESSION_READ_ONLY", "lease_unavailable");
  }
  if (!source.header || source.readOnlyReason) {
    throw new HostError("SESSION_READ_ONLY", source.readOnlyReason ?? "append_unverified");
  }
  if (expectedId !== undefined && source.header.id !== expectedId) {
    throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
  }
  const { canonical } = source;
  const manager = SessionManager.inMemory(source.header.cwd, undefined, source.entries);
  const prefix = createHash("sha256").update(source.bytes);
  const buffer = Buffer.alloc(64 * 1024);
  let expected = source.version;
  let leaf = manager.getLeafId();
  let failure: HostError | undefined;
  manager.getSessionFile = () => canonical;
  // The Host serializes its writers. Native Pi can write independently of that lock.
  manager._persist = (entry) => {
    if (failure) throw failure;
    let fd: number | undefined;
    try {
      if (entry.parentId !== leaf || realpathSync(path) !== canonical) {
        throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
      }
      fd = openSync(canonical, constants.O_RDWR | constants.O_APPEND | constants.O_NOFOLLOW | constants.O_NONBLOCK);
      if (!sameVersion(fstatSync(fd, { bigint: true }), expected)
          || hashPrefix(fd, Number(expected.size), buffer) !== prefix.copy().digest("hex")
          || !sameVersion(statSync(path, { bigint: true }), expected)) {
        throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
      }
      const line = Buffer.from(`${JSON.stringify(entry)}\n`);
      if (writeSync(fd, line) !== line.length) throw new HostError("SESSION_READ_ONLY", "append_unverified");
      fsyncSync(fd);
      syncDirectory(canonical);
      const after = fstatSync(fd, { bigint: true });
      prefix.update(line);
      if (after.size !== expected.size + BigInt(line.length)
          || hashPrefix(fd, Number(after.size), buffer) !== prefix.copy().digest("hex")
          || !sameVersion(after, statSync(path, { bigint: true }))) {
        throw new HostError("SESSION_READ_ONLY", "append_unverified");
      }
      expected = after;
      leaf = entry.id;
    } catch (error) {
      failure = error instanceof HostError ? error : new HostError("SESSION_READ_ONLY", "append_unverified");
      throw failure;
    } finally {
      if (fd !== undefined) closeSync(fd);
    }
  };
  return manager;
}

const MAX_CACHED_TEXT_BYTES = 32 * 1024 * 1024;
const MAX_CACHED_TEXT_ITEMS = 16;

export class NativeSessionCatalog {
  private readonly textCache = new Map<string, { sessionId: string; version: BigIntStats; body: Buffer }>();
  private cachedTextBytes = 0;

  constructor(private readonly roots: string[]) {}

  async scan(): Promise<NativeSession[]> {
    const paths = new Set<string>();
    for (const root of this.roots) {
      for (const path of await walkJsonl(resolve(root))) paths.add(path);
    }
    const sessions: NativeSession[] = [];
    for (const path of paths) {
      try {
        const { header, entries, version, readOnlyReason } = await readSession(path);
        const manager = header?.version === 3 ? SessionManager.inMemory(header.cwd, undefined, entries) : undefined;
        const messages = manager?.getEntries() ?? [];
        sessions.push({
          id: header?.id ?? path,
          path,
          cwd: header?.cwd ?? "",
          title: manager?.getSessionName() ?? titleFromEntries(messages, header?.id ?? path),
          messageCount: messages.filter((entry) => entry.type === "message").length,
          createdAt: header?.timestamp ?? new Date(0).toISOString(),
          updatedAt: version.mtime.toISOString(),
          readOnlyReason
        });
      } catch (error) {
        if (error instanceof HostError && error.message === "external_write_conflict") continue;
        sessions.push({
          id: path,
          path,
          cwd: "",
          title: path,
          messageCount: 0,
          createdAt: new Date(0).toISOString(),
          updatedAt: new Date(0).toISOString(),
          readOnlyReason: "lease_unavailable"
        });
      }
    }
    return sessions.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt));
  }

  async createFile(cwd: string, sessionDir: string, id: string, now = new Date()): Promise<string> {
    await mkdir(sessionDir, { recursive: true, mode: 0o700 });
    const stamp = now.toISOString().replace(/[:.]/g, "-");
    const path = join(sessionDir, `${stamp}_${id}.jsonl`);
    await writeFile(
      path,
      `${JSON.stringify({ type: "session", version: 3, id, timestamp: now.toISOString(), cwd })}\n`,
      { mode: 0o600, flag: "wx", flush: true }
    );
    syncDirectory(path);
    return path;
  }

  async appendUserMessage(
    sessionPath: string,
    text: string,
    now = Date.now(),
    expectedId?: string
  ): Promise<NativeWriteResult> {
    const beforeBytes = await readFile(sessionPath);
    const manager = await openNativeSessionForWrite(sessionPath, expectedId);
    const entryId = manager.appendMessage({ role: "user", content: text, timestamp: now });
    return {
      entryId,
      file: sessionPath,
      fingerprintBefore: sha256(beforeBytes),
      fingerprintAfter: sha256(readFileSync(sessionPath))
    };
  }

  async appendSessionInfo(sessionPath: string, title: string, expectedId?: string): Promise<string> {
    return (await openNativeSessionForWrite(sessionPath, expectedId)).appendSessionInfo(title);
  }

  async branch(sessionPath: string, fromEntryId: string, expectedId?: string): Promise<string> {
    const manager = await openNativeSessionForWrite(sessionPath, expectedId);
    if (!manager.getEntry(fromEntryId)) throw new HostError("NOT_FOUND", "branch item not found");
    manager.createBranchedSession(fromEntryId);
    const header = { ...manager.getHeader()!, parentSession: sessionPath };
    const child = join(dirname(sessionPath), `${header.timestamp.replace(/[:.]/g, "-")}_${header.id}.jsonl`);
    const entries = [header, ...manager.getEntries()];
    await writeFile(child, entries.map((entry) => `${JSON.stringify(entry)}\n`).join(""), { mode: 0o600, flag: "wx", flush: true });
    syncDirectory(child);
    return child;
  }

  async history(sessionPath: string, expectedId?: string): Promise<SessionEntry[]> {
    return (await this.historySnapshot(sessionPath, expectedId)).entries;
  }

  private async historySnapshot(sessionPath: string, expectedId?: string): Promise<{ entries: SessionEntry[]; version: BigIntStats }> {
    const { header, entries, version } = await readSession(sessionPath);
    if (header?.version !== 3) throw new HostError("SESSION_READ_ONLY", "unsupported_session_version");
    if (expectedId !== undefined && header.id !== expectedId) {
      throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
    }
    return { entries: entries.slice(1) as SessionEntry[], version };
  }

  async historyTextChunk(sessionPath: string, sessionId: string, itemId: string, offset: number, length: number) {
    const key = JSON.stringify([sessionPath, sessionId, itemId]);
    const cached = this.textCache.get(key);
    let entry: NonNullable<typeof cached>;
    if (cached && sameVersion(cached.version, await stat(sessionPath, { bigint: true }))) {
      entry = cached;
    } else {
      const { entries, version } = await this.historySnapshot(sessionPath, sessionId);
      const item = entries.find((candidate) => candidate.type === "message" && candidate.id === itemId)
        ?? entries.findLast((candidate) => candidate.type === "message"
          && candidate.message.role === "toolResult" && candidate.message.toolCallId === itemId);
      if (!item || item.type !== "message") throw new HostError("NOT_FOUND", "history item no longer exists");
      const message = item.message.role === "assistant" ? publicAssistantMessage(item.message) : item.message;
      const body = Buffer.from(messageText("content" in message ? message.content : undefined), "utf8");
      entry = { sessionId, version, body };
    }
    const { body } = entry;
    if (offset > body.length) throw new HostError("INVALID_ARGUMENT", "textRange.offset exceeds the body length");
    this.dropCachedText(key);
    if (body.length > length && body.length <= MAX_CACHED_TEXT_BYTES) {
      while (this.textCache.size >= MAX_CACHED_TEXT_ITEMS || this.cachedTextBytes + body.length > MAX_CACHED_TEXT_BYTES) {
        this.dropCachedText(this.textCache.keys().next().value!);
      }
      this.textCache.set(key, entry);
      this.cachedTextBytes += body.length;
    }
    return { dataBase64: body.subarray(offset, offset + length).toString("base64"), totalBytes: body.length };
  }

  private dropCachedText(key: string): void {
    const cached = this.textCache.get(key);
    if (!cached) return;
    this.textCache.delete(key);
    this.cachedTextBytes -= cached.body.length;
  }

  async deleteFile(sessionPath: string, sessionId: string): Promise<void> {
    // A retry after a successful unlink must still be able to clean sidecars.
    let version: BigIntStats;
    try {
      version = lstatSync(sessionPath, { bigint: true });
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return;
      throw new HostError("SESSION_READ_ONLY", "lease_unavailable");
    }
    try {
      if (!version.isFile()) throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
      const source = await readSession(sessionPath);
      if (source.header?.id !== sessionId || !sameVersion(version, source.version)
          || !sameVersion(version, lstatSync(sessionPath, { bigint: true }))) {
        throw new HostError("SESSION_READ_ONLY", "external_write_conflict");
      }
      // Keep the final identity check adjacent to unlink; external Pi writers
      // do not acquire the Host's per-session mutex.
      unlinkSync(sessionPath);
    } catch (error) {
      if (error instanceof HostError) throw error;
      throw new HostError("SESSION_READ_ONLY", "lease_unavailable");
    }
  }

  forgetHistoryText(sessionId: string): void {
    for (const [key, entry] of this.textCache) {
      if (entry.sessionId === sessionId) this.dropCachedText(key);
    }
  }

  async historyForAttach(sessionPath: string, expectedId: string): Promise<{ entries: SessionEntry[]; readOnlyReason: string | null }> {
    try {
      const { header, entries, readOnlyReason } = await readSession(sessionPath);
      if (header && header.id !== expectedId) return { entries: [], readOnlyReason: "external_write_conflict" };
      return { entries: header?.version === 3 ? entries.slice(1) as SessionEntry[] : [], readOnlyReason };
    } catch (error) {
      return { entries: [], readOnlyReason: error instanceof HostError ? error.message : "lease_unavailable" };
    }
  }
}
