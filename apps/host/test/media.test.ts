import { createHash } from "node:crypto";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { BlobStore, MAX_IMAGE_BYTES } from "../src/media/blob-store.js";

describe("blob store", () => {
  it("preserves concurrent upload registrations", async () => {
    const store = new BlobStore(await mkdtemp(join(tmpdir(), "pi-adaptor-media-race-")));
    await store.init();
    const inputs = Array.from({ length: 4 }, (_, i) => store.create({ sessionId: "s", fileName: `${i}.png`, mimeType: "image/png", byteLength: 1, sha256: "0".repeat(64) }));
    const records = await Promise.all(inputs);
    await Promise.all(records.map((record) => store.appendChunk(record.id, 0, "YQ==")));
  });
  it("uploads, verifies, reads, and garbage-collects images", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-media-"));
    const store = new BlobStore(root);
    await store.init();
    const bytes = Buffer.from([0xff, 0xd8, 0xff, 0x01, 0x02, 0x03]);
    const hash = createHash("sha256").update(bytes).digest("hex");
    const created = await store.create({
      sessionId: "s1",
      fileName: "a.jpg",
      mimeType: "image/jpeg",
      byteLength: bytes.length,
      sha256: hash
    });
    expect(await store.appendChunk(created.id, 0, bytes.toString("base64"))).toBe(bytes.length);
    const ready = await store.complete(created.id, hash);
    expect(ready.state).toBe("ready");
    const read = await store.read(created.id, 0, 3);
    expect(Buffer.from(read.dataBase64, "base64").equals(bytes.subarray(0, 3))).toBe(true);
    expect(await store.gc(new Set([created.id]))).toBe(0);
    expect(await store.gc(new Set(), new Date(Date.now() + 25 * 60 * 60 * 1000))).toBe(1);
  });

  it("rejects oversized images and hash mismatch", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-media-"));
    const store = new BlobStore(root);
    await store.init();
    await expect(
      store.create({
        sessionId: "s1",
        fileName: "big.png",
        mimeType: "image/png",
        byteLength: MAX_IMAGE_BYTES + 1,
        sha256: "0".repeat(64)
      })
    ).rejects.toMatchObject({ code: "ATTACHMENT_INVALID" });
    const bytes = Buffer.from("abc");
    const hash = createHash("sha256").update(bytes).digest("hex");
    const created = await store.create({
      sessionId: "s1",
      fileName: "a.webp",
      mimeType: "image/webp",
      byteLength: 3,
      sha256: hash
    });
    await store.appendChunk(created.id, 0, bytes.toString("base64"));
    await expect(store.complete(created.id, "f".repeat(64))).rejects.toMatchObject({
      code: "ATTACHMENT_INVALID"
    });
  });

  it("imports output images and preserves blobs shared by another session", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-media-"));
    const store = new BlobStore(root);
    await store.init();
    const bytes = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x01, 0x02]);
    const encoded = bytes.toString("base64");
    const first = await store.importImageBase64({
      sessionId: "session-a",
      dataBase64: encoded,
      mimeType: "image/png",
      fileName: "output.png",
      kind: "output"
    });
    const duplicate = await store.importImageBase64({
      sessionId: "session-a",
      dataBase64: encoded,
      mimeType: "image/png",
      fileName: "duplicate.png",
      kind: "output"
    });
    expect(duplicate.id).toBe(first.id);
    const branch = await store.importImageBase64({
      sessionId: "session-b",
      dataBase64: encoded,
      mimeType: "image/png",
      fileName: "branch.png",
      kind: "output"
    });

    expect(await store.deleteSession("session-a")).toBe(1);
    const read = await store.read(branch.id, 0, bytes.length);
    expect(Buffer.from(read.dataBase64, "base64").equals(bytes)).toBe(true);
    expect(await store.deleteSession("session-b")).toBe(1);
    await expect(store.read(branch.id, 0, bytes.length)).rejects.toMatchObject({
      code: "NOT_FOUND"
    });
  });
});
