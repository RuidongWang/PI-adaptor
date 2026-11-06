import { lookup as systemLookup } from "node:dns/promises";
import type { IncomingHttpHeaders } from "node:http";
import { request as httpRequest } from "node:http";
import { request as httpsRequest } from "node:https";
import { connect as tcpConnect, isIP, type Socket } from "node:net";
import type { Readable } from "node:stream";
import { checkServerIdentity, connect as tlsConnect, type TLSSocket } from "node:tls";
import { TextDecoder } from "node:util";
import { createBrotliDecompress, createGunzip, createInflate } from "node:zlib";
import type { ProviderModel } from "./store.js";
import { providerApi, type ProviderApi } from "./protocol.js";

export const PROVIDER_DISCOVERY_DEADLINE_MS = 7_000;
export const PROVIDER_DISCOVERY_MAX_BYTES = 2 * 1024 * 1024;
export const PROVIDER_DISCOVERY_MAX_MODELS = 500;

const USER_AGENT = "pi-adaptor-provider-discovery/1.0";
const DEFAULT_CONTEXT_WINDOW = 128_000;
const DEFAULT_MAX_TOKENS = 8_192;

export const PROVIDER_DISCOVERY_ERROR_NUMBERS = {
  INTERNAL: -32000,
  INVALID_ARGUMENT: -32004,
  PAYLOAD_TOO_LARGE: -32010,
  ENDPOINT_REJECTED: -32027,
  UPSTREAM_TIMEOUT: -32028,
  UPSTREAM_UNAVAILABLE: -32029,
  UPSTREAM_RESPONSE_INVALID: -32030,
  REDIRECT_FORBIDDEN: -32031
} as const;

export type ProviderDiscoveryErrorCode = keyof typeof PROVIDER_DISCOVERY_ERROR_NUMBERS;

/** A fixed, non-secret provider error; upstream bodies and raw network messages are never copied. */
export class ProviderDiscoveryError extends Error {
  readonly code: ProviderDiscoveryErrorCode;
  readonly numericCode: number;
  readonly data: Record<string, unknown> & { code: ProviderDiscoveryErrorCode };

  constructor(
    code: ProviderDiscoveryErrorCode,
    message: string,
    data: Record<string, unknown> = {}
  ) {
    super(message);
    this.name = "ProviderDiscoveryError";
    this.code = code;
    this.numericCode = PROVIDER_DISCOVERY_ERROR_NUMBERS[code];
    this.data = { ...data, code };
  }

  toJSONRPC(id: string | number | null): {
    jsonrpc: "2.0";
    id: string | number | null;
    error: { code: number; message: string; data: Record<string, unknown> };
  } {
    return {
      jsonrpc: "2.0",
      id,
      error: { code: this.numericCode, message: this.message, data: { ...this.data } }
    };
  }
}

export type ProviderDiscoveryInput = {
  baseUrl: string;
  /** Omit for authKind:none. Ad-hoc request schema requires this field separately. */
  apiKey?: string;
  /**
   * Wire protocol of the provider being discovered. It decides only how the
   * list request authenticates (`/models` is shared by all four APIs); unknown
   * or missing values keep the OpenAI Chat Completions behaviour.
   */
  protocol?: string;
};

export type ProviderDiscoveryResult = { models: ProviderModel[] };

export type ProviderDiscoveryLookup = (
  hostname: string
) => Promise<readonly { address: string }[]>;

export type ProviderDiscoveryConnectOptions = {
  address: string;
  port: number;
  /** Original normalized URL hostname, without IPv6 brackets. Used for certificate hostname checks. */
  hostname: string;
  /** DNS hostname for SNI; undefined for IP literals, which still use IP certificate verification. */
  servername: string | undefined;
  rejectUnauthorized: true;
  signal: AbortSignal;
  /** Plain HTTP is only accepted for loopback gateways (no certificate to verify). */
  scheme?: "https" | "http";
};

export type ProviderDiscoveryRequest = {
  method: "GET";
  path: string;
  headers: Record<string, string>;
  signal: AbortSignal;
};

export type ProviderDiscoveryResponse = {
  statusCode: number | undefined;
  headers: IncomingHttpHeaders;
  body: Readable;
  close(): void;
};

export type ProviderDiscoveryConnection = {
  /** Must be the actual transport remote address, not the requested address. */
  remoteAddress: string | undefined;
  request(request: ProviderDiscoveryRequest): Promise<ProviderDiscoveryResponse>;
  close(): void;
};

export type ProviderDiscoveryConnector = (
  options: ProviderDiscoveryConnectOptions,
  /** The production connector calls this on TCP connect, before TLS and before HTTP headers. */
  validateRemoteAddress: (remoteAddress: string | undefined) => void
) => Promise<ProviderDiscoveryConnection>;

