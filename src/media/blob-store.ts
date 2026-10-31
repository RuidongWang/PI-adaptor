import { createHash } from "node:crypto";
import { mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
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
      const data = await this.load();
      const stagingBytes = data.attachments
        .filter((entry) => entry.state === "uploading" && entry.expiresAt && Date.parse(entry.expiresAt) > now.getTime())
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
        sha256: input.sha256,
        state: "uploading",
        createdAt: now.toISOString(),
        expiresAt: new Date(now.getTime() + 60 * 60 * 1000).toISOString()
      };
      data.attachments.push(record);
      await this.save(data);
      await writeFile(this.partPath(record.id), new Uint8Array(), { mode: 0o600 });
      return record;
    });
  }

  async appendChunk(id: string, offset: number, dataBase64: string): Promise<number> {
    return this.serialized(async () => {
      const index = await this.load();
      const record = index.attachments.find((entry) => entry.id === id && entry.state === "uploading");
      if (!record) throw new HostError("ATTACHMENT_INCOMPLETE", "upload not found");
      const chunk = Buffer.from(dataBase64, "base64");
      const current = await readFile(this.partPath(id));
      if (offset !== current.length) {
        if (offset < current.length && current.subarray(offset, offset + chunk.length).equals(chunk)) return current.length;
        throw new HostError("ATTACHMENT_INVALID", "non-contiguous chunk");
      }
      if (current.length + chunk.length > record.byteLength) {
        throw new HostError("ATTACHMENT_INVALID", "upload exceeds declared size");
      }
      await writeFile(this.partPath(id), Buffer.concat([current, chunk]), { mode: 0o600 });
      return current.length + chunk.length;
    });
  }

  async complete(id: string, expectedSha256: string): Promise<AttachmentRecord> {
    return this.serialized(async () => {
      const index = await this.load();
      const record = index.attachments.find((entry) => entry.id === id && entry.state === "uploading");
      if (!record) throw new HostError("ATTACHMENT_INCOMPLETE", "upload not found");
      const bytes = await readFile(this.partPath(id));
      const actual = createHash("sha256").update(bytes).digest("hex");
      if (bytes.length !== record.byteLength || actual !== expectedSha256 || actual !== record.sha256) {
        record.state = "failed";
        await this.save(index);
        await rm(this.partPath(id), { force: true });
        throw new HostError("ATTACHMENT_INVALID", "length or sha256 mismatch");
      }
      const destination = this.blobPath(actual);
      try {
        await stat(destination);
        await rm(this.partPath(id), { force: true });
      } catch {
        await rename(this.partPath(id), destination);
      }
      record.state = "ready";
      delete record.expiresAt;
      await this.save(index);
      return record;
    });
  }

  async read(id: string, offset: number, length: number): Promise<{
    attachment: AttachmentRecord;
    dataBase64: string;
    eof: boolean;
  }> {
    const record = (await this.load()).attachments.find((entry) => entry.id === id && entry.state === "ready");
    if (!record) throw new HostError("NOT_FOUND", "attachment not found");
    const bytes = await readFile(this.blobPath(record.sha256));
    const chunk = bytes.subarray(offset, Math.min(bytes.length, offset + Math.max(1, length)));
    return { attachment: record, dataBase64: chunk.toString("base64"), eof: offset + chunk.length >= bytes.length };
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
      if (existing) return existing;
  
      const destination = this.blobPath(digest);
      try {
        await stat(destination);
      } catch {
        await writeFile(destination, bytes, { mode: 0o600, flag: "wx" });
      }
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
        if (record.sessionId !== sessionId || record.state === "deleted") continue;
        hashes.add(record.sha256);
        if (record.state === "uploading") await rm(this.partPath(record.id), { force: true });
        record.state = "deleted";
        removed++;
      }
      await this.save(data);
      for (const hash of hashes) {
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
    maybeNow = new Date()
  ): Promise<number> {
    const referencedHashes =
      referencedHashesOrNow instanceof Set ? referencedHashesOrNow : new Set<string>();
    const now = referencedHashesOrNow instanceof Date ? referencedHashesOrNow : maybeNow;
    return this.serialized(async () => {
      const index = await this.load();
      let removed = 0;
      for (const record of index.attachments) {
        if (record.state === "uploading" && record.expiresAt && Date.parse(record.expiresAt) <= now.getTime()) {
          await rm(this.partPath(record.id), { force: true });
          record.state = "failed";
          removed++;
          continue;
        }
        if (record.state === "ready") {
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
        index.attachments.filter((a) => a.state === "ready").map((a) => a.sha256)
      );
      for (const hash of referencedHashes) {
        liveHashes.add(hash);
      }
      for (const record of index.attachments) {
        if (record.state === "deleted" && !liveHashes.has(record.sha256)) {
          await rm(this.blobPath(record.sha256), { force: true });
        }
      }
      return removed;
    });
  }
}
