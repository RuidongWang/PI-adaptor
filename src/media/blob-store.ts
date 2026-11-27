import { createHash } from "node:crypto";
import { link, mkdir, open, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { HostError } from "../errors.js";
import { JsonCommitUncertainError, readJsonFile, syncDirectory, writeJsonFileAtomic } from "../util/json-file.js";
import { uuid } from "../util/id.js";

export type AttachmentRecord = {
  id: string;
  sessionId: string;
  kind: "input" | "output";
  fileName: string;
  mimeType: "image/jpeg" | "image/png" | "image/webp";
  byteLength: number;
  sha256: string;
  state: "uploading" | "ready" | "failed" | "deleted";
  createdAt: string;
  expiresAt?: string;
};

type MediaIndex = {
  version: 1;
  attachments: AttachmentRecord[];
};

const EMPTY: MediaIndex = { version: 1, attachments: [] };
export const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
export const MAX_STAGING_BYTES = 1024 * 1024 * 1024;
/// One attachment/read response must stay small enough for a single frame and
/// for the iOS client's chunk budget.
export const MAX_READ_CHUNK_BYTES = 1024 * 1024;

// sha256 直接用作 blob 文件名，必须严格限定为 64 位小写十六进制，
// 否则 `../../x` 之类的取值会让 rm/read 落到 blobs 目录之外。
const SHA256_HEX = /^[0-9a-f]{64}$/;

function isSha256Hex(value: unknown): value is string {
  return typeof value === "string" && SHA256_HEX.test(value);
}

function normalizeSha256(value: string): string {
  if (!isSha256Hex(value)) {
    throw new HostError("ATTACHMENT_INVALID", "sha256 must be 64 lowercase hex characters");
  }
  return value;
}

function validateMime(mime: string): asserts mime is AttachmentRecord["mimeType"] {
  if (!["image/jpeg", "image/png", "image/webp"].includes(mime)) {
    throw new HostError("ATTACHMENT_INVALID", "unsupported image type");
  }
}

export class BlobStore {
  private pending: Promise<void> = Promise.resolve();

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  private readonly index: string;
  private readonly staging: string;
  private readonly blobs: string;

  constructor(private readonly dataDir: string) {
    this.index = join(dataDir, "media", "index.json");
    this.staging = join(dataDir, "staging");
    this.blobs = join(dataDir, "media", "blobs");
  }

  async init(): Promise<void> {
    await mkdir(this.staging, { recursive: true, mode: 0o700 });
    await mkdir(this.blobs, { recursive: true, mode: 0o700 });
  }

  private async load(): Promise<MediaIndex> {
    const value = await readJsonFile<MediaIndex>(this.index, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported media index");
    return value;
  }

  private async save(value: MediaIndex): Promise<void> {
    await writeJsonFileAtomic(this.index, value, 0o600);
  }

  private partPath(id: string): string {
    return join(this.staging, `${id}.part`);
  }

  private blobPath(hash: string): string {
    return join(this.blobs, hash);
  }

  private async expireParts(index: MediaIndex, now: Date): Promise<number> {
    let expired = 0;
    for (const record of index.attachments) {
      if (!(record.state === "uploading" && record.expiresAt && Date.parse(record.expiresAt) <= now.getTime())) continue;
      await rm(this.partPath(record.id), { force: true });
      record.state = "failed";
      expired++;
    }
    return expired;
  }

  async expireUploads(now: Date): Promise<number> {
    return this.serialized(async () => {
      const index = await this.load();
      const expired = await this.expireParts(index, now);
      if (expired) await this.save(index);
      return expired;
    });
  }

  private async readyAttachment(id: string): Promise<AttachmentRecord> {
    const record = (await this.load()).attachments.find((entry) => entry.id === id && entry.state === "ready");
    if (!record || !isSha256Hex(record.sha256)) throw new HostError("NOT_FOUND", "attachment not found");
    return record;
  }

  async readForTurn(id: string, sessionId: string): Promise<{ mimeType: AttachmentRecord["mimeType"]; dataBase64: string }> {
    const record = await this.readyAttachment(id);
    if (record.sessionId !== sessionId) {
      throw new HostError("ATTACHMENT_INVALID", "attachment does not belong to session");
    }
    const path = this.blobPath(record.sha256);
    const checkSize = (size: number) => size === record.byteLength && size > 0 && size <= MAX_IMAGE_BYTES;
    if (!checkSize((await stat(path)).size)) throw new HostError("ATTACHMENT_INVALID", "attachment length changed");
    const bytes = await readFile(path);
    if (!checkSize(bytes.length) || createHash("sha256").update(bytes).digest("hex") !== record.sha256) {
      throw new HostError("ATTACHMENT_INVALID", "attachment checksum mismatch");
    }
    // Turn assembly uses the complete image. The RPC reader below still limits each frame.
    return { mimeType: record.mimeType, dataBase64: bytes.toString("base64") };
  }

  async create(
    input: {
      sessionId: string;
      fileName: string;
      mimeType: string;
      byteLength: number;
      sha256: string;
    },
    now = new Date()
  ): Promise<AttachmentRecord> {
    return this.serialized(async () => {
      validateMime(input.mimeType);
      if (!Number.isInteger(input.byteLength) || input.byteLength < 1 || input.byteLength > MAX_IMAGE_BYTES) {
        throw new HostError("ATTACHMENT_INVALID", "image exceeds 20 MiB or is empty");
      }
      const sha256 = normalizeSha256(input.sha256);
      const data = await this.load();
      // Expired uploads still occupy disk until GC. Purge them before measuring
      // the quota, and count every remaining staging file regardless of its
      // expiresAt so the budget reflects real disk usage.
      await this.expireParts(data, now);
      const stagingBytes = data.attachments
        .filter((entry) => entry.state === "uploading")
        .reduce((total, entry) => total + entry.byteLength, 0);
      if (stagingBytes + input.byteLength > MAX_STAGING_BYTES) {
        throw new HostError("PAYLOAD_TOO_LARGE", "staging quota exceeded");
      }
      const record: AttachmentRecord = {
        id: uuid(),
        sessionId: input.sessionId,
        kind: "input",
        fileName: input.fileName,
        mimeType: input.mimeType,
        byteLength: input.byteLength,
        sha256,
        state: "uploading",
        createdAt: now.toISOString(),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000).toISOString()
      };
      // Create the staging file before publishing the index entry. If either
      // step fails, roll the other back so a retry starts from a clean state.
      await writeFile(this.partPath(record.id), new Uint8Array(), { mode: 0o600 });
      data.attachments.push(record);
      try {
        await syncDirectory(this.staging);
        await this.save(data);
      } catch (error) {
        if (!(error instanceof JsonCommitUncertainError)) await rm(this.partPath(record.id), { force: true });
        throw error;
      }
      return record;
    });
  }

  async appendChunk(id: string, offset: number, dataBase64: string): Promise<number> {
    return this.serialized(async () => {
      const index = await this.load();
      const record = index.attachments.find((entry) => entry.id === id && entry.state === "uploading");
      if (!record) throw new HostError("ATTACHMENT_INCOMPLETE", "upload not found");
      if (record.expiresAt && Date.parse(record.expiresAt) <= Date.now()) {
        record.state = "failed";
        await this.save(index);
        await rm(this.partPath(id), { force: true });
        throw new HostError("ATTACHMENT_INCOMPLETE", "upload expired");
      }
      const chunk = Buffer.from(dataBase64, "base64");
      const part = await open(this.partPath(id), "r+");
      try {
        const { size } = await part.stat();
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > size || offset + chunk.length > record.byteLength) {
          throw new HostError("ATTACHMENT_INVALID", "invalid chunk range");
        }
        const overlap = Math.min(size - offset, chunk.length);
        if (overlap > 0) {
          const previous = Buffer.alloc(overlap);
          const { bytesRead } = await part.read(previous, 0, overlap, offset);
          if (bytesRead !== overlap || !previous.equals(chunk.subarray(0, overlap))) {
            throw new HostError("ATTACHMENT_INVALID", "conflicting chunk");
          }
        }
        for (let written = overlap; written < chunk.length;) {
          const { bytesWritten } = await part.write(chunk, written, chunk.length - written, offset + written);
          if (!bytesWritten) throw new Error("attachment write made no progress");
          written += bytesWritten;
        }
        return Math.max(size, offset + chunk.length);
      } finally {
        await part.close();
      }
    });
  }

  async complete(id: string, expectedSha256: string): Promise<AttachmentRecord> {
    return this.serialized(async () => {
      const index = await this.load();
      const record = index.attachments.find((entry) => entry.id === id);
      if (!record || (record.state !== "uploading" && record.state !== "ready")) {
        throw new HostError("ATTACHMENT_INCOMPLETE", "upload not found");
      }
      const expected = normalizeSha256(expectedSha256);
      if (record.state === "ready") {
        if (expected !== record.sha256 || (await stat(this.blobPath(expected))).size !== record.byteLength) {
          throw new HostError("ATTACHMENT_INVALID", "completed attachment does not match");
        }
        await syncDirectory(dirname(this.index));
        await rm(this.partPath(id), { force: true });
        return record;
      }
      if (record.expiresAt && Date.parse(record.expiresAt) <= Date.now()) {
        record.state = "failed";
        await this.save(index);
        await rm(this.partPath(id), { force: true });
        throw new HostError("ATTACHMENT_INCOMPLETE", "upload expired");
      }
      const bytes = await readFile(this.partPath(id));
      const actual = createHash("sha256").update(bytes).digest("hex");
      if (bytes.length !== record.byteLength || actual !== expected || actual !== record.sha256) {
        record.state = "failed";
        await this.save(index);
        await rm(this.partPath(id), { force: true });
        throw new HostError("ATTACHMENT_INVALID", "length or sha256 mismatch");
      }
      const destination = this.blobPath(actual);
      const part = await open(this.partPath(id), "r");
      try {
        await part.sync();
      } finally {
        await part.close();
      }
      let linked = false;
      try {
        try {
          await link(this.partPath(id), destination);
          linked = true;
        } catch (error) {
          if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
          if (!(await readFile(destination)).equals(bytes)) {
            throw new HostError("ATTACHMENT_INVALID", "existing blob checksum mismatch");
          }
        }
        // Keep both names until the ready index is durable. A restart can
        // continue from either index version after an uncertain commit.
        await syncDirectory(this.blobs);
        record.state = "ready";
        delete record.expiresAt;
        await this.save(index);
      } catch (error) {
        if (linked && !(error instanceof JsonCommitUncertainError)) {
          await rm(destination, { force: true }).catch(() => undefined);
        }
        throw error;
      }
      await rm(this.partPath(id), { force: true });
      return record;
    });
  }

  async read(id: string, offset: number, length: number): Promise<{
    attachment: AttachmentRecord;
    dataBase64: string;
    eof: boolean;
  }> {
    const record = await this.readyAttachment(id);
    if (!Number.isSafeInteger(offset) || offset < 0) {
      throw new HostError("INVALID_ARGUMENT", "offset must be a non-negative safe integer");
    }
    if (!Number.isSafeInteger(length) || length < 1 || length > MAX_READ_CHUNK_BYTES) {
      throw new HostError("INVALID_ARGUMENT", "length must be between 1 and the read chunk limit");
    }
    if (offset >= record.byteLength) {
      return { attachment: record, dataBase64: "", eof: true };
    }
    const file = await open(this.blobPath(record.sha256), "r");
    try {
      if ((await file.stat()).size !== record.byteLength) throw new HostError("ATTACHMENT_INVALID", "attachment length changed");
      const chunk = Buffer.alloc(Math.min(length, record.byteLength - offset));
      const { bytesRead } = await file.read(chunk, 0, chunk.length, offset);
      if (bytesRead !== chunk.length) throw new HostError("ATTACHMENT_INVALID", "attachment read was incomplete");
      return { attachment: record, dataBase64: chunk.toString("base64"), eof: offset + bytesRead === record.byteLength };
    } finally {
      await file.close();
    }
  }

  async importImageBase64(input: {
    sessionId: string;
    dataBase64: string;
    mimeType: string;
    fileName: string;
    kind: "input" | "output";
    now?: Date;
  }): Promise<AttachmentRecord> {
    return this.serialized(async () => {
      validateMime(input.mimeType);
      const bytes = Buffer.from(input.dataBase64, "base64");
      if (bytes.length < 1 || bytes.length > MAX_IMAGE_BYTES) {
        throw new HostError("ATTACHMENT_INVALID", "image exceeds 20 MiB or is empty");
      }
      const digest = createHash("sha256").update(bytes).digest("hex");
      const now = input.now ?? new Date();
      const data = await this.load();
      const existing = data.attachments.find(
        (entry) =>
          entry.sessionId === input.sessionId &&
          entry.sha256 === digest &&
          entry.kind === input.kind &&
          entry.state === "ready"
      );
      const destination = this.blobPath(digest);
      let valid = false;
      try {
        valid = (await stat(destination)).size === bytes.length && (await readFile(destination)).equals(bytes);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
      if (!valid) {
        const temporary = join(this.blobs, `.${uuid()}.tmp`);
        try {
          await writeFile(temporary, bytes, { mode: 0o600, flag: "wx", flush: true });
          await rename(temporary, destination);
          await syncDirectory(this.blobs);
        } finally { await rm(temporary, { force: true }); }
      }
      if (existing) return existing;
      const record: AttachmentRecord = {
        id: uuid(),
        sessionId: input.sessionId,
        kind: input.kind,
        fileName: input.fileName,
        mimeType: input.mimeType,
        byteLength: bytes.length,
        sha256: digest,
        state: "ready",
        createdAt: now.toISOString()
      };
      data.attachments.push(record);
      await this.save(data);
      return record;
    });
  }

  async deleteSession(sessionId: string): Promise<number> {
    return this.serialized(async () => {
      const data = await this.load();
      const hashes = new Set<string>();
      let removed = 0;
      for (const record of data.attachments) {
        if (record.sessionId !== sessionId) continue;
        hashes.add(record.sha256);
        if (record.state === "deleted") continue;
        if (record.state === "uploading") await rm(this.partPath(record.id), { force: true });
        record.state = "deleted";
        removed++;
      }
      await this.save(data);
      for (const hash of hashes) {
        // 历史索引里可能残留非法 sha256（早期版本未校验），绝不拿它拼路径删除。
        if (!isSha256Hex(hash)) continue;
        const stillReferenced = data.attachments.some(
          (entry) => entry.sha256 === hash && entry.state === "ready"
        );
        if (!stillReferenced) await rm(this.blobPath(hash), { force: true });
      }
      return removed;
    });
  }

  async gc(
    referencedIds: Set<string>,
    referencedHashesOrNow?: Set<string> | Date,
    maybeNow = new Date(),
    protectedSessions: ReadonlySet<string> = new Set()
  ): Promise<number> {
    const referencedHashes =
      referencedHashesOrNow instanceof Set ? referencedHashesOrNow : new Set<string>();
    const now = referencedHashesOrNow instanceof Date ? referencedHashesOrNow : maybeNow;
    return this.serialized(async () => {
      const index = await this.load();
      let removed = 0;
      for (const record of index.attachments) {
        if (record.state === "ready" && !protectedSessions.has(record.sessionId)) {
          const isReferenced = referencedIds.has(record.id) || referencedHashes.has(record.sha256);
          if (!isReferenced) {
            const age = now.getTime() - Date.parse(record.createdAt);
            if (age >= 24 * 60 * 60 * 1000) {
              record.state = "deleted";
              removed++;
            }
          }
        }
      }
      await this.save(index);

      // Clean up orphaned blobs on disk:
      // A blob is kept if ANY record in index with that sha256 is still "ready"
      // (whether referenced or still within protection window), or explicitly referenced by hash.
      const liveHashes = new Set(
        index.attachments.filter((a) => a.state === "ready" || protectedSessions.has(a.sessionId)).map((a) => a.sha256)
      );
      for (const hash of referencedHashes) {
        liveHashes.add(hash);
      }
      for (const record of index.attachments) {
        if (record.state === "deleted" && !liveHashes.has(record.sha256) && isSha256Hex(record.sha256)) {
          await rm(this.blobPath(record.sha256), { force: true });
        }
      }
      return removed;
    });
  }
}
