import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ProviderStore } from "../src/providers/store.js";

describe("provider store", () => {
  it("preserves the default provider when deleting another and serializes creation", async () => {
    const store = new ProviderStore(await mkdtemp(join(tmpdir(), "pi-adaptor-provider-race-")), true);
    const input = { name: "mock", type: "openai_compatible", protocol: "openai_compatible", baseUrl: "https://example.com", authKind: "none" as const, models: [] };
    const [first, second] = await Promise.all([store.create({ ...input, vendorKey: "one" }), store.create({ ...input, vendorKey: "two" })]);
    await store.delete(second.id);
    expect((await store.list()).find((entry) => entry.id === first.id)?.isDefault).toBe(true);
  });
  it("stores secrets separately and masks them", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-provider-"));
    const store = new ProviderStore(root, true);
    const created = await store.create({
      name: "Mock",
      vendorKey: "mock",
      type: "openai_compatible",
      protocol: "openai_compatible",
      baseUrl: "https://example.com/v1",
      authKind: "api_key",
      apiKey: "sk-test-secret",
      models: []
    });
    expect(created.hasApiKey).toBe(true);
    expect(created.apiKey).toBeUndefined();
    expect(created.apiKeyMask).not.toContain("secret");
    expect(await store.secret(created.id)).toBe("sk-test-secret");
    expect(await readFile(join(root, "providers", "providers.json"), "utf8")).not.toContain("sk-test-secret");
    await store.delete(created.id);
    expect(await store.list()).toHaveLength(0);
    expect(await store.secret(created.id)).toBeNull();
  });

  it("updates every model while retaining the secret, default flag, and creation time", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-provider-update-"));
    const store = new ProviderStore(root, true);
    const created = await store.create({
      name: "Original", vendorKey: "original", type: "openai_compatible",
      protocol: "openai_compatible", baseUrl: "https://example.com/v1",
      authKind: "api_key", apiKey: "sk-test-update-secret", models: [
        { id: "first", displayName: "First", contextWindow: 100_000, maxTokens: 8_192,
          thinkingLevels: ["off", "low"], defaultThinkingLevel: "low", supportsImages: false },
        { id: "second", displayName: "Second", contextWindow: 64_000, maxTokens: 4_096,
          thinkingLevels: [], defaultThinkingLevel: null, supportsImages: true }
      ]
    }, new Date("2026-01-01T00:00:00Z"));
    const updated = await store.update(created.id, {
      name: "Updated", vendorKey: "original", type: "openai_compatible",
      protocol: "openai_compatible", baseUrl: "https://example.com/v2", authKind: "api_key",
      models: [
        { id: "next", displayName: "Next", contextWindow: 300_000, maxTokens: 24_000,
          thinkingLevels: ["off", "high"], defaultThinkingLevel: "high", supportsImages: true },
        { id: "mini", displayName: "Mini", contextWindow: 32_000, maxTokens: 2_048,
          thinkingLevels: [], defaultThinkingLevel: null, supportsImages: false }
      ]
    }, new Date("2026-01-02T00:00:00Z"));

    expect(updated.models.map((model) => model.id)).toEqual(["next", "mini"]);
    expect(updated.models[0]).toMatchObject({
      displayName: "Next", contextWindow: 300_000, maxTokens: 24_000,
      thinkingLevels: ["off", "high"], defaultThinkingLevel: "high", supportsImages: true
    });
    expect(updated.createdAt).toBe(created.createdAt);
    expect(updated.updatedAt).toBe("2026-01-02T00:00:00.000Z");
    expect(updated.isDefault).toBe(true);
    expect(updated.apiKey).toBeUndefined();
    expect(await store.secret(created.id)).toBe("sk-test-update-secret");
    expect(await readFile(join(root, "providers", "providers.json"), "utf8")).not.toContain("sk-test-update-secret");
  });
  it("rejects invalid auth combinations", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-provider-"));
    const store = new ProviderStore(root, true);
    await expect(
      store.create({
        name: "Mock",
        vendorKey: "mock",
        type: "openai_compatible",
        protocol: "openai_compatible",
        baseUrl: "https://example.com/v1",
        authKind: "api_key",
        models: []
      })
    ).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  });
});
