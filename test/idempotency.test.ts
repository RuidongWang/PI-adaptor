import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { IdempotencyStore, requestDigest } from "../src/server/idempotency.js";

it("retains recent results after 5000 completed writes and restart", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-retry-window-"));
  try {
    const createdAt = new Date(Date.now() - 5_000).toISOString();
    const records = Array.from({ length: 5000 }, (_, index) => ({ key: String(index), method: "turn/start", digest: "d", createdAt, state: "done", result: "original" }));
    await mkdir(join(root, "meta"));
    await writeFile(join(root, "meta/idempotency.json"), JSON.stringify({ version: 1, records }));
    const extra = vi.fn(async () => 1);
    await expect(new IdempotencyStore(root).run("new", "attachment/chunk", "c", extra)).rejects.toMatchObject({ code: "RATE_LIMITED" });
    expect(extra).not.toHaveBeenCalled();
    const work = vi.fn(async () => "duplicate");
    expect(await new IdempotencyStore(root).run("0", "turn/start", "d", work)).toBe("original");
    expect(work).not.toHaveBeenCalled();
  } finally { await rm(root, { recursive: true, force: true }); }
});

it.each(["done", "pending"])("rejects expired %s keys after capacity cleanup and restart without repeating work", async expiredState => {
  const root = await mkdtemp(join(tmpdir(), "pi-expired-key-"));
  const first = new IdempotencyStore(root);
  const restarted = new IdempotencyStore(root);
  try {
    const now = Date.now();
    const records = Array.from({ length: 5000 }, (_, index) => ({ key: String(index), deviceId: "owner", method: "turn/start", digest: "d", result: "done", state: index ? "done" : expiredState, createdAt: new Date(index ? now : now - 25 * 3_600_000).toISOString() }));
    await mkdir(join(root, "meta"));
    await writeFile(join(root, "meta/idempotency.json"), JSON.stringify({ version: 1, records }));
    await first.run("new", "turn/start", "d", async () => "accepted", "owner");
    first.close();
    const duplicate = vi.fn(async () => "duplicate");
    await expect(restarted.run("0", "turn/start", "d", duplicate, "owner")).rejects.toMatchObject({ code: "CONFLICT" });
    expect(duplicate).not.toHaveBeenCalled();
    expect(await restarted.run("0", "connection/revoke", "different", async () => true, "other")).toBe(true);
  } finally { first.close(); restarted.close(); await rm(root, { recursive: true, force: true }); }
});

it("lets an unrelated request finish while a slow request and its retry wait", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-adaptor-idempotency-"));
  const store = new IdempotencyStore(root);
  let complete!: (result: { completed: boolean }) => void;
  const gate = new Promise<{ completed: boolean }>((resolve) => { complete = resolve; });
  const slow = vi.fn(() => gate);
  const original = store.run("slow", "skill/install", "first", slow, "device");
  const retry = store.run("slow", "skill/install", "first", slow, "device");
  const quick = store.run("quick", "turn/start", "second", async () => ({ accepted: true }), "device", new Date(Date.now() + 25 * 3_600_000));
  let advanced = false;
  void quick.then(() => { advanced = true; }, () => undefined);
  try {
    await vi.waitFor(() => expect(advanced).toBe(true), { timeout: 500 });
    expect(slow).toHaveBeenCalledTimes(1);
  } finally {
    complete({ completed: true });
    await Promise.allSettled([original, retry, quick]);
    await rm(root, { recursive: true, force: true });
  }
  expect(await retry).toEqual({ completed: true });
  expect(slow).toHaveBeenCalledTimes(1);
});

describe("request digest redaction", () => {
  it("redacts top-level and nested api keys before hashing", () => {
    const topA = requestDigest({ sessionId: "s", apiKey: "key-a", input: { text: "hi" } });
    const topB = requestDigest({ sessionId: "s", apiKey: "key-b", input: { text: "hi" } });
    expect(topA).toBe(topB);
    // A request without the field is still a distinguishable request shape.
    expect(requestDigest({ sessionId: "s", input: { text: "hi" } })).not.toBe(topA);
    expect(requestDigest({ sessionId: "s", apiKey: "key-a", input: { text: "bye" } })).not.toBe(topA);

    const nestedA = requestDigest({ providerId: "p", provider: { name: "x", apiKey: "key-a" } });
    const nestedB = requestDigest({ providerId: "p", provider: { name: "x", apiKey: "key-b" } });
    expect(nestedA).toBe(nestedB);
    expect(requestDigest({ providerId: "p", provider: { name: "y", apiKey: "key-a" } })).not.toBe(nestedA);

    const arrayA = requestDigest({ providers: [{ apiKey: "key-a" }] });
    const arrayB = requestDigest({ providers: [{ apiKey: "key-b" }] });
    expect(arrayA).toBe(arrayB);
  });

  it("keeps excluding the retry-varying context", () => {
    const first = requestDigest({ sessionId: "s", input: { text: "hi" }, context: { requestId: "r1" } });
    const retry = requestDigest({ sessionId: "s", input: { text: "hi" }, context: { requestId: "r2" } });
    expect(first).toBe(retry);
    expect(first).not.toBe(requestDigest({ sessionId: "s", input: { text: "bye" } }));
  });
});
