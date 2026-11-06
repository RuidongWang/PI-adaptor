import { Readable } from "node:stream";
import { gzipSync } from "node:zlib";
import type { IncomingHttpHeaders } from "node:http";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  discoverProviderModels,
  PROVIDER_DISCOVERY_MAX_BYTES,
  PROVIDER_DISCOVERY_MAX_MODELS,
  ProviderDiscoveryError,
  type ProviderDiscoveryConnectOptions,
  type ProviderDiscoveryConnection,
  type ProviderDiscoveryConnector,
  type ProviderDiscoveryLookup,
  type ProviderDiscoveryRequest,
  type ProviderDiscoveryResponse,
  type ProviderDiscoveryTestOnly
} from "../src/providers/discovery.js";

const DEFAULT_BODY = JSON.stringify({ data: [{ id: "model-b" }, { id: "model-a" }] });

type HarnessOptions = {
  addresses?: string[];
  remoteAddress?: string;
  tcpRemoteAddress?: string;
  body?: Buffer | string;
  statusCode?: number;
  headers?: IncomingHttpHeaders;
  allowPrivateHosts?: string[];
  lookupError?: unknown;
  connectError?: unknown;
};

function makeResponse(options: HarnessOptions = {}): ProviderDiscoveryResponse {
  const body = options.body ?? DEFAULT_BODY;
  return {
    statusCode: options.statusCode ?? 200,
    headers: options.headers ?? {},
    body: Readable.from([Buffer.isBuffer(body) ? body : Buffer.from(body)]),
    close: vi.fn()
  };
}

function makeHarness(options: HarnessOptions = {}) {
  const requests: ProviderDiscoveryRequest[] = [];
  const connectOptions: ProviderDiscoveryConnectOptions[] = [];
  const connections: ProviderDiscoveryConnection[] = [];
  const responses: ProviderDiscoveryResponse[] = [];
  const lookup: ProviderDiscoveryLookup = vi.fn(async () => {
    if (options.lookupError) throw options.lookupError;
    return (options.addresses ?? ["8.8.8.8"]).map((address) => ({ address }));
  });
  const connect: ProviderDiscoveryConnector = vi.fn(async (connectOption, validateRemoteAddress) => {
    connectOptions.push(connectOption);
    if (options.connectError) throw options.connectError;
    validateRemoteAddress(options.tcpRemoteAddress ?? options.remoteAddress ?? connectOption.address);
    const response = makeResponse(options);
    responses.push(response);
    const connection: ProviderDiscoveryConnection = {
      remoteAddress: options.remoteAddress ?? connectOption.address,
      request: vi.fn(async (request) => {
        requests.push(request);
        return response;
      }),
      close: vi.fn()
    };
    connections.push(connection);
    return connection;
  });
  const testOnly: ProviderDiscoveryTestOnly = {
    lookup,
    connect,
    ...(options.allowPrivateHosts ? { allowPrivateHosts: options.allowPrivateHosts } : {})
  };
  return { testOnly, lookup, connect, requests, connectOptions, connections, responses };
}

function discover(
  harness: ReturnType<typeof makeHarness>,
  baseUrl = "https://provider.unit/v1",
  apiKey?: string
) {
  return discoverProviderModels(
    { baseUrl, ...(apiKey === undefined ? {} : { apiKey }) },
    { testOnly: harness.testOnly }
  );
}

function expectError(code: string, reason?: string) {
  return expect.objectContaining({
    code,
    numericCode: expect.any(Number),
    ...(reason === undefined ? {} : { data: expect.objectContaining({ code, reason }) })
  });
}

afterEach(() => {
  vi.useRealTimers();
  vi.restoreAllMocks();
});

