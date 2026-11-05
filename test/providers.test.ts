import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
import type { ProviderDiscoveryRequest, ProviderDiscoveryTestOnly } from "../src/providers/discovery.js";
import { ProviderStore } from "../src/providers/store.js";
import { HostService, type AuthContext } from "../src/server/host-service.js";

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

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

function makeDiscoveryHarness() {
  const requests: ProviderDiscoveryRequest[] = [];
  let statusCode = 200;
  let body = JSON.stringify({ data: [{ id: "model-b" }, { id: "model-a" }] });
  const testOnly: ProviderDiscoveryTestOnly = {
    lookup: async () => [{ address: "8.8.8.8" }],
    connect: async (options, validateRemoteAddress) => {
      validateRemoteAddress("8.8.8.8");
      return {
        remoteAddress: "8.8.8.8",
        request: async (request) => {
          requests.push(request);
          return {
            statusCode,
            headers: {},
            body: Readable.from([body]),
            close: vi.fn()
          };
        },
        close: vi.fn()
      };
    }
  };
  return {
    requests,
    testOnly,
    setStatus(value: number) { statusCode = value; },
    setBody(value: string) { body = value; }
  };
}

async function makeDiscoveryService() {
  const root = await mkdtemp(join(tmpdir(), "pi-adaptor-test-discovery-service-"));
  const harness = makeDiscoveryHarness();
  const config = parseHostConfig([
    "--data-dir", join(root, "data"),
    "--agent-dir", join(root, "agent")
  ], {}, root);
  await ensureHostDirectories(config);
  const service = new HostService(config, new DeterministicAgentDriver(), { testOnly: harness.testOnly });
  await service.init();
  const pairing = await service.createPairingToken();
  const paired = await service.tokens.pair(pairing.token, "discovery-owner");
  const auth = { device: await service.tokens.authenticate(paired.deviceToken) } satisfies AuthContext;
  return { root, config, service, harness, auth, paired };
}

async function persistedText(path: string): Promise<string> {
  let output = "";
  for (const entry of await readdir(path, { withFileTypes: true })) {
    const child = join(path, entry.name);
    if (entry.isDirectory()) output += await persistedText(child);
    else if (entry.isFile()) output += await readFile(child, "utf8");
  }
  return output;
}

