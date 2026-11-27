import { mkdir, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { sha256 } from "../util/id.js";
import { KeyedMutex } from "../util/keyed-mutex.js";

export type IdempotencyRecord = {
  key: string;
  deviceId?: string;
  method: string;
  /** Digest of the request params (context excluded) the key was first used with. */
  digest: string;
  result: unknown;
  createdAt: string;
  /**
   * `pending` is persisted before the side effect runs. If the process dies
   * between the side effect and writing the result, a retry finds `pending` and
   * must not execute again blindly.
   */
  state?: "pending" | "done";
};

type IdempotencyFile = { version: 1; records: IdempotencyRecord[] };

const EMPTY: IdempotencyFile = { version: 1, records: [] };
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;
const MAX_RECORDS = 5000;

/** Deterministic JSON encoding so two equivalent param objects share a digest. */
function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value) ?? "null";
  if (Array.isArray(value)) return `[${value.map((entry) => stableStringify(entry)).join(",")}]`;
  const entries = Object.entries(value as Record<string, unknown>)
    .filter(([, entry]) => entry !== undefined)
    .sort(([left], [right]) => (left < right ? -1 : left > right ? 1 : 0));
  return `{${entries.map(([key, entry]) => `${JSON.stringify(key)}:${stableStringify(entry)}`).join(",")}}`;
}

/**
 * Replace credential-bearing values before hashing. Provider keys are accepted
 * at `provider/create|update` (`provider.apiKey`) and `turn/start` (top-level
 * `apiKey`), and the digest itself is persisted in `meta/idempotency.json`: even
 * a hash of a secret is a secret-derived value, so every `apiKey` field becomes
 * a constant. Two requests that differ only by key therefore share an identity,
 * which is the intended idempotency semantics.
 */
function redactSecrets(value: unknown): unknown {
  if (Array.isArray(value)) return value.map((entry) => redactSecrets(entry));
  if (value === null || typeof value !== "object") return value;
  const redacted: Record<string, unknown> = {};
  for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
    redacted[key] = key === "apiKey" ? "[redacted]" : redactSecrets(entry);
  }
  return redacted;
}

/** Digest of the params with the retry-varying `context` removed. */
export function requestDigest(params: Record<string, unknown>): string {
  const { context: _context, ...rest } = params;
  return sha256(stableStringify(redactSecrets(rest)));
}

/**
 * JSON-safe projection of a response so it can be persisted and replayed.
 * Functions (e.g. a turn handle) are dropped; the persisted shape still carries
 * every contract field the client relies on.
 */
function persistable(value: unknown): unknown {
  return JSON.parse(
    JSON.stringify(value, (_key, entry) => (typeof entry === "function" ? undefined : entry))
  ) as unknown;
}

export class IdempotencyStore {
  private readonly path: string;
  private pending: Promise<void> = Promise.resolve();
  private readonly requests = new KeyedMutex();
  private expiredKeys: DatabaseSync | undefined;
  private cache: { data: IdempotencyFile; mtimeMs: number | null; size: number | null } | null = null;

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  constructor(dataDir: string) {
    this.path = join(dataDir, "meta", "idempotency.json");
  }

  private async expiryIndex(): Promise<DatabaseSync> {
    if (this.expiredKeys) return this.expiredKeys;
    const directory = dirname(this.path);
    await mkdir(directory, { recursive: true, mode: 0o700 });
    const index = new DatabaseSync(join(directory, "expired-idempotency.sqlite"));
    try {
      index.exec("CREATE TABLE IF NOT EXISTS expired (identity BLOB PRIMARY KEY) WITHOUT ROWID");
      this.expiredKeys = index;
      return index;
    } catch (error) { index.close(); throw error; }
  }

  close(): void { this.expiredKeys?.close(); this.expiredKeys = undefined; }

  private async fileStamp(): Promise<{ mtimeMs: number | null; size: number | null }> {
    try {
      const info = await stat(this.path);
      return { mtimeMs: info.mtimeMs, size: info.size };
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return { mtimeMs: null, size: null };
      throw error;
    }
  }