/**
 * Explicit test seam, never part of the RACP request. An allowlist entry may be an exact
 * URL hostname or exact IP. No dataDir, environment, or client-controlled field is consulted.
 */
export type ProviderDiscoveryTestOnly = {
  allowPrivateHosts?: readonly string[];
  lookup?: ProviderDiscoveryLookup;
  connect?: ProviderDiscoveryConnector;
};

export type ProviderDiscoveryOptions = {
  testOnly?: ProviderDiscoveryTestOnly;
  /** Absolute epoch deadline shared with saved-provider snapshot reads, when supplied. */
  deadlineAt?: number;
};

type ParsedAddress = {
  version: 4 | 6;
  canonical: string;
  ipv4: number;
  words: number[];
};

type NormalizedEndpoint = {
  url: URL;
  hostname: string;
  hostHeader: string;
  port: number;
  servername: string | undefined;
  scheme: "https" | "http";
};

/** Loopback gateways may be plain HTTP: the request never leaves the host. */
export function isLoopbackHostname(hostname: string): boolean {
  const host = hostname.replace(/\.$/, "").toLowerCase();
  return host === "localhost"
    || host.endsWith(".localhost")
    || host === "127.0.0.1"
    || host === "::1"
    || host === "0:0:0:0:0:0:0:1";
}

function failure(
  code: ProviderDiscoveryErrorCode,
  message: string,
  data: Record<string, unknown> = {}
): ProviderDiscoveryError {
  return new ProviderDiscoveryError(code, message, data);
}

function invalidUrl(reason: string): ProviderDiscoveryError {
  return failure("INVALID_ARGUMENT", "invalid provider discovery base URL", { reason });
}

function rejected(reason: string): ProviderDiscoveryError {
  return failure("ENDPOINT_REJECTED", "provider discovery endpoint was rejected", { reason });
}

function timeoutFailure(): ProviderDiscoveryError {
  return failure("UPSTREAM_TIMEOUT", "provider discovery deadline exceeded");
}

function parseIPv4(address: string): number | null {
  if (!/^\d+\.\d+\.\d+\.\d+$/.test(address)) return null;
  const parts = address.split(".");
  let value = 0;
  for (const part of parts) {
    if (!/^\d{1,3}$/.test(part) || (part.length > 1 && part.startsWith("0"))) return null;
    const octet = Number(part);
    if (octet > 255) return null;
    value = value * 256 + octet;
  }
  return value >>> 0;
}

function parseIPv6Groups(part: string): number[] | null {
  if (part === "") return [];
  const tokens = part.split(":");
  const groups: number[] = [];
  for (const [index, token] of tokens.entries()) {
    if (token.includes(".")) {
      if (index !== tokens.length - 1) return null;
      const ipv4 = parseIPv4(token);
      if (ipv4 === null) return null;
      groups.push((ipv4 >>> 16) & 0xffff, ipv4 & 0xffff);
    } else {
      if (!/^[0-9a-fA-F]{1,4}$/.test(token)) return null;
      groups.push(Number.parseInt(token, 16));
    }
  }
  return groups;
}

function canonicalIPv6(words: readonly number[]): string {
  let bestStart = -1;
  let bestLength = 0;
  let index = 0;
  while (index < 8) {
    if (words[index] !== 0) {
      index += 1;
      continue;
    }
    const start = index;
    while (index < 8 && words[index] === 0) index += 1;
    const length = index - start;
    if (length >= 2 && length > bestLength) {
      bestStart = start;
      bestLength = length;
    }
  }
  let output = "";
  index = 0;
  while (index < 8) {
    if (index === bestStart) {
      output += "::";
      index += bestLength;
      continue;
    }
    if (output !== "" && !output.endsWith("::")) output += ":";
    output += words[index]?.toString(16) ?? "0";
    index += 1;
  }
  return output;
}

function parseAddress(address: string): ParsedAddress | null {
  if (address.includes("%")) return null;
  const ipv4 = parseIPv4(address);
  if (ipv4 !== null) {
    return { version: 4, canonical: address, ipv4, words: [] };
  }
  if (isIP(address) !== 6) return null;
  const halves = address.split("::");
  if (halves.length > 2) return null;
  const left = parseIPv6Groups(halves[0] ?? "");
  const right = parseIPv6Groups(halves[1] ?? "");
  if (!left || !right) return null;
  const missing = 8 - left.length - right.length;
  if ((halves.length === 1 && missing !== 0) || (halves.length === 2 && missing < 1)) return null;
  const words = [...left, ...Array<number>(Math.max(0, missing)).fill(0), ...right];
  if (words.length !== 8) return null;
  return { version: 6, canonical: canonicalIPv6(words), ipv4: 0, words };
}