describe("provider model discovery URL policy", () => {
  it.each([
    ["https://provider.unit", "/models"],
    ["https://provider.unit/v1", "/v1/models"],
    ["https://provider.unit/v1/", "/v1/models"],
    ["https://provider.unit/v1////", "/v1/models"],
    ["https://provider.unit/v1/chat/completions", "/v1/models"],
    ["https://provider.unit/v1/chat/completions/", "/v1/models"],
    ["https://provider.unit/v1/chat/completions///", "/v1/models"],
    ["https://provider.unit/v1/responses", "/v1/models"],
    ["https://provider.unit/v1/messages", "/v1/models"],
    ["https://provider.unit/v1/models", "/v1/models"],
    ["https://provider.unit/v1/models/", "/v1/models"]
  ])("normalizes %s to the models endpoint", async (baseUrl, expectedPath) => {
    const harness = makeHarness();
    await discover(harness, baseUrl);
    expect(harness.requests).toHaveLength(1);
    expect(harness.requests[0]?.path).toBe(expectedPath);
  });

  it.each([
    ["http://provider.unit/v1", "scheme"],
    ["https://user:pass@provider.unit/v1", "userinfo"],
    ["https://provider.unit/v1?key=value", "query"],
    ["https://provider.unit/v1?", "query"],
    ["https://provider.unit/v1#fragment", "fragment"],
    ["https://provider.unit/v1#", "fragment"],
    [" https://provider.unit/v1", "whitespace"],
    ["https://provider.unit/v 1", "whitespace"],
    ["https://provider.unit/v1\n", "whitespace"],
    ["https://provider.unit:0/v1", "port"],
    ["https://provider.unit:65536/v1", "invalid_url"]
  ])("rejects %s before DNS", async (baseUrl, reason) => {
    const harness = makeHarness();
    await expect(discover(harness, baseUrl)).rejects.toMatchObject({
      code: "INVALID_ARGUMENT",
      numericCode: -32004,
      data: expect.objectContaining({ reason })
    });
    expect(harness.lookup).not.toHaveBeenCalled();
    expect(harness.connect).not.toHaveBeenCalled();
  });

  it.each([
    "https://2130706433/v1",
    "https://0177.0.0.1/v1",
    "https://0x7f000001/v1",
    "https://0x7f.0.0.1/v1",
    "https://127.1/v1",
    "https://0x08080808/v1",
    "https://134744072/v1"
  ])("rejects non-canonical IPv4 expression %s", async (baseUrl) => {
    const harness = makeHarness();
    await expect(discover(harness, baseUrl)).rejects.toMatchObject({
      code: "INVALID_ARGUMENT",
      data: expect.objectContaining({ reason: "hostname" })
    });
    expect(harness.connect).not.toHaveBeenCalled();
  });

  it.each([
    "https://printer.local/v1",
    "https://metadata.google.internal/v1",
    "https://metadata.azure.internal/v1"
  ])("rejects local or metadata hostname %s before DNS", async (baseUrl) => {
    const harness = makeHarness();
    await expect(discover(harness, baseUrl)).rejects.toMatchObject({
      code: "ENDPOINT_REJECTED",
      numericCode: -32027,
      data: expect.objectContaining({ reason: "private_address" })
    });
    expect(harness.lookup).not.toHaveBeenCalled();
  });

  it.each([
    "https://localhost/v1",
    "https://foo.localhost/v1",
    "http://localhost:8080/v1",
    "http://127.0.0.1:8080/v1"
  ])("allows loopback gateway %s without DNS", async (baseUrl) => {
    const harness = makeHarness({ addresses: ["127.0.0.1"] });
    await expect(discover(harness, baseUrl)).resolves.toMatchObject({ models: expect.any(Array) });
    expect(harness.connect).toHaveBeenCalledTimes(1);
  });

  it("validates temporary keys without copying them into errors", async () => {
    const secret = `sk-not-for-logs-${"x".repeat(16_400)}`;
    const harness = makeHarness();
    await expect(discover(harness, undefined, secret)).rejects.toMatchObject({
      code: "INVALID_ARGUMENT",
      data: expect.objectContaining({ reason: "api_key" })
    });
    await expect(discover(harness, undefined, "bad\r\nInjected: yes")).rejects.toMatchObject({
      code: "INVALID_ARGUMENT",
      data: expect.objectContaining({ reason: "api_key" })
    });
    expect(harness.connect).not.toHaveBeenCalled();
  });
});

