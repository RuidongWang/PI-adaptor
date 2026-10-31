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