function inIPv4Range(value: number, base: string, bits: number): boolean {
  const parsedBase = parseIPv4(base);
  if (parsedBase === null) return false;
  const mask = bits === 0 ? 0 : (0xffffffff << (32 - bits)) >>> 0;
  return ((value & mask) >>> 0) === ((parsedBase & mask) >>> 0);
}

const IPV4_SPECIAL_RANGES: readonly (readonly [string, number])[] = [
  ["0.0.0.0", 8],
  ["10.0.0.0", 8],
  ["100.64.0.0", 10],
  ["100.100.100.200", 32],
  ["127.0.0.0", 8],
  ["169.254.0.0", 16],
  ["172.16.0.0", 12],
  ["192.0.0.0", 24],
  ["192.0.2.0", 24],
  ["192.31.196.0", 24],
  ["192.52.193.0", 24],
  ["192.88.99.0", 24],
  ["192.168.0.0", 16],
  ["192.175.48.0", 24],
  ["198.18.0.0", 15],
  ["198.51.100.0", 24],
  ["203.0.113.0", 24],
  ["224.0.0.0", 4],
  ["240.0.0.0", 4]
];

function inIPv6Range(words: readonly number[], base: string, bits: number): boolean {
  const parsed = parseAddress(base);
  if (!parsed || parsed.version !== 6) return false;
  for (let index = 0; index < 8; index += 1) {
    const remaining = bits - index * 16;
    if (remaining <= 0) return true;
    const mask = remaining >= 16 ? 0xffff : (0xffff << (16 - remaining)) & 0xffff;
    if (((words[index] ?? 0) & mask) !== ((parsed.words[index] ?? 0) & mask)) return false;
  }
  return true;
}

const IPV6_SPECIAL_RANGES: readonly (readonly [string, number])[] = [
  ["64:ff9b::", 96],
  ["64:ff9b:1::", 48],
  ["100::", 64],
  ["2001::", 23],
  ["2001:20::", 28],
  ["2001:30::", 28],
  ["2001:db8::", 32],
  ["2002::", 16],
  ["3fff::", 20],
  ["5f00::", 16],
  ["fc00::", 7],
  ["fe80::", 10],
  ["fec0::", 10],
  ["ff00::", 8]
];

function addressKind(address: ParsedAddress): "public" | "private" | "transition" {
  if (address.version === 4) {
    return IPV4_SPECIAL_RANGES.some(([base, bits]) => inIPv4Range(address.ipv4, base, bits))
      ? "private"
      : "public";
  }
  // Unspecified and loopback may be named by an explicit test-only allowlist.
  if (address.canonical === "::" || address.canonical === "::1") return "private";
  // Reject IPv4-compatible, mapped, translated, and other reserved ::/64 forms even
  // when their embedded IPv4 is public. Never unmap them into a different policy path.
  if (address.words.slice(0, 4).every((word) => word === 0)) return "transition";
  return IPV6_SPECIAL_RANGES.some(([base, bits]) => inIPv6Range(address.words, base, bits))
    ? "private"
    : "public";
}

function canonicalAllowlistEntry(entry: string): string {
  const unbracketed = entry.startsWith("[") && entry.endsWith("]")
    ? entry.slice(1, -1)
    : entry;
  const parsed = parseAddress(unbracketed);
  return (parsed?.canonical ?? unbracketed.replace(/\.$/, "")).toLowerCase();
}

function isLoopbackAddress(address: ParsedAddress): boolean {
  if (address.version === 4) return address.ipv4 >>> 24 === 127;
  return address.canonical === "::1";
}

function privateAddressAllowed(
  hostname: string,
  address: ParsedAddress,
  allowlist: ReadonlySet<string>
): boolean {
  // Loopback gateways are a product default (localhost 模型服务), and a
  // loopback connection cannot reach anything outside the host itself. Only
  // allow it when the requested hostname is itself loopback, so a public name
  // that rebinds to 127.0.0.1 stays rejected.
  if (isLoopbackAddress(address) && isLoopbackHostname(hostname)) return true;
  return allowlist.has(canonicalAllowlistEntry(hostname)) || allowlist.has(address.canonical);
}

function isLocalOrMetadataHostname(hostname: string): boolean {
  const host = hostname.replace(/\.$/, "").toLowerCase();
  return host === "localhost" || host.endsWith(".localhost") ||
    host === "local" || host.endsWith(".local") ||
    host === "metadata.google.internal" || host.endsWith(".metadata.google.internal") ||
    host === "metadata.azure.internal" || host.endsWith(".metadata.azure.internal") ||
    host === "metadata.oraclecloud.internal" || host.endsWith(".metadata.oraclecloud.internal");
}

