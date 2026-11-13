import { createHash } from "node:crypto";
import { mkdir, readFile, readdir, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { HostError } from "../errors.js";
import { KeyedMutex } from "../util/keyed-mutex.js";
import { writeJsonFileAtomic } from "../util/json-file.js";
import { addDiagnostic, boundSnapshot, diagnostic, type ExtensionSnapshot, type SnapshotPair } from "./types.js";

const empty = (): SnapshotPair => ({ latestAttempt: null, previousCompleted: null });
function exact(value: unknown, keys: string[]): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
}
const text = (value: unknown, max = 256): value is string => typeof value === "string" && value.length <= max;
const date = (value: unknown): boolean => typeof value === "string" && Number.isFinite(Date.parse(value));
function diagnostics(value: unknown): boolean {
  return Array.isArray(value) && value.length <= 20 && value.every(item => exact(item, ["stage", "severity", "code", "message", "occurredAt"]) && ["validation", "load", "startup", "runtime", "cleanup"].includes(item.stage as string) && ["warning", "error"].includes(item.severity as string) && text(item.code) && text(item.message, 1024) && date(item.occurredAt));
}
function validSnapshot(value: unknown, sessionId: string): value is ExtensionSnapshot {
  if (!exact(value, ["id", "hostId", "sessionId", "turnId", "configRevision", "revision", "startedAt", "completedAt", "phase", "entries", "diagnostics"])) return false;
  if (![value.id, value.hostId, value.turnId, value.configRevision].every(item => text(item) && item.length > 0) || value.sessionId !== sessionId || !Number.isSafeInteger(value.revision) || (value.revision as number) < 1 || !["loading", "ready", "failed"].includes(value.phase as string) || !date(value.startedAt) || (value.phase === "loading" ? value.completedAt !== null : !date(value.completedAt)) || !diagnostics(value.diagnostics) || !Array.isArray(value.entries) || value.entries.length > 100 || Buffer.byteLength(JSON.stringify(value)) > 256 * 1024) return false;
  return value.entries.every(entry => exact(entry, ["id", "name", "configuredVersion", "loadState", "skipReason", "registeredTools", "activeTools", "registeredCommands", "mobileInvocable", "diagnostics"]) && text(entry.id, 64) && text(entry.name, 4096) && (entry.configuredVersion === null || text(entry.configuredVersion)) && ["loaded", "failed", "skipped"].includes(entry.loadState as string) && [null, "host-disabled", "entry-disabled", "not-adapted"].includes(entry.skipReason as string | null) && entry.mobileInvocable === false && diagnostics(entry.diagnostics) && [entry.registeredTools, entry.activeTools, entry.registeredCommands].every(names => Array.isArray(names) && names.length <= 200 && names.every(name => text(name))));
}
export class ExtensionSnapshotStore {
  readonly directory: string;
  private readonly locks = new KeyedMutex();
  constructor(dataDir: string) { this.directory = join(dataDir, "meta", "extensions"); }
  path(sessionId: string): string { return join(this.directory, `${createHash("sha256").update(sessionId).digest("hex")}.json`); }
  async get(sessionId: string): Promise<SnapshotPair> {
    try {
      const path = this.path(sessionId);
      if ((await stat(path)).size > 600 * 1024) throw new Error("oversize");
      const data: unknown = JSON.parse(await readFile(path, "utf8"));
      if (!exact(data, ["version", "sessionId", "latestAttempt", "previousCompleted"]) || data.version !== 1 || data.sessionId !== sessionId) throw new Error("invalid envelope");
      for (const snapshot of [data.latestAttempt, data.previousCompleted]) if (snapshot !== null && !validSnapshot(snapshot, sessionId)) throw new Error("invalid snapshot");
      if (data.previousCompleted !== null && (data.previousCompleted as ExtensionSnapshot).completedAt === null) throw new Error("incomplete history");
      return { latestAttempt: data.latestAttempt as ExtensionSnapshot | null, previousCompleted: data.previousCompleted as ExtensionSnapshot | null };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return empty();
      throw new HostError("INTERNAL", "Extension snapshot is unreadable or corrupt.");
    }
  }
  async put(input: ExtensionSnapshot): Promise<ExtensionSnapshot | null> {
    return this.locks.run(input.sessionId, async () => {
      const pair = await this.get(input.sessionId), current = pair.latestAttempt;
      if (current?.id === input.id && current.revision >= input.revision) return null;
      if (current && current.id !== input.id) {
        if (input.revision !== 1) return null;
        if (current.completedAt !== null) pair.previousCompleted = current;
      }
      const snapshot = boundSnapshot(input);
      if (!validSnapshot(snapshot, input.sessionId)) throw new HostError("INTERNAL", "Invalid extension snapshot update.");
      pair.latestAttempt = snapshot;
      await this.write(input.sessionId, pair);
      return snapshot;
    });
  }
  private async write(sessionId: string, pair: SnapshotPair) {
    try { await writeJsonFileAtomic(this.path(sessionId), { version: 1, sessionId, ...pair }, 0o600); }
    catch { throw new HostError("INTERNAL", "Could not persist extension snapshot."); }
  }
  async delete(sessionId: string): Promise<void> {
    try { await this.locks.run(sessionId, () => rm(this.path(sessionId), { force: true })); }
    catch { throw new HostError("INTERNAL", "Could not delete extension snapshot."); }
  }
  async recover(sessionIds: Set<string>): Promise<void> {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const live = new Map([...sessionIds].map(id => [this.path(id).split("/").pop()!, id]));
    for (const file of await readdir(this.directory)) {
      if (!/^[a-f0-9]{64}\.json$/.test(file)) continue;
      const sessionId = live.get(file);
      if (!sessionId) { await rm(join(this.directory, file), { force: true }); continue; }
      const pair = await this.get(sessionId), latest = pair.latestAttempt;
      if (latest?.phase === "loading") {
        latest.phase = "failed"; latest.revision += 1; latest.completedAt = new Date().toISOString();
        addDiagnostic(latest.diagnostics, diagnostic("startup", "AGENT_RESTARTED", "Host restarted before extension initialization completed."));
        pair.latestAttempt = boundSnapshot(latest);
        await this.write(sessionId, pair);
      }
    }
  }
}