  private async load(): Promise<IdempotencyFile> {
    const stamp = await this.fileStamp();
    if (this.cache && this.cache.mtimeMs === stamp.mtimeMs && this.cache.size === stamp.size) {
      return this.cache.data;
    }
    const value = await readJsonFile<IdempotencyFile>(this.path, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported idempotency store");
    // Sanitize: results that carry plaintext credentials must never persist on
    // disk. `connection/rotate-token` returns a device token (`pdt2.`) and
    // `device/pairing-token` returns a pairing token (`ppt2.`); both are
    // dropped here, so a file written by an older build is scrubbed on load.
    value.records = value.records.filter(
      (record) =>
        record.method !== "connection/rotate-token" && record.method !== "device/pairing-token"
    );
    this.cache = { data: value, ...stamp };
    return value;
  }

  private async save(value: IdempotencyFile): Promise<void> {
    try {
      await writeJsonFileAtomic(this.path, value, 0o600);
      this.cache = { data: value, ...(await this.fileStamp()) };
    } catch (error) {
      this.cache = null;
      throw error;
    }
  }

  /**
   * Resolve a stored result for `key` scoped to `deviceId`, or run `work` once and remember it.
   * Reusing the key with a different method or params raises IDEMPOTENCY_CONFLICT;
   * retrying an expired key raises CONFLICT, matching contract §3.1.
   */
  async run<T>(
    key: string,
    method: string,
    digest: string,
    work: () => Promise<T>,
    deviceId?: string,
    now = new Date(),
    recoverPending?: () => Promise<T | undefined>
  ): Promise<T> {
    const matches = (record: IdempotencyRecord) => record.key === key && (record.deviceId ?? "") === (deviceId ?? "");
    return this.requests.run(JSON.stringify([deviceId ?? "", key]), async () => {
      const reservation = await this.serialized(async () => {
        const data = await this.load();
        const cutoff = now.getTime() - IDEMPOTENCY_TTL_MS;
        const existing = data.records.find(matches);
        if (existing) {
          if (Date.parse(existing.createdAt) < cutoff) throw new HostError("CONFLICT", "idempotency key expired");
          if (existing.method !== method || existing.digest !== digest) {
            throw new HostError("IDEMPOTENCY_CONFLICT", "idempotency key reused with different request");
          }
          return { existing };
        }
        const index = await this.expiryIndex();
        const identity = (device: string | undefined, requestKey: string) => Buffer.from(sha256(JSON.stringify([device ?? "", requestKey])), "hex");
        if (index.prepare("SELECT 1 FROM expired WHERE identity = ?").get(identity(deviceId, key))) {
          throw new HostError("CONFLICT", "idempotency key expired");
        }
        const expired = data.records.filter(record => Date.parse(record.createdAt) < cutoff &&
          !this.requests.has(JSON.stringify([record.deviceId ?? "", record.key])));
        if (expired.length) {
          index.exec("BEGIN IMMEDIATE");
          try {
            const insert = index.prepare("INSERT OR IGNORE INTO expired VALUES (?)");
            for (const record of expired) insert.run(identity(record.deviceId, record.key));
            index.exec("COMMIT");
          } catch (error) { index.exec("ROLLBACK"); throw error; }
          const archived = new Set(expired);
          data.records = data.records.filter(record => !archived.has(record));
        }
        if (method !== "connection/revoke" && data.records.filter(record => record.method !== "connection/revoke").length >= MAX_RECORDS) {
          throw new HostError("RATE_LIMITED", "Idempotency window is full; no action was performed");
        }
        data.records.push({ key, ...(deviceId ? { deviceId } : {}), method, digest, result: null, createdAt: now.toISOString(), state: "pending" });
        await this.save(data);
        return { existing: undefined };
      });
      const { existing } = reservation;
      if (existing && existing.state !== "pending") return existing.result as T;

      let result: T;
      try {
        if (existing) {
          const committed = await recoverPending?.();
          if (committed === undefined) {
            throw new HostError("CONFLICT", "previous attempt outcome is unknown; reconcile before retrying");
          }
          result = committed;
        } else {
          result = await work();
        }
      } catch (error) {
        if (!existing && error instanceof HostError && error.code !== "INTERNAL") {
          await this.serialized(async () => {
            const data = await this.load();
            data.records = data.records.filter((record) => !matches(record));
            await this.save(data);
          }).catch(() => undefined);
        }
        throw error;
      }
      await this.serialized(async () => {
        const data = await this.load();
        const record = data.records.find(matches);
        if (!record) throw new HostError("INTERNAL", "idempotency reservation is missing");
        record.result = persistable(result);
        record.state = "done";
        await this.save(data);
      });
      return result;
    });
  }
}