describe("provider model discovery address policy and DNS pinning", () => {
  it.each([
    "0.0.0.0",
    "0.1.2.3",
    "10.0.0.1",
    "100.64.0.1",
    "100.127.255.254",
    "100.100.100.200",
    "169.254.169.254",
    "172.16.0.1",
    "172.31.255.254",
    "192.0.0.1",
    "192.0.2.10",
    "192.31.196.1",
    "192.52.193.1",
    "192.88.99.1",
    "192.168.1.1",
    "192.175.48.1",
    "198.18.0.1",
    "198.19.255.254",
    "198.51.100.10",
    "203.0.113.10",
    "224.0.0.1",
    "239.255.255.255",
    "240.0.0.1",
    "255.255.255.255",
    "::",
    "::8.8.8.8",
    "::ffff:8.8.8.8",
    "::ffff:0:8.8.8.8",
    "64:ff9b::808:808",
    "64:ff9b:1::1",
    "100::1",
    "2001::1",
    "2001:2::1",
    "2001:10::1",
    "2001:20::1",
    "2001:30::1",
    "2001:db8::1",
    "2002::1",
    "fc00::1",
    "fdff::1",
    "fe80::1",
    "febf::1",
    "fec0::1",
    "ff02::1",
    "3fff::1",
    "5f00::1"
  ])("rejects non-public, special, mapped, or transition address %s", async (address) => {
    const harness = makeHarness({ addresses: [address] });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "ENDPOINT_REJECTED",
      numericCode: -32027,
      data: expect.objectContaining({ reason: "private_address" })
    });
    expect(harness.connect).not.toHaveBeenCalled();
  });

  it.each([
    "8.8.8.8",
    "100.32.0.1",
    "100.128.0.1",
    "172.15.0.1",
    "172.32.0.1",
    "192.0.1.1",
    "192.0.3.1",
    "198.17.0.1",
    "198.20.0.1",
    "203.0.112.1",
    "2001:4860:4860::8888",
    "2606:4700:4700::1111"
  ])("allows public unicast address %s", async (address) => {
    const harness = makeHarness({ addresses: [address] });
    await expect(discover(harness)).resolves.toMatchObject({ models: expect.any(Array) });
    expect(harness.connect).toHaveBeenCalledTimes(1);
  });

  it("rejects the entire request when any DNS candidate is private", async () => {
    const harness = makeHarness({ addresses: ["8.8.8.8", "10.0.0.1"] });
    await expect(discover(harness)).rejects.toMatchObject({ code: "ENDPOINT_REJECTED" });
    expect(harness.connect).not.toHaveBeenCalled();
  });

  it("allows a private mock only through the separate explicit test-only allowlist", async () => {
    const blocked = makeHarness({ addresses: ["10.0.0.1"] });
    await expect(discover(blocked)).rejects.toMatchObject({ code: "ENDPOINT_REJECTED" });
    expect(blocked.connect).not.toHaveBeenCalled();

    const allowed = makeHarness({ addresses: ["10.0.0.1"], allowPrivateHosts: ["provider.unit"] });
    await expect(discover(allowed)).resolves.toMatchObject({ models: expect.any(Array) });
    expect(allowed.connect).toHaveBeenCalledTimes(1);
  });

  it("never lets the test-only allowlist enable mapped or transition addresses", async () => {
    const harness = makeHarness({
      addresses: ["::ffff:127.0.0.1"],
      allowPrivateHosts: ["provider.unit"]
    });
    await expect(discover(harness)).rejects.toMatchObject({ code: "ENDPOINT_REJECTED" });
    expect(harness.connect).not.toHaveBeenCalled();
  });

  it("pins all normalized addresses and retries another pinned address after refusal", async () => {
    const requests: ProviderDiscoveryRequest[] = [];
    const attempted: string[] = [];
    const lookup: ProviderDiscoveryLookup = async () => [
      { address: "8.8.8.8" },
      { address: "1.1.1.1" },
      { address: "8.8.8.8" }
    ];
    const connect: ProviderDiscoveryConnector = async (options, validateRemoteAddress) => {
      attempted.push(options.address);
      validateRemoteAddress(options.address);
      if (options.address === "8.8.8.8") {
        throw Object.assign(new Error("refused"), { code: "ECONNREFUSED" });
      }
      return {
        remoteAddress: options.address,
        request: async (request) => {
          requests.push(request);
          return makeResponse();
        },
        close: vi.fn()
      };
    };
    const result = await discoverProviderModels(
      { baseUrl: "https://provider.unit/v1" },
      { testOnly: { lookup, connect } }
    );
    expect(attempted).toEqual(["8.8.8.8", "1.1.1.1"]);
    expect(requests).toHaveLength(1);
    expect(result.models.map((model) => model.id)).toEqual(["model-a", "model-b"]);
  });

  it("rejects a public actual remoteIP outside the pinned set before sending headers", async () => {
    const harness = makeHarness({
      addresses: ["8.8.8.8"],
      tcpRemoteAddress: "8.8.8.8",
      remoteAddress: "1.1.1.1"
    });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "ENDPOINT_REJECTED",
      data: expect.objectContaining({ reason: "public_address_changed" })
    });
    expect(harness.requests).toHaveLength(0);
    expect(harness.connections[0]?.close).toHaveBeenCalled();
  });

  it("rejects a mapped actual remoteIP even when its embedded IPv4 was pinned", async () => {
    const harness = makeHarness({
      addresses: ["8.8.8.8"],
      tcpRemoteAddress: "::ffff:8.8.8.8"
    });
    await expect(discover(harness)).rejects.toMatchObject({ code: "ENDPOINT_REJECTED" });
    expect(harness.requests).toHaveLength(0);
  });

  it("canonicalizes the actual remoteIPv6 before exact pinned-set comparison", async () => {
    const harness = makeHarness({
      addresses: ["2606:4700:4700::1111"],
      remoteAddress: "2606:4700:4700:0:0:0:0:1111"
    });
    await expect(discover(harness)).resolves.toMatchObject({ models: expect.any(Array) });
    expect(harness.requests).toHaveLength(1);
  });

  it("rejects malformed and zone-scoped DNS results", async () => {
    for (const address of ["not-an-ip", "fe80::1%eth0", "127.1", "0x7f000001"]) {
      const harness = makeHarness({ addresses: [address] });
      await expect(discover(harness)).rejects.toMatchObject({ code: "ENDPOINT_REJECTED" });
      expect(harness.connect).not.toHaveBeenCalled();
    }
  });

  it("maps DNS failures and empty answers without leaking resolver details", async () => {
    const failure = makeHarness({ lookupError: new Error("resolver secret detail") });
    await expect(discover(failure)).rejects.toMatchObject({
      code: "UPSTREAM_UNAVAILABLE",
      numericCode: -32029,
      message: "upstream DNS resolution failed",
      data: expect.objectContaining({ reason: "dns" })
    });
    const empty = makeHarness({ addresses: [] });
    await expect(discover(empty)).rejects.toMatchObject({
      code: "ENDPOINT_REJECTED",
      data: expect.objectContaining({ reason: "dns" })
    });
  });

  it("uses an IP literal directly and preserves IP hostname verification semantics", async () => {
    const harness = makeHarness();
    await discover(harness, "https://8.8.8.8:8443/v1");
    expect(harness.lookup).not.toHaveBeenCalled();
    expect(harness.connectOptions[0]).toMatchObject({
      address: "8.8.8.8",
      hostname: "8.8.8.8",
      servername: undefined,
      port: 8443,
      rejectUnauthorized: true
    });
    expect(harness.requests[0]?.headers.Host).toBe("8.8.8.8:8443");
  });
});

