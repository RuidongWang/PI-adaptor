import { join } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { sha256 } from "../util/id.js";

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
/** Keys older than this are forgotten; a retry after the window is a new request. */
export const IDEMPOTENCY_TTL_MS = 24 * 60 * 60 * 1000;

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

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  constructor(dataDir: string) {
    this.path = join(dataDir, "meta", "idempotency.json");
  }

  private async load(): Promise<IdempotencyFile> {
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
    return value;
  }

  private async save(value: IdempotencyFile): Promise<void> {
    await writeJsonFileAtomic(this.path, value, 0o600);
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
    now = new Date()
  ): Promise<T> {
    return this.serialized(async () => {
      const data = await this.load();
      const cutoff = now.getTime() - IDEMPOTENCY_TTL_MS;
      // Retain expired tombstones up to 7 days so expired retries raise CONFLICT
      // instead of being admitted as fresh requests (contract §3.1).
      const purgeCutoff = now.getTime() - 7 * 24 * 60 * 60 * 1000;
      data.records = data.records.filter((record) => Date.parse(record.createdAt) >= purgeCutoff);
      const existing = data.records.find(
        (record) => record.key === key && (record.deviceId ?? "") === (deviceId ?? "")
      );
      if (existing) {
        if (Date.parse(existing.createdAt) < cutoff) {
          throw new HostError("CONFLICT", "idempotency key expired");
        }
        if (existing.method !== method || existing.digest !== digest) {
          await this.save(data);
          throw new HostError("IDEMPOTENCY_CONFLICT", "idempotency key reused with different request");
        }
        if (existing.state === "pending") {
          // The previous attempt may have run its side effect before the result
          // was persisted. Never replay automatically; let the caller reconcile.
          throw new HostError("CONFLICT", "previous attempt outcome is unknown; reconcile before retrying");
        }
        return existing.result as T;
      }
      // Execute outside the store's serialisation is unsafe: two concurrent
      // identical requests must not both run. The store lock is the admission
      // point, so `work` runs while holding it.
      const pending: IdempotencyRecord = {
        key,
        ...(deviceId ? { deviceId } : {}),
        method,
        digest,
        result: null,
        createdAt: now.toISOString(),
        state: "pending"
      };
      data.records.push(pending);
      // Persist the reservation before running the side effect. A crash after
      // this point leaves a tombstone that blocks silent double execution.
      await this.save(data);
      let result: T;
      try {
        result = await work();
      } catch (error) {
        // A definite failure means the caller may retry; drop the reservation.
        data.records = data.records.filter((record) => record !== pending);
        await this.save(data).catch(() => undefined);
        throw error;
      }
      pending.result = persistable(result);
      pending.state = "done";
      await this.save(data);
      return result;
    });
  }
}
