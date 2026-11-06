import { describe, expect, it } from "vitest";
import { requestDigest } from "../src/server/idempotency.js";

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