describe("provider model discovery HTTPS request", () => {
  it("uses the original hostname for SNI and Host and sends only fixed headers", async () => {
    const harness = makeHarness();
    await discover(harness, "https://provider.unit:8443/v1", "sk-temporary-only");
    expect(harness.connectOptions[0]).toMatchObject({
      address: "8.8.8.8",
      hostname: "provider.unit",
      servername: "provider.unit",
      port: 8443,
      rejectUnauthorized: true
    });
    expect(harness.requests[0]?.method).toBe("GET");
    expect(harness.requests[0]?.headers).toEqual({
      Accept: "application/json",
      Authorization: "Bearer sk-temporary-only",
      Host: "provider.unit:8443",
      "User-Agent": "pi-adaptor-provider-discovery/1.0"
    });
  });

  it("omits Authorization for a saved provider with authKind none", async () => {
    const harness = makeHarness();
    await discover(harness);
    expect(harness.requests[0]?.headers).not.toHaveProperty("Authorization");
  });

  it.each([300, 301, 302, 303, 307, 308])("rejects every redirect status %s without following it", async (statusCode) => {
    const harness = makeHarness({
      statusCode,
      headers: { location: "https://provider.unit/v1/other" },
      body: "redirect body must not be copied"
    });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "REDIRECT_FORBIDDEN",
      numericCode: -32031,
      message: "upstream redirects are forbidden"
    });
    expect(harness.connect).toHaveBeenCalledTimes(1);
  });

  it.each([401, 402, 403, 404, 408, 409, 429, 500, 503])("preserves upstream HTTP %d as a provider error", async (statusCode) => {
    const harness = makeHarness({ statusCode, body: "sensitive upstream response" });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "UPSTREAM_UNAVAILABLE",
      numericCode: -32029,
      message: "upstream HTTP request failed",
      data: { code: "UPSTREAM_UNAVAILABLE", reason: "upstream_http", upstreamStatus: statusCode }
    });
  });

  it("classifies refused and TLS connection failures with fixed messages", async () => {
    const refused = makeHarness({ connectError: Object.assign(new Error("private detail"), { code: "ECONNREFUSED" }) });
    await expect(discover(refused)).rejects.toMatchObject({
      code: "UPSTREAM_UNAVAILABLE",
      message: "upstream connection refused",
      data: expect.objectContaining({ reason: "refused" })
    });
    const tls = makeHarness({ connectError: Object.assign(new Error("certificate detail"), { code: "CERT_ALTNAME_INVALID" }) });
    await expect(discover(tls)).rejects.toMatchObject({
      code: "UPSTREAM_UNAVAILABLE",
      message: "upstream TLS connection failed",
      data: expect.objectContaining({ reason: "tls" })
    });
  });

  it("uses one 7 second deadline across DNS and connection, and aborts the active operation", async () => {
    vi.useFakeTimers();
    let signal: AbortSignal | undefined;
    const lookup: ProviderDiscoveryLookup = () => new Promise((resolve) => {
      setTimeout(() => resolve([{ address: "8.8.8.8" }]), 4_000);
    });
    const connect: ProviderDiscoveryConnector = (options) => {
      signal = options.signal;
      return new Promise<ProviderDiscoveryConnection>(() => undefined);
    };
    const pending = discoverProviderModels(
      { baseUrl: "https://provider.unit/v1" },
      { testOnly: { lookup, connect } }
    );
    const assertion = expect(pending).rejects.toMatchObject({
      code: "UPSTREAM_TIMEOUT",
      numericCode: -32028,
      message: "provider discovery deadline exceeded"
    });
    await vi.advanceTimersByTimeAsync(6_999);
    expect(signal?.aborted).toBe(false);
    await vi.advanceTimersByTimeAsync(1);
    await assertion;
    expect(signal?.aborted).toBe(true);
  });
});

