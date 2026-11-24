import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import { IdempotencyStore, requestDigest } from "../src/server/idempotency.js";

it("lets an unrelated request finish while a slow request and its retry wait", async () => {
  const root = await mkdtemp(join(tmpdir(), "pi-adaptor-idempotency-"));
  const store = new IdempotencyStore(root);
  let complete!: (result: { completed: boolean }) => void;
  const gate = new Promise<{ completed: boolean }>((resolve) => { complete = resolve; });
  const slow = vi.fn(() => gate);
  const original = store.run("slow", "skill/install", "first", slow, "device");
  const retry = store.run("slow", "skill/install", "first", slow, "device");
  const quick = store.run("quick", "turn/start", "second", async () => ({ accepted: true }), "device");
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