describe("HostService provider/discover", () => {
  it("resolves saved providers, preserves authKind none, and returns normalized models", async () => {
    const { service, harness, auth } = await makeDiscoveryService();
    const saved = await service.providers.create({
      name: "Saved", vendorKey: "saved", type: "openai_compatible", protocol: "openai_compatible",
      baseUrl: "https://provider.unit/v1", authKind: "api_key", apiKey: "saved-secret", models: []
    });
    const none = await service.providers.create({
      name: "None", vendorKey: "none", type: "openai_compatible", protocol: "openai_compatible",
      baseUrl: "https://provider.unit/v2", authKind: "none", models: []
    });
    const result = await service.handle("provider/discover", {
      providerId: saved.id,
      context: { requestId: "req_saved" }
    }, auth) as { models: Array<{ id: string }> };
    expect(result.models.map((model) => model.id)).toEqual(["model-a", "model-b"]);
    expect(result).not.toHaveProperty("baseUrl");
    expect(result).not.toHaveProperty("apiKey");
    expect(harness.requests[0]?.path).toBe("/v1/models");
    expect(harness.requests[0]?.headers.Authorization).toBe("Bearer saved-secret");

    await service.handle("provider/discover", { providerId: none.id }, auth);
    expect(harness.requests[1]?.path).toBe("/v2/models");
    expect(harness.requests[1]?.headers).not.toHaveProperty("Authorization");
  });

  it("uses an ad-hoc key only in memory without provider or idempotency persistence", async () => {
    const { service, harness, auth } = await makeDiscoveryService();
    const idempotencyRun = vi.spyOn((service as any).idempotency, "run");
    const temporaryKey = "temporary-discovery-key-never-persist";
    const result = await service.handle("provider/discover", {
      baseUrl: "https://provider.unit/v1/chat/completions",
      apiKey: temporaryKey,
      context: { requestId: "req_ad_hoc" }
    }, auth);
    expect(result).toMatchObject({ models: expect.any(Array) });
    expect(harness.requests[0]?.path).toBe("/v1/models");
    expect(harness.requests[0]?.headers.Authorization).toBe(`Bearer ${temporaryKey}`);
    expect(idempotencyRun).not.toHaveBeenCalled();
    expect(await service.providers.list()).toHaveLength(0);
    expect(await persistedText(service.config.dataDir)).not.toContain(temporaryKey);
    expect(JSON.stringify(result)).not.toContain(temporaryKey);
  });

  it("validates the two request shapes, ownership, saved secrets, and fixed provider errors", async () => {
    const { service, harness, auth } = await makeDiscoveryService();
    const invalid = [
      {},
      { providerId: "saved", baseUrl: "https://provider.unit", apiKey: "key" },
      { baseUrl: "https://provider.unit" },
      { apiKey: "key" },
      { providerId: "" },
      { providerId: "saved", idempotencyKey: "forbidden" },
      { providerId: "saved", context: { requestId: "req", idempotencyKey: "forbidden" } },
      { providerId: "saved", context: { requestId: "req" }, extra: true }
    ];
    for (const params of invalid) {
      await expect(service.handle("provider/discover", params, auth)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    }
    await expect(service.handle("provider/discover", { providerId: "missing" }, auth)).rejects.toMatchObject({
      code: "NOT_FOUND",
      data: expect.objectContaining({ field: "providerId" })
    });
    await expect(service.handle("provider/discover", { providerId: "missing" }, null)).rejects.toMatchObject({ code: "UNAUTHORIZED" });
    await expect(service.handle("provider/discover", { providerId: "missing" }, {
      device: { ...auth.device, role: "viewer" as never }
    })).rejects.toMatchObject({ code: "FORBIDDEN" });
    expect(harness.requests).toHaveLength(0);

    const saved = await service.providers.create({
      name: "Saved", vendorKey: "saved", type: "openai_compatible", protocol: "openai_compatible",
      baseUrl: "https://provider.unit", authKind: "api_key", apiKey: "saved-secret", models: []
    });
    await rm(join(service.config.dataDir, "providers", "secrets", saved.id));
    await expect(service.handle("provider/discover", { providerId: saved.id }, auth)).rejects.toMatchObject({
      code: "PROVIDER_SECRET_MISSING",
      data: expect.objectContaining({ field: "providerId" })
    });

    harness.setStatus(500);
    harness.setBody("sensitive upstream body");
    try {
      await service.handle("provider/discover", { baseUrl: "https://provider.unit", apiKey: "temporary" }, auth);
      throw new Error("expected discovery failure");
    } catch (error) {
      const envelope = (error as { toJSONRPC(id: string): any }).toJSONRPC("req_upstream");
      expect(envelope.error).toMatchObject({
        code: -32029,
        data: { code: "UPSTREAM_UNAVAILABLE", reason: "upstream_http", upstreamStatus: 500 }
      });
      expect(JSON.stringify(envelope)).not.toContain("sensitive upstream body");
      expect(JSON.stringify(envelope)).not.toContain("temporary");
    }
  });

  it("takes discovery credentials and origin as one snapshot serialized with updates", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-provider-snapshot-"));
    const store = new ProviderStore(root, true);
    const created = await store.create({
      name: "Original", vendorKey: "snapshot", type: "openai_compatible", protocol: "openai_compatible",
      baseUrl: "https://provider-a.unit/v1", authKind: "api_key", apiKey: "key-a", models: []
    });
    const update = {
      name: "Updated", vendorKey: "snapshot", type: "openai_compatible", protocol: "openai_compatible",
      baseUrl: "https://provider-b.unit/v1", authKind: "api_key" as const, apiKey: "key-b", models: []
    };
    for (let index = 0; index < 20; index++) {
      const [snapshot] = await Promise.all([
        store.discoveryInput(created.id),
        index % 2 === 0 ? store.update(created.id, update) : Promise.resolve(null)
      ]);
      expect(
        (snapshot.baseUrl === "https://provider-a.unit/v1" && snapshot.apiKey === "key-a") ||
        (snapshot.baseUrl === "https://provider-b.unit/v1" && snapshot.apiKey === "key-b")
      ).toBe(true);
    }
  });

  it("includes saved provider snapshot reads in the single seven-second deadline", async () => {
    const { service, auth } = await makeDiscoveryService();
    const saved = await service.providers.create({
      name: "Slow", vendorKey: "slow", type: "openai_compatible", protocol: "openai_compatible",
      baseUrl: "https://provider.unit/v1", authKind: "api_key", apiKey: "saved-secret", models: []
    });
    vi.useFakeTimers();
    const delayed = () => new Promise<any>((resolve) => {
      setTimeout(() => resolve({ baseUrl: "https://provider.unit/v1", apiKey: "saved-secret" }), 8_000);
    });
    vi.spyOn(service.providers, "list").mockImplementation(delayed);
    (service.providers as any).discoveryInput = vi.fn(delayed);
    const pending = service.handle("provider/discover", {
      providerId: saved.id,
      context: { requestId: "req_slow_saved" }
    }, auth);
    void pending.catch(() => undefined);
    let settled = false;
    void pending.then(() => { settled = true; }, () => { settled = true; });
    await vi.advanceTimersByTimeAsync(7_001);
    expect(settled).toBe(true);
    const envelope = await pending.then(
      () => { throw new Error("expected a deadline error"); },
      (error: { toJSONRPC(id: string): any }) => error.toJSONRPC("req_slow_saved")
    );
    expect(envelope.error).toMatchObject({ code: -32028, data: { code: "UPSTREAM_TIMEOUT" } });
  });
});