describe("provider model discovery response limits and errors", () => {
  it("accepts exactly 2 MiB", async () => {
    const prefix = Buffer.from(JSON.stringify({ data: [{ id: "exact-limit" }] }));
    const body = Buffer.concat([prefix, Buffer.alloc(PROVIDER_DISCOVERY_MAX_BYTES - prefix.length, 0x20)]);
    expect(body).toHaveLength(2_097_152);
    const harness = makeHarness({ body });
    await expect(discover(harness)).resolves.toMatchObject({ models: [{ id: "exact-limit" }] });
  });

  it("aborts at byte 2 MiB + 1 and returns no partial models", async () => {
    const body = Buffer.alloc(PROVIDER_DISCOVERY_MAX_BYTES + 1, 0x20);
    const harness = makeHarness({ body });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "PAYLOAD_TOO_LARGE",
      numericCode: -32010,
      data: { code: "PAYLOAD_TOO_LARGE", maxBytes: 2_097_152 }
    });
    expect(harness.responses[0]?.close).toHaveBeenCalled();
  });

  it("rejects an excessive Content-Length before streaming the body", async () => {
    let iterated = false;
    const harness = makeHarness({ headers: { "content-length": "2097153" } });
    const response = makeResponse({ headers: { "content-length": "2097153" } });
    response.body = Readable.from((async function* () {
      iterated = true;
      yield Buffer.from("{}");
    })());
    harness.connect = vi.fn(async (_options, validateRemoteAddress) => {
      validateRemoteAddress("8.8.8.8");
      return { remoteAddress: "8.8.8.8", request: async () => response, close: vi.fn() };
    });
    harness.testOnly.connect = harness.connect;
    await expect(discover(harness)).rejects.toMatchObject({ code: "PAYLOAD_TOO_LARGE" });
    expect(iterated).toBe(false);
    expect(response.close).toHaveBeenCalled();
  });

  it("counts decompressed bytes rather than compressed bytes", async () => {
    const prefix = Buffer.from(JSON.stringify({ data: [{ id: "compressed" }] }));
    const expanded = Buffer.concat([prefix, Buffer.alloc(PROVIDER_DISCOVERY_MAX_BYTES, 0x20)]);
    const compressed = gzipSync(expanded);
    expect(compressed.length).toBeLessThan(PROVIDER_DISCOVERY_MAX_BYTES);
    const harness = makeHarness({
      body: compressed,
      headers: { "content-encoding": "gzip", "content-length": String(compressed.length) }
    });
    await expect(discover(harness)).rejects.toMatchObject({ code: "PAYLOAD_TOO_LARGE" });
  });

  it.each(["not json", "{\"", "{} trailing"])("rejects malformed JSON %s", async (body) => {
    const harness = makeHarness({ body });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "UPSTREAM_RESPONSE_INVALID",
      numericCode: -32030,
      data: expect.objectContaining({ reason: "invalid_json" })
    });
  });

  it("rejects invalid UTF-8 as invalid JSON", async () => {
    const harness = makeHarness({ body: Buffer.from([0x7b, 0x22, 0x78, 0x22, 0x3a, 0xff, 0x7d]) });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "UPSTREAM_RESPONSE_INVALID",
      data: expect.objectContaining({ reason: "invalid_json" })
    });
  });

  it.each([null, {}, { data: {} }, { models: "no" }, "text", 42])("rejects invalid schema %j", async (value) => {
    const harness = makeHarness({ body: JSON.stringify(value) });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "UPSTREAM_RESPONSE_INVALID",
      data: expect.objectContaining({ reason: "schema" })
    });
  });

  it.each([
    { data: [] },
    { models: [] },
    [],
    { data: [null, 1, {}, { id: "" }, { id: "models/" }, { id: 42 }] }
  ])("rejects an empty valid-model result for %j", async (value) => {
    const harness = makeHarness({ body: JSON.stringify(value) });
    await expect(discover(harness)).rejects.toMatchObject({
      code: "UPSTREAM_RESPONSE_INVALID",
      data: expect.objectContaining({ reason: "empty_list" })
    });
  });

  it("never includes an API key, upstream body, endpoint, or remoteIP in results/errors/logs", async () => {
    const apiKey = "sk-super-secret-temporary";
    const spies = [console.log, console.info, console.warn, console.error].map((method) =>
      vi.spyOn(console, method.name as "log").mockImplementation(() => undefined)
    );
    const failure = makeHarness({ statusCode: 500, body: `upstream echoed ${apiKey}` });
    let serialized = "";
    try {
      await discover(failure, undefined, apiKey);
    } catch (error) {
      expect(error).toBeInstanceOf(ProviderDiscoveryError);
      serialized = JSON.stringify(error) + JSON.stringify((error as ProviderDiscoveryError).toJSONRPC("req_1"));
      expect(String(error)).not.toContain(apiKey);
    }
    expect(serialized).not.toContain(apiKey);
    expect(serialized).not.toContain("upstream echoed");
    for (const spy of spies) expect(spy).not.toHaveBeenCalled();

    const success = makeHarness();
    const result = await discover(success, undefined, apiKey);
    expect(JSON.stringify(result)).not.toContain(apiKey);
    expect(result).not.toHaveProperty("baseUrl");
    expect(result).not.toHaveProperty("remoteIP");
  });
});