function rawHostname(raw: string): string | null {
  const authority = /^https?:\/\/([^/?#]*)/i.exec(raw)?.[1];
  if (authority === undefined) return null;
  const withoutUserinfo = authority.slice(authority.lastIndexOf("@") + 1);
  if (withoutUserinfo.startsWith("[")) {
    const end = withoutUserinfo.indexOf("]");
    return end < 0 ? null : withoutUserinfo.slice(1, end);
  }
  const colon = withoutUserinfo.lastIndexOf(":");
  return colon < 0 ? withoutUserinfo : withoutUserinfo.slice(0, colon);
}

function normalizeEndpoint(raw: string): NormalizedEndpoint {
  if (typeof raw !== "string" || raw.length === 0) throw invalidUrl("invalid_url");
  if (/\s/.test(raw)) throw invalidUrl("whitespace");
  if (raw.includes("?")) throw invalidUrl("query");
  if (raw.includes("#")) throw invalidUrl("fragment");
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw invalidUrl("invalid_url");
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") throw invalidUrl("scheme");
  if (url.username !== "" || url.password !== "") throw invalidUrl("userinfo");
  if (url.search !== "") throw invalidUrl("query");
  if (url.hash !== "") throw invalidUrl("fragment");
  const bracketedHostname = url.hostname;
  const hostname = bracketedHostname.startsWith("[") && bracketedHostname.endsWith("]")
    ? bracketedHostname.slice(1, -1)
    : bracketedHostname;
  if (hostname === "") throw invalidUrl("hostname");
  if (url.protocol === "http:" && !isLoopbackHostname(hostname)) throw invalidUrl("scheme");
  const originalHostname = rawHostname(raw);
  if (!originalHostname || originalHostname.includes("%")) throw invalidUrl("hostname");
  const literal = parseAddress(hostname);
  if (literal?.version === 4 && originalHostname !== literal.canonical) throw invalidUrl("hostname");
  if (!literal && /^(?:0x[0-9a-f]+|[0-9.]+)$/i.test(originalHostname) && isIP(hostname) === 4) {
    throw invalidUrl("hostname");
  }
  const port = url.port === "" ? (url.protocol === "http:" ? 80 : 443) : Number(url.port);
  if (!Number.isInteger(port) || port < 1 || port > 65_535) throw invalidUrl("port");

  let path = url.pathname.replace(/\/+$/, "");
  for (const suffix of ["/chat/completions", "/responses", "/messages"]) {
    if (path.endsWith(suffix)) {
      path = path.slice(0, -suffix.length).replace(/\/+$/, "");
      break;
    }
  }
  if (!path.endsWith("/models")) path += "/models";
  if (path === "") path = "/models";
  url.pathname = path;
  return {
    url,
    hostname: hostname.toLowerCase(),
    hostHeader: url.host,
    port,
    servername: literal ? undefined : hostname.toLowerCase(),
    scheme: url.protocol === "http:" ? "http" : "https"
  };
}

/**
 * `<base>/models` lists models for all four APIs, but each API authenticates
 * differently. Keys stay in headers — never in the URL — so they cannot leak
 * through request logs or diagnostics.
 */
function applyDiscoveryAuth(
  headers: Record<string, string>,
  api: ProviderApi,
  apiKey: string
): void {
  switch (api) {
    case "anthropic-messages":
      headers["x-api-key"] = apiKey;
      headers["anthropic-version"] = "2023-06-01";
      return;
    case "google-generative-ai":
      headers["x-goog-api-key"] = apiKey;
      return;
    default:
      headers.Authorization = `Bearer ${apiKey}`;
  }
}

function validateApiKey(apiKey: string | undefined): void {
  if (apiKey === undefined) return;
  if (apiKey.length === 0 || apiKey.length > 16_384 || /[\r\n]/.test(apiKey)) {
    throw failure("INVALID_ARGUMENT", "invalid provider discovery API key", { reason: "api_key" });
  }
}

const defaultLookup: ProviderDiscoveryLookup = async (hostname) => {
  return systemLookup(hostname, { all: true, verbatim: true });
};

function requestOverSocket(
  socket: Socket,
  options: ProviderDiscoveryConnectOptions,
  request: ProviderDiscoveryRequest,
  secure: boolean
): Promise<ProviderDiscoveryResponse> {
  return new Promise((resolve, reject) => {
    let responded = false;
    const client = secure ? httpsRequest : httpRequest;
    const outgoing = client({
      protocol: secure ? "https:" : "http:",
      hostname: options.hostname,
      port: options.port,
      method: "GET",
      path: request.path,
      headers: request.headers,
      agent: false,
      createConnection: () => socket as never,
      signal: request.signal
    }, (response) => {
      responded = true;
      resolve({
        statusCode: response.statusCode,
        headers: response.headers,
        body: response,
        close: () => response.destroy()
      });
    });
    outgoing.once("error", (error) => {
      if (!responded) reject(error);
    });
    outgoing.end();
  });
}

const defaultConnect: ProviderDiscoveryConnector = (options, validateRemoteAddress) => {
  return new Promise((resolve, reject) => {
    let settled = false;
    let tls: TLSSocket | undefined;
    const raw = tcpConnect({
      host: options.address,
      port: options.port,
      family: parseAddress(options.address)?.version ?? 4
    });
    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      options.signal.removeEventListener("abort", onAbort);
      tls?.destroy();
      raw.destroy();
      reject(error);
    };
    const onAbort = () => fail(timeoutFailure());
    options.signal.addEventListener("abort", onAbort, { once: true });
    raw.once("error", fail);
    raw.once("connect", () => {
      try {
        // This check is deliberately before ClientHello and before any HTTP header.
        validateRemoteAddress(raw.remoteAddress);
      } catch (error) {
        fail(error as Error);
        return;
      }
      if (options.scheme === "http") {
        // Loopback plain-HTTP gateway: the TCP socket itself is the transport.
        settled = true;
        options.signal.removeEventListener("abort", onAbort);
        resolve({
          remoteAddress: raw.remoteAddress,
          request: (request) => requestOverSocket(raw, options, request, false),
          close: () => raw.destroy()
        });
        return;
      }
      tls = tlsConnect({
        socket: raw,
        ...(options.servername === undefined ? {} : { servername: options.servername }),
        rejectUnauthorized: true,
        checkServerIdentity: (_hostname, certificate) => checkServerIdentity(options.hostname, certificate)
      });
      tls.once("error", fail);
      tls.once("secureConnect", () => {
        if (settled) return;
        try {
          validateRemoteAddress(tls?.remoteAddress);
        } catch (error) {
          fail(error as Error);
          return;
        }
        settled = true;
        options.signal.removeEventListener("abort", onAbort);
        const socket = tls;
        if (!socket) {
          reject(new Error("TLS socket unavailable"));
          return;
        }
        resolve({
          remoteAddress: socket.remoteAddress,
          request: (request) => requestOverSocket(socket, options, request, true),
          close: () => socket.destroy()
        });
      });
    });
  });
};

function networkFailure(error: unknown): ProviderDiscoveryError {
  const code = typeof error === "object" && error !== null && "code" in error
    ? String((error as { code: unknown }).code)
    : "";
  if (code === "ECONNREFUSED") {
    return failure("UPSTREAM_UNAVAILABLE", "upstream connection refused", { reason: "refused" });
  }
  if (code === "EPROTO" || code.startsWith("ERR_TLS") || code.includes("CERT") || code.startsWith("UNABLE_TO")) {
    return failure("UPSTREAM_UNAVAILABLE", "upstream TLS connection failed", { reason: "tls" });
  }
  return failure("UPSTREAM_UNAVAILABLE", "upstream network request failed", { reason: "network" });
}

function firstHeader(headers: IncomingHttpHeaders, name: string): string | undefined {
  const value = headers[name];
  return Array.isArray(value) ? value[0] : value;
}

function checkContentLength(headers: IncomingHttpHeaders): void {
  const raw = firstHeader(headers, "content-length");
  if (!raw || !/^\d+$/.test(raw)) return;
  if (BigInt(raw) > BigInt(PROVIDER_DISCOVERY_MAX_BYTES)) {
    throw failure("PAYLOAD_TOO_LARGE", "upstream response exceeds 2 MiB", {
      maxBytes: PROVIDER_DISCOVERY_MAX_BYTES
    });
  }
}

async function readResponseBytes(response: ProviderDiscoveryResponse, signal: AbortSignal): Promise<Buffer> {
  checkContentLength(response.headers);
  const encoding = firstHeader(response.headers, "content-encoding")?.trim().toLowerCase() ?? "identity";
  let stream: Readable = response.body;
  if (encoding === "gzip" || encoding === "x-gzip") {
    stream = response.body.pipe(createGunzip());
  } else if (encoding === "deflate") {
    stream = response.body.pipe(createInflate());
  } else if (encoding === "br") {
    stream = response.body.pipe(createBrotliDecompress());
  } else if (encoding !== "identity") {
    throw failure("UPSTREAM_RESPONSE_INVALID", "upstream response schema is invalid", { reason: "schema" });
  }
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    for await (const chunk of stream) {
      if (signal.aborted) throw timeoutFailure();
      const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as Uint8Array);
      total += buffer.length;
      if (total > PROVIDER_DISCOVERY_MAX_BYTES) {
        throw failure("PAYLOAD_TOO_LARGE", "upstream response exceeds 2 MiB", {
          maxBytes: PROVIDER_DISCOVERY_MAX_BYTES
        });
      }
      chunks.push(buffer);
    }
  } catch (error) {
    if (error instanceof ProviderDiscoveryError) throw error;
    if (signal.aborted) throw timeoutFailure();
    const code = typeof error === "object" && error !== null && "code" in error
      ? String((error as { code: unknown }).code)
      : "";
    if (code.startsWith("Z_") || code === "ERR_PADDING") {
      throw failure("UPSTREAM_RESPONSE_INVALID", "upstream response is not valid JSON", { reason: "invalid_json" });
    }
    throw failure("UPSTREAM_UNAVAILABLE", "upstream response stream failed", { reason: "network" });
  }
  if (signal.aborted) throw timeoutFailure();
  return Buffer.concat(chunks, total);
}

