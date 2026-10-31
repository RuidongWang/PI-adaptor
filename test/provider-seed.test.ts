import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ProviderStore } from "../src/providers/store.js";
import { applyProviderSeed, loadProviderSeed, parseProviderSeed } from "../src/providers/seed.js";

const ENTRY = {
  name: "DeepSeek",
  vendorKey: "test-deepseek-official",
  type: "openai_compatible",
  protocol: "openai_completions",
  baseUrl: "https://api.deepseek.com",
  authKind: "api_key",
  apiKey: "not-a-real-key",
  models: [
    {
      id: "deepseek-chat",
      displayName: "DeepSeek Chat",
      contextWindow: 128000,
      maxTokens: 8192,
      thinkingLevels: []
    }
  ]
};

describe("provider seed", () => {
  it("accepts an object with a providers array and fills model defaults", () => {
    const entries = parseProviderSeed({ providers: [ENTRY] });
    expect(entries).toHaveLength(1);
    const entry = entries[0]!;
    const model = entry.models[0]!;
    expect(entry.vendorKey).toBe(ENTRY.vendorKey);
    expect(model.defaultThinkingLevel).toBeNull();
    expect(model.supportsImages).toBe(false);
    expect(model.contextWindow).toBe(128000);
  });

  it("accepts a bare array", () => {
    expect(parseProviderSeed([ENTRY])).toHaveLength(1);
  });

  it("rejects an api_key provider without a key and a malformed shape", () => {
    const { apiKey: _apiKey, ...noKey } = ENTRY;
    expect(() => parseProviderSeed({ providers: [noKey] })).toThrow(/requires apiKey/);
    expect(() => parseProviderSeed({ nope: true })).toThrow(/expected a JSON array/);
  });

  it("creates providers then idempotently updates on re-seed", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-seed-"));
    const store = new ProviderStore(root, true);

    const first = await applyProviderSeed(store, parseProviderSeed({ providers: [ENTRY] }));
    expect(first).toEqual({ created: 1, updated: 0 });

    const provider = (await store.list())[0]!;
    expect(provider.hasApiKey).toBe(true);
    expect(await store.secret(provider.id)).toBe(ENTRY.apiKey);

    // Same file again: no duplicate, the record (and its secret) is updated in place.
    const rotatedKey = "sk-test-rotated";
    const renamed = { ...ENTRY, name: "DeepSeek Official", apiKey: rotatedKey };
    const second = await applyProviderSeed(store, parseProviderSeed({ providers: [renamed] }));
    expect(second).toEqual({ created: 0, updated: 1 });
    const list = await store.list();
    expect(list).toHaveLength(1);
    expect(list[0]!.id).toBe(provider.id);
    expect(list[0]!.name).toBe("DeepSeek Official");
    expect(await store.secret(provider.id)).toBe(rotatedKey);
  });

  it("fails loudly when the seed file is missing or not JSON", async () => {
    await expect(loadProviderSeed(join(tmpdir(), "pi-host-seed-does-not-exist.json"))).rejects.toThrow(
      /not readable/
    );
    const root = await mkdtemp(join(tmpdir(), "pi-host-seed-bad-"));
    const path = join(root, "bad.json");
    await writeFile(path, "{ not json", "utf8");
    await expect(loadProviderSeed(path)).rejects.toThrow(/not valid JSON/);
  });
});