describe("provider model discovery ProviderModel parsing", () => {
  it("parses complete models, aliases, capabilities, defaults, deduplication, and sorting", async () => {
    const harness = makeHarness({
      body: JSON.stringify({
        data: [
          {
            id: "models/zeta",
            display_name: "Zeta Display",
            context_window: 0,
            contextWindow: 64_000,
            max_tokens: -1,
            maxTokens: 4_096,
            supported_effort_levels: ["low", "high", "low"],
            default_effort: "medium",
            supports_images: true
          },
          {
            slug: "alpha",
            name: "Alpha Display",
            context_length: 128_000,
            max_completion_tokens: 2_048,
            thinking_levels: ["off", "medium"],
            defaultThinkingLevel: "medium",
            architecture: { input_modalities: ["text", "image"] }
          },
          { name: "fallback-name" },
          { id: "zeta", displayName: "duplicate must not replace first" },
          null,
          42,
          { id: "models/" }
        ]
      })
    });
    const result = await discover(harness);
    expect(result).toEqual({
      models: [
        {
          id: "alpha",
          displayName: "Alpha Display",
          contextWindow: 128_000,
          maxTokens: 2_048,
          thinkingLevels: ["off", "medium"],
          defaultThinkingLevel: "medium",
          supportsImages: true
        },
        {
          id: "fallback-name",
          displayName: "fallback-name",
          contextWindow: 128_000,
          maxTokens: 8_192,
          thinkingLevels: [],
          defaultThinkingLevel: null,
          supportsImages: false
        },
        {
          id: "zeta",
          displayName: "Zeta Display",
          contextWindow: 64_000,
          maxTokens: 4_096,
          thinkingLevels: ["low", "high"],
          defaultThinkingLevel: null,
          supportsImages: true
        }
      ]
    });
  });

  it("supports models envelopes and bare arrays", async () => {
    const envelope = makeHarness({ body: JSON.stringify({ models: [{ id: "models/envelope" }] }) });
    await expect(discover(envelope)).resolves.toMatchObject({ models: [{ id: "envelope" }] });
    const bare = makeHarness({ body: JSON.stringify([{ id: "bare" }]) });
    await expect(discover(bare)).resolves.toMatchObject({ models: [{ id: "bare" }] });
  });

  it("takes the first 500 unique upstream ids, ignores later rows, then sorts by id", async () => {
    const rows = Array.from({ length: PROVIDER_DISCOVERY_MAX_MODELS + 1 }, (_, index) => ({
      id: `model-${String(index).padStart(3, "0")}`
    }));
    rows.splice(10, 0, { id: "model-000" });
    const harness = makeHarness({ body: JSON.stringify(rows) });
    const result = await discover(harness);
    expect(result.models).toHaveLength(500);
    expect(result.models.some((model) => model.id === "model-500")).toBe(false);
    expect(result.models[0]?.displayName).toBe("model-000");
    expect(result.models.map((model) => model.id)).toEqual(
      Array.from({ length: 500 }, (_, index) => `model-${String(index).padStart(3, "0")}`)
    );
  });

  it("uses null when a declared default effort is absent from the ladder", async () => {
    const harness = makeHarness({
      body: JSON.stringify([
        { id: "valid-default", reasoning: { efforts: ["low", "high"], default_effort: "high" } },
        { id: "invalid-default", reasoning: { efforts: ["low"], default_effort: "max" } },
        { id: "undeclared", defaultThinkingLevel: "high" }
      ])
    });
    const result = await discover(harness);
    expect(result.models.find((model) => model.id === "valid-default")).toMatchObject({
      thinkingLevels: ["low", "high"],
      defaultThinkingLevel: "high"
    });
    expect(result.models.find((model) => model.id === "invalid-default")?.defaultThinkingLevel).toBeNull();
    expect(result.models.find((model) => model.id === "undeclared")).toMatchObject({
      thinkingLevels: [],
      defaultThinkingLevel: null
    });
  });
});