function record(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

function firstPositiveInteger(source: Record<string, unknown>, fields: readonly string[]): number | undefined {
  for (const field of fields) {
    const value = source[field];
    if (typeof value === "number" && Number.isSafeInteger(value) && value > 0) return value;
  }
  return undefined;
}

function modelNumber(model: Record<string, unknown>, fields: readonly string[], fallback: number): number {
  const direct = firstPositiveInteger(model, fields);
  if (direct !== undefined) return direct;
  for (const containerName of ["limits", "capabilities", "metadata"]) {
    const container = record(model[containerName]);
    if (!container) continue;
    const nested = firstPositiveInteger(container, fields);
    if (nested !== undefined) return nested;
  }
  return fallback;
}

function stringList(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const result: string[] = [];
  const seen = new Set<string>();
  for (const item of value) {
    if (typeof item !== "string" || item.trim() === "") continue;
    const normalized = item.trim();
    if (!seen.has(normalized)) {
      seen.add(normalized);
      result.push(normalized);
    }
  }
  return result;
}

const EFFORT_FIELDS = [
  "thinkingLevels",
  "thinking_levels",
  "effortLevels",
  "effort_levels",
  "supportedEffortLevels",
  "supported_effort_levels",
  "reasoningEfforts",
  "reasoning_efforts",
  "supportedReasoningEfforts",
  "supported_reasoning_efforts",
  "efforts"
] as const;

function thinkingLevels(model: Record<string, unknown>): string[] {
  for (const source of [model, record(model.reasoning), record(model.effort), record(model.capabilities)]) {
    if (!source) continue;
    for (const field of EFFORT_FIELDS) {
      const levels = stringList(source[field]);
      if (levels !== undefined) return levels;
    }
  }
  return [];
}

const DEFAULT_EFFORT_FIELDS = [
  "defaultThinkingLevel",
  "default_thinking_level",
  "defaultEffort",
  "default_effort",
  "defaultReasoningEffort",
  "default_reasoning_effort",
  "default"
] as const;

function defaultThinkingLevel(
  model: Record<string, unknown>,
  levels: readonly string[]
): string | null {
  for (const source of [model, record(model.reasoning), record(model.effort), record(model.capabilities)]) {
    if (!source) continue;
    for (const field of DEFAULT_EFFORT_FIELDS) {
      const value = source[field];
      if (typeof value === "string" && levels.includes(value)) return value;
    }
  }
  return null;
}

function imageCapabilityFrom(source: Record<string, unknown>): boolean | undefined {
  for (const field of ["supportsImages", "supports_images", "images", "imageInput", "image_input"]) {
    if (typeof source[field] === "boolean") return source[field];
  }
  for (const field of ["input", "inputModalities", "input_modalities"]) {
    const modalities = source[field];
    if (Array.isArray(modalities)) return modalities.includes("image");
  }
  return undefined;
}

function supportsImages(model: Record<string, unknown>): boolean {
  for (const source of [model, record(model.architecture), record(model.modalities), record(model.capabilities)]) {
    if (!source) continue;
    const capability = imageCapabilityFrom(source);
    if (capability !== undefined) return capability;
  }
  return false;
}

function modelId(model: Record<string, unknown>): string | null {
  for (const field of ["id", "slug", "name"]) {
    const value = model[field];
    if (typeof value !== "string") continue;
    const id = value.trim().replace(/^models\//, "");
    if (id !== "") return id;
  }
  return null;
}

function displayName(model: Record<string, unknown>, id: string): string {
  for (const field of ["display_name", "displayName", "name"]) {
    const value = model[field];
    if (typeof value === "string" && value.trim() !== "") return value.trim();
  }
  return id;
}

const CONTEXT_FIELDS = [
  "contextWindow",
  "context_window",
  "contextLength",
  "context_length",
  "contextSize",
  "context_size",
  "inputContextWindow",
  "input_context_window"
] as const;

const MAX_TOKEN_FIELDS = [
  "maxTokens",
  "max_tokens",
  "maxOutputTokens",
  "max_output_tokens",
  "maxCompletionTokens",
  "max_completion_tokens",
  "outputTokenLimit",
  "output_token_limit"
] as const;

function parseModel(raw: unknown): ProviderModel | null {
  const model = record(raw);
  if (!model) return null;
  const id = modelId(model);
  if (!id) return null;
  const levels = thinkingLevels(model);
  return {
    id,
    displayName: displayName(model, id),
    contextWindow: modelNumber(model, CONTEXT_FIELDS, DEFAULT_CONTEXT_WINDOW),
    maxTokens: modelNumber(model, MAX_TOKEN_FIELDS, DEFAULT_MAX_TOKENS),
    thinkingLevels: levels,
    defaultThinkingLevel: defaultThinkingLevel(model, levels),
    supportsImages: supportsImages(model)
  };
}

function parseModels(raw: unknown): ProviderModel[] {
  let rows: unknown[];
  if (Array.isArray(raw)) {
    rows = raw;
  } else {
    const envelope = record(raw);
    if (envelope && Array.isArray(envelope.data)) rows = envelope.data;
    else if (envelope && Array.isArray(envelope.models)) rows = envelope.models;
    else throw failure("UPSTREAM_RESPONSE_INVALID", "upstream response schema is invalid", { reason: "schema" });
  }
  const models: ProviderModel[] = [];
  const seen = new Set<string>();
  for (const row of rows) {
    if (seen.size >= PROVIDER_DISCOVERY_MAX_MODELS) break;
    const model = parseModel(row);
    if (!model || seen.has(model.id)) continue;
    seen.add(model.id);
    models.push(model);
  }
  if (models.length === 0) {
    throw failure("UPSTREAM_RESPONSE_INVALID", "upstream returned no valid models", { reason: "empty_list" });
  }
  models.sort((left, right) => left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
  return models;
}

async function parseResponse(response: ProviderDiscoveryResponse, signal: AbortSignal): Promise<ProviderDiscoveryResult> {
  const status = response.statusCode ?? 0;
  if (status >= 300 && status < 400) {
    throw failure("REDIRECT_FORBIDDEN", "upstream redirects are forbidden");
  }
  if (status < 200 || status >= 300) {
    throw failure("UPSTREAM_UNAVAILABLE", "upstream HTTP request failed", {
      reason: "upstream_http",
      upstreamStatus: status
    });
  }
  // A declared redirect-length body is still rejected before any stream read.
  checkContentLength(response.headers);
  const bytes = await readResponseBytes(response, signal);
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw failure("UPSTREAM_RESPONSE_INVALID", "upstream response is not valid JSON", { reason: "invalid_json" });
  }
  let raw: unknown;
  try {
    raw = JSON.parse(text) as unknown;
  } catch {
    throw failure("UPSTREAM_RESPONSE_INVALID", "upstream response is not valid JSON", { reason: "invalid_json" });
  }
  if (signal.aborted) throw timeoutFailure();
  return { models: parseModels(raw) };
}

async function executeDiscovery(
  input: ProviderDiscoveryInput,
  options: ProviderDiscoveryOptions,
  signal: AbortSignal,
  deadlineAt: number
): Promise<ProviderDiscoveryResult> {
  const assertDeadline = () => {
    if (signal.aborted || Date.now() >= deadlineAt) throw timeoutFailure();
  };
  assertDeadline();
  const endpoint = normalizeEndpoint(input.baseUrl);
  validateApiKey(input.apiKey);
  assertDeadline();
  const allowlist = new Set((options.testOnly?.allowPrivateHosts ?? []).map(canonicalAllowlistEntry));
  if (isLocalOrMetadataHostname(endpoint.hostname)
      && !isLoopbackHostname(endpoint.hostname)
      && !allowlist.has(canonicalAllowlistEntry(endpoint.hostname))) {
    throw rejected("private_address");
  }
  const lookup = options.testOnly?.lookup ?? defaultLookup;
  const connect = options.testOnly?.connect ?? defaultConnect;
  const literal = parseAddress(endpoint.hostname);
  let answers: readonly { address: string }[];
  if (literal) {
    answers = [{ address: literal.canonical }];
  } else {
    try {
      answers = await lookup(endpoint.hostname);
    } catch (error) {
      if (signal.aborted) throw timeoutFailure();
      if (error instanceof ProviderDiscoveryError) throw error;
      throw failure("UPSTREAM_UNAVAILABLE", "upstream DNS resolution failed", { reason: "dns" });
    }
  }
  if (signal.aborted) throw timeoutFailure();
  if (answers.length === 0) throw rejected("dns");
  const pinned = new Set<string>();
  for (const answer of answers) {
    const parsed = parseAddress(answer.address);
    if (!parsed) throw rejected("dns");
    const kind = addressKind(parsed);
    if (kind === "transition") throw rejected("private_address");
    if (kind === "private" && !privateAddressAllowed(endpoint.hostname, parsed, allowlist)) {
      throw rejected("private_address");
    }
    pinned.add(parsed.canonical);
  }
  if (pinned.size === 0) throw rejected("dns");

  const validateRemoteAddress = (remoteAddress: string | undefined): void => {
    if (!remoteAddress) throw rejected("public_address_changed");
    const parsed = parseAddress(remoteAddress);
    if (!parsed) throw rejected("public_address_changed");
    const kind = addressKind(parsed);
    if (kind === "transition") throw rejected("private_address");
    if (kind === "private" && !privateAddressAllowed(endpoint.hostname, parsed, allowlist)) {
      throw rejected("private_address");
    }
    if (!pinned.has(parsed.canonical)) throw rejected("public_address_changed");
  };

  const connections = new Set<ProviderDiscoveryConnection>();
  const closeOnAbort = () => {
    for (const connection of connections) connection.close();
  };
  signal.addEventListener("abort", closeOnAbort);
  try {
    let lastConnectionError: unknown;
    for (const address of pinned) {
      if (signal.aborted) throw timeoutFailure();
      const connectOptions: ProviderDiscoveryConnectOptions = {
        address,
        port: endpoint.port,
        hostname: endpoint.hostname,
        servername: endpoint.servername,
        rejectUnauthorized: true,
        signal,
        scheme: endpoint.scheme
      };
      let connection: ProviderDiscoveryConnection;
      try {
        connection = await connect(connectOptions, validateRemoteAddress);
      } catch (error) {
        if (signal.aborted) throw timeoutFailure();
        if (error instanceof ProviderDiscoveryError) throw error;
        lastConnectionError = error;
        continue;
      }
      connections.add(connection);
      try {
        validateRemoteAddress(connection.remoteAddress);
        const headers: Record<string, string> = {
          Accept: "application/json",
          Host: endpoint.hostHeader,
          "User-Agent": USER_AGENT
        };
        if (input.apiKey !== undefined) applyDiscoveryAuth(headers, providerApi(input.protocol), input.apiKey);
        let response: ProviderDiscoveryResponse;
        try {
          response = await connection.request({
            method: "GET",
            path: endpoint.url.pathname,
            headers,
            signal
          });
        } catch (error) {
          if (signal.aborted) throw timeoutFailure();
          if (error instanceof ProviderDiscoveryError) throw error;
          throw networkFailure(error);
        }
        try {
          const result = await parseResponse(response, signal);
          assertDeadline();
          return result;
        } finally {
          response.close();
        }
      } finally {
        connections.delete(connection);
        connection.close();
      }
    }
    throw networkFailure(lastConnectionError);
  } finally {
    signal.removeEventListener("abort", closeOnAbort);
    for (const connection of connections) connection.close();
    connections.clear();
  }
}

/**
 * Discover models without persisting credentials or discovered state. HostService resolves
 * providerId/authKind before calling this function; ad-hoc keys only flow to Authorization.
 */
export async function discoverProviderModels(
  input: ProviderDiscoveryInput,
  options: ProviderDiscoveryOptions = {}
): Promise<ProviderDiscoveryResult> {
  const controller = new AbortController();
  const deadlineAt = options.deadlineAt ?? Date.now() + PROVIDER_DISCOVERY_DEADLINE_MS;
  let timer: ReturnType<typeof setTimeout> | undefined;
  const deadline = new Promise<never>((_resolve, reject) => {
    timer = setTimeout(() => {
      controller.abort();
      reject(timeoutFailure());
    }, Math.max(0, deadlineAt - Date.now()));
  });
  try {
    const result = await Promise.race([executeDiscovery(input, options, controller.signal, deadlineAt), deadline]);
    if (Date.now() >= deadlineAt) throw timeoutFailure();
    return result;
  } catch (error) {
    if (error instanceof ProviderDiscoveryError) throw error;
    if (controller.signal.aborted) throw timeoutFailure();
    throw failure("INTERNAL", "provider discovery failed");
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    controller.abort();
  }
}
