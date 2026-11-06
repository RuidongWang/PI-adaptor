import { createHash, randomUUID } from "node:crypto";
import type { IncomingMessage, ServerResponse } from "node:http";
import { createServer as createHttpsServer } from "node:https";
import type { Duplex } from "node:stream";
import { WebSocketServer, type WebSocket } from "ws";
import type { DirectConfig } from "../config.js";
import { HostError, asHostError } from "../errors.js";
import { loadDirectTlsIdentity, type DirectTlsIdentity } from "../security/direct-tls.js";
import { HostService } from "./host-service.js";

const RACP_PATH = "/v1/racp/ws";
const V1_PROTOCOL = "pi-racp.v1.jsonrpc";
const V2_PROTOCOL = "pi-racp.v2.jsonrpc";
type RacpProtocol = typeof V1_PROTOCOL | typeof V2_PROTOCOL;
type ListenerKind = "loopback" | "direct";
type DirectHandshake = { stage: "initialize" | "initialized" | "ready" };

type RequestFrame = {
  jsonrpc: "2.0";
  id?: string | number;
  method: string;
  params?: unknown;
};

type RegistryEntry = {
  identity: string;
  socket: WebSocket;
  deviceId: string;
  listener: ListenerKind;
  credentialHash: string;
  subscriptions: Set<string>;
};

/** One registry instance must be shared by both listeners of a HostService. */
export class SocketDeviceRegistry {
  private readonly bySocket = new Map<WebSocket, RegistryEntry>();
  private readonly byIdentity = new Map<string, RegistryEntry>();
  private readonly releasedSockets = new WeakSet<WebSocket>();

  constructor(private readonly service: HostService) {}

  authenticate(socket: WebSocket, deviceId: string, listener: ListenerKind, credentialHash: string): RegistryEntry | null {
    if (this.releasedSockets.has(socket)) return null;
    const existing = this.bySocket.get(socket);
    if (existing) {
      existing.deviceId = deviceId;
      existing.credentialHash = credentialHash;
      return existing;
    }
    const entry: RegistryEntry = {
      identity: randomUUID(),
      socket,
      deviceId,
      listener,
      credentialHash,
      subscriptions: new Set()
    };
    this.bySocket.set(socket, entry);
    this.byIdentity.set(entry.identity, entry);
    return entry;
  }

  addSubscription(socket: WebSocket, subscriptionId: string): void {
    this.bySocket.get(socket)?.subscriptions.add(subscriptionId);
  }

  removeSubscription(socket: WebSocket, subscriptionId: string): boolean {
    const removed = this.bySocket.get(socket)?.subscriptions.delete(subscriptionId) ?? false;
    if (removed) this.service.removeSubscription(subscriptionId);
    return removed;
  }

  release(socket: WebSocket): void {
    this.releasedSockets.add(socket);
    const entry = this.bySocket.get(socket);
    if (!entry) return;
    // Identity comparison makes a delayed close harmless if an entry was replaced.
    this.bySocket.delete(socket);
    if (this.byIdentity.get(entry.identity) === entry) this.byIdentity.delete(entry.identity);
    for (const id of entry.subscriptions) this.service.removeSubscription(id);
    entry.subscriptions.clear();
  }

  private closeEntry(entry: RegistryEntry): void {
    for (const subscriptionId of entry.subscriptions) {
      send(entry.socket, {
        jsonrpc: "2.0",
        method: "events/closed",
        params: { subscriptionId, code: "UNAUTHORIZED", message: "device revoked" }
      });
    }
    // Remove business state before initiating close so peer-observed closure can
    // never expose stale subscriptions. A delayed close is a no-op by identity.
    this.release(entry.socket);
    entry.socket.close(1008, "device revoked");
  }

  closeDevice(deviceId: string): void {
    for (const entry of [...this.bySocket.values()]) {
      if (entry.deviceId === deviceId) this.closeEntry(entry);
    }
  }

  closeCredential(deviceId: string, credentialHash: string): void {
    for (const entry of [...this.bySocket.values()]) {
      if (entry.deviceId === deviceId && entry.credentialHash === credentialHash) this.closeEntry(entry);
    }
  }
}

function tokenFrom(request: IncomingMessage): string | null {
  const header = request.headers.authorization;
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice("Bearer ".length);
}

function credentialHash(token: string): string {
  return createHash("sha256").update(token).digest("hex");
}

function send(socket: WebSocket, value: unknown): void {
  if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(value));
}

export type RunningHostServer = {
  port: number;
  close(): Promise<void>;
};

export type DirectTrustMetadata = {
  certificateSha256: string;
  notBefore: string;
  notAfter: string;
};

export type RunningDirectServer = RunningHostServer & {
  trust: DirectTrustMetadata;
};

export async function startWebSocketServer(
  service: HostService,
  port: number,
  registry = new SocketDeviceRegistry(service)
): Promise<RunningHostServer> {
  const server = new WebSocketServer({
    host: "127.0.0.1",
    port,
    maxPayload: 1024 * 1024,
    verifyClient: (info, done) => {
      if (info.req.url === RACP_PATH) {
        done(true);
        return;
      }
      done(false, 404, "Not Found");
    }
  });
  await new Promise<void>((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
  });
  const sockets = new Set<WebSocket>();
  server.on("connection", (socket, request) => {
    sockets.add(socket);
    attachConnection(service, registry, socket, request, "loopback");
    socket.on("close", () => sockets.delete(socket));
  });
  return {
    port: (server.address() as { port: number }).port,
    async close() {
      for (const socket of sockets) socket.close();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  };
}

function httpErrorBody(code: string, reason?: string, retryAfterMs?: number): string {
  return JSON.stringify({
    code,
    requestId: `req_${randomUUID()}`,
    ...(retryAfterMs === undefined ? {} : { retryAfterMs }),
    ...(reason === undefined ? {} : { reason })
  });
}

function respondHttp(
  response: ServerResponse,
  status: number,
  code: string,
  reason?: string,
  retryAfterMs?: number,
  onComplete?: () => void
): void {
  const body = httpErrorBody(code, reason, retryAfterMs);
  response.writeHead(status, {
    "Content-Type": "application/json",
    "Content-Length": Buffer.byteLength(body),
    Connection: "close"
  });
  response.end(body, onComplete);
}

function rejectUpgrade(
  socket: Duplex,
  status: number,
  code: string,
  reason?: string,
  retryAfterMs?: number,
  onComplete?: () => void
): void {
  if (socket.destroyed || !socket.writable) {
    onComplete?.();
    socket.destroy();
    return;
  }
  const body = httpErrorBody(code, reason, retryAfterMs);
  const response = [
    `HTTP/1.1 ${status} ${code}`,
    "Content-Type: application/json",
    `Content-Length: ${Buffer.byteLength(body)}`,
    "Connection: close",
    "",
    body
  ].join("\r\n");
  socket.write(response, () => {
    onComplete?.();
    socket.destroy();
  });
}

function validWebSocketKey(value: string | undefined): boolean {
  if (!value || !/^[A-Za-z0-9+/]{22}==$/.test(value)) return false;
  return Buffer.from(value, "base64").length === 16;
}

function requestedProtocol(request: IncomingMessage): RacpProtocol | null {
  const raw = request.headers["sec-websocket-protocol"];
  if (!raw) return null;
  const values = raw.split(",").map((value) => value.trim()).filter(Boolean);
  if (values.length !== 1) return null;
  return values[0] === V1_PROTOCOL || values[0] === V2_PROTOCOL ? values[0] : null;
}

function trustFrom(identity: DirectTlsIdentity): DirectTrustMetadata {
  return {
    certificateSha256: identity.certificateSha256,
    notBefore: identity.notBefore,
    notAfter: identity.notAfter
  };
}

type FixedWindow = { startedAt: number; count: number };
type RateLimit = { count: number; windowMs: number };

function consumeFixedWindow(window: FixedWindow, limit: RateLimit, now = Date.now()): { allowed: boolean; retryAfterMs: number } {
  if (now - window.startedAt >= limit.windowMs) {
    window.startedAt = now;
    window.count = 0;
  }
  window.count++;
  const retryAfterMs = Math.max(1, window.startedAt + limit.windowMs - now);
  return { allowed: window.count <= limit.count, retryAfterMs };
}

export class DirectPreAuthRateLimiter {
  private readonly windows = new Map<string, FixedWindow>();

  constructor(private readonly limit: RateLimit, private readonly maxWindows = 1024) {
    if (!Number.isInteger(maxWindows) || maxWindows < 1) throw new Error("maxWindows must be positive");
  }

  get size(): number {
    return this.windows.size;
  }

  consume(remote: string, now = Date.now()): { allowed: boolean; retryAfterMs: number } {
    for (const [key, window] of this.windows) {
      if (now - window.startedAt >= this.limit.windowMs) this.windows.delete(key);
    }
    let window = this.windows.get(remote);
    if (window) {
      this.windows.delete(remote);
    } else {
      while (this.windows.size >= this.maxWindows) {
        const oldest = this.windows.keys().next().value as string | undefined;
        if (oldest === undefined) break;
        this.windows.delete(oldest);
      }
      window = { startedAt: now, count: 0 };
    }
    this.windows.set(remote, window);
    return consumeFixedWindow(window, this.limit, now);
  }

  clear(): void {
    this.windows.clear();
  }
}

function requestIdFrom(raw: WebSocket.RawData): string | number | null {
  try {
    const value = JSON.parse(raw.toString()) as { id?: unknown };
    return typeof value.id === "string" || typeof value.id === "number" ? value.id : null;
  } catch {
    return null;
  }
}

type DirectConnectionState = {
  socket: Duplex;
  admitted: boolean;
  secure: boolean;
  upgraded: boolean;
  responded: boolean;
  timeout: NodeJS.Timeout | undefined;
};

function connectionKey(socket: Duplex): string {
  const remote = socket as Duplex & { remoteAddress?: string; remotePort?: number };
  return `${remote.remoteAddress ?? "unknown"}:${remote.remotePort ?? 0}`;
}

export async function startDirectWebSocketServer(
  service: HostService,
  config: DirectConfig,
  registry = new SocketDeviceRegistry(service)
): Promise<RunningDirectServer> {
  if (!config.enabled || !config.host) throw new Error("direct listener requires enabled config and an explicit host");
  const identity = await loadDirectTlsIdentity(config);
  const sockets = new Set<WebSocket>();
  const pending = new Map<string, DirectConnectionState>();
  const authenticatedRaw = new Map<string, Duplex>();
  const rateLimit = { count: config.messageRateCount, windowMs: config.messageRateWindowMs };
  const preAuthLimiter = new DirectPreAuthRateLimiter(rateLimit);
  const upgrades = new WeakMap<IncomingMessage, { protocol: RacpProtocol; deviceId: string }>();
  const wss = new WebSocketServer({ noServer: true, maxPayload: 1024 * 1024 });
  const clearTimer = (state: DirectConnectionState) => {
    if (state.timeout) clearTimeout(state.timeout);
    state.timeout = undefined;
  };
  const cleanupConnection = (key: string, state: DirectConnectionState, socket: Duplex) => {
    clearTimer(state);
    if (pending.get(key) === state) pending.delete(key);
    if (authenticatedRaw.get(key) === socket) authenticatedRaw.delete(key);
  };
  const reject = (socket: Duplex, status: number, code: string, reason?: string, retryAfterMs?: number) => {
    const key = connectionKey(socket);
    const state = pending.get(key);
    if (authenticatedRaw.has(key) || state?.upgraded || state?.responded) {
      if (state) cleanupConnection(key, state, socket);
      socket.destroy();
      return;
    }
    if (state) {
      state.responded = true;
      clearTimer(state);
    }
    rejectUpgrade(
      socket,
      status,
      code,
      reason,
      retryAfterMs,
      state ? () => cleanupConnection(key, state, socket) : undefined
    );
  };

  const httpsServer = createHttpsServer({
    cert: identity.certificatePem,
    key: identity.privateKeyPem
  }, (request, response) => {
    const key = connectionKey(request.socket);
    const state = pending.get(key);
    if (state) {
      state.responded = true;
      clearTimer(state);
    }
    const onComplete = state ? () => cleanupConnection(key, state, request.socket) : undefined;
    if (request.url !== RACP_PATH) {
      respondHttp(response, 404, "NOT_FOUND", undefined, undefined, onComplete);
    } else {
      respondHttp(response, 426, "UPGRADE_REQUIRED", undefined, undefined, onComplete);
    }
  });
  httpsServer.on("connection", (socket) => {
    const key = connectionKey(socket);
    const admitted = authenticatedRaw.size + [...pending.values()].filter((state) => state.admitted).length < config.maxConnections;
    if (!admitted) {
      // The contract allows pre-101 TCP/TLS abortion. Do not let overflow sockets
      // allocate TLS or timer state beyond N while waiting for an Upgrade or T.
      socket.destroy();
      return;
    }
    const state: DirectConnectionState = { socket, admitted, secure: false, upgraded: false, responded: false, timeout: undefined };
    pending.set(key, state);
    state.timeout = setTimeout(() => {
      if (state.upgraded || state.responded || state.socket.destroyed) return;
      if (state.secure) {
        reject(state.socket, 429, "RATE_LIMITED", "authentication_timeout", 1000);
      } else {
        cleanupConnection(key, state, state.socket);
        state.socket.destroy();
      }
    }, config.unauthenticatedTimeoutMs);
    state.timeout.unref();
    socket.once("close", () => cleanupConnection(key, state, socket));
  });
  httpsServer.on("secureConnection", (socket) => {
    const key = connectionKey(socket);
    const state = pending.get(key);
    if (!state) {
      socket.destroy();
      return;
    }
    state.socket = socket;
    state.secure = true;
    socket.once("close", () => cleanupConnection(key, state, socket));
    // N is rejected by the explicit upgrade handler once an HTTP response is safe.
  });
  httpsServer.on("clientError", (_error, socket) => socket.destroy());
  wss.on("connection", (socket, request) => {
    const upgrade = upgrades.get(request);
    if (!upgrade) {
      socket.close(1008);
      return;
    }
    sockets.add(socket);
    registry.authenticate(socket, upgrade.deviceId, "direct", credentialHash(tokenFrom(request)!));
    attachConnection(service, registry, socket, request, "direct", upgrade.protocol, rateLimit);
    socket.on("close", () => sockets.delete(socket));
  });

  httpsServer.on("upgrade", (request, socket, head) => {
    void (async () => {
      try {
        if (request.url !== RACP_PATH) {
          reject(socket, 404, "NOT_FOUND");
          return;
        }
        const connection = request.headers.connection?.split(",").map((token) => token.trim().toLowerCase()) ?? [];
        if (
          request.method !== "GET" ||
          request.headers.upgrade?.toLowerCase() !== "websocket" ||
          !connection.includes("upgrade") ||
          request.headers["sec-websocket-version"] !== "13" ||
          !validWebSocketKey(request.headers["sec-websocket-key"])
        ) {
          reject(socket, 426, "UPGRADE_REQUIRED");
          return;
        }
        const protocol = requestedProtocol(request);
        if (!protocol) {
          reject(socket, 400, "PROTOCOL_MISMATCH");
          return;
        }
        const key = connectionKey(socket);
        const state = pending.get(key);
        if (!state?.admitted) {
          reject(socket, 429, "RATE_LIMITED", "connection_limit", 1000);
          return;
        }
        const remote = (socket as Duplex & { remoteAddress?: string }).remoteAddress ?? "unknown";
        const admission = preAuthLimiter.consume(remote);
        if (!admission.allowed) {
          reject(socket, 429, "RATE_LIMITED", "message_rate", admission.retryAfterMs);
          return;
        }
        const token = tokenFrom(request);
        if (!token || !token.startsWith("pdt2.") || token.length === 5 || /\s/.test(token)) {
          reject(socket, 401, "UNAUTHORIZED");
          return;
        }
        let device;
        try {
          device = await service.tokens.authenticate(token);
        } catch (error) {
          if (error instanceof HostError && error.code === "UNAUTHORIZED") {
            reject(socket, 401, "UNAUTHORIZED");
          } else {
            reject(socket, 503, "INTERNAL");
          }
          return;
        }
        if (socket.destroyed || !socket.writable || state.responded) {
          socket.destroy();
          return;
        }
        state.upgraded = true;
        state.socket = socket;
        cleanupConnection(key, state, socket);
        authenticatedRaw.set(key, socket);
        upgrades.set(request, { protocol, deviceId: device.deviceId });
        wss.handleUpgrade(request, socket, head, (webSocket) => {
          wss.emit("connection", webSocket, request);
        });
      } catch {
        reject(socket, 503, "INTERNAL");
      }
    })();
  });

  try {
    await new Promise<void>((resolve, reject) => {
      const onError = (error: Error) => reject(error);
      httpsServer.once("error", onError);
      httpsServer.listen(config.port, config.host, () => {
        httpsServer.off("error", onError);
        resolve();
      });
    });
  } catch (error) {
    for (const state of pending.values()) {
      clearTimer(state);
      state.socket.destroy();
    }
    wss.close();
    throw error;
  }
  const address = httpsServer.address();
  if (!address || typeof address === "string") throw new Error("direct listener did not expose a TCP port");
  let closePromise: Promise<void> | undefined;
  return {
    port: address.port,
    trust: trustFrom(identity),
    close() {
      closePromise ??= (async () => {
        for (const socket of sockets) socket.close();
        for (const state of pending.values()) {
          clearTimer(state);
          state.socket.destroy();
        }
        for (const socket of authenticatedRaw.values()) socket.destroy();
        pending.clear();
        authenticatedRaw.clear();
        preAuthLimiter.clear();
        await new Promise<void>((resolve) => wss.close(() => resolve()));
        await new Promise<void>((resolve) => httpsServer.close(() => resolve()));
      })();
      return closePromise;
    }
  };
}

function attachConnection(
  service: HostService,
  registry: SocketDeviceRegistry,
  socket: WebSocket,
  request: IncomingMessage,
  listener: ListenerKind,
  protocol?: RacpProtocol,
  rateLimit?: RateLimit
): void {
  socket.on("error", () => undefined);
  socket.on("close", () => registry.release(socket));
  const token = tokenFrom(request);
  const handshake = listener === "direct" ? { stage: "initialize" } as DirectHandshake : undefined;
  const window = rateLimit ? { startedAt: Date.now(), count: 0 } : undefined;
  socket.on("message", (raw, isBinary) => {
    if (rateLimit && window) {
      const rate = consumeFixedWindow(window, rateLimit);
      if (!rate.allowed) {
        const response = new HostError("RATE_LIMITED", "rate limited", { retryAfterMs: rate.retryAfterMs })
          .toJSONRPC(requestIdFrom(raw));
        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify(response), () => socket.close(1008, "rate limited"));
        } else {
          socket.close(1008, "rate limited");
        }
        return;
      }
    }
    if (isBinary) {
      socket.close(1003, "text frames only");
      return;
    }
    void handleMessage(service, registry, socket, token, raw.toString(), listener, protocol, handshake);
  });
}

async function handleMessage(
  service: HostService,
  registry: SocketDeviceRegistry,
  socket: WebSocket,
  token: string | null,
  raw: string,
  listener: ListenerKind,
  protocol?: RacpProtocol,
  handshake?: DirectHandshake
): Promise<void> {
  let frame: RequestFrame;
  try {
    frame = JSON.parse(raw) as RequestFrame;
  } catch {
    send(socket, {
      jsonrpc: "2.0",
      id: null,
      error: { code: -32700, message: "parse error" }
    });
    return;
  }
  if (!frame || typeof frame !== "object" || Array.isArray(frame) || frame.jsonrpc !== "2.0" || typeof frame.method !== "string") {
    send(socket, {
      jsonrpc: "2.0",
      id: frame?.id ?? null,
      error: { code: -32600, message: "invalid request" }
    });
    return;
  }
  try {
    let auth = null;
    if (listener === "direct") {
      if (!token) throw new HostError("UNAUTHORIZED", "a device token is required");
      auth = { device: await service.tokens.authenticate(token) };
      if (socket.readyState !== socket.OPEN) return;
      registry.authenticate(socket, auth.device.deviceId, "direct", credentialHash(token));
      if (frame.method === "connection/pair") {
        const response = new HostError("FORBIDDEN", "pairing is forbidden on the direct listener").toJSONRPC(frame.id ?? null);
        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify(response), () => {
            registry.release(socket);
            socket.close(1008);
          });
        } else {
          registry.release(socket);
        }
        return;
      }
      if (!handshake) throw new HostError("INTERNAL", "direct handshake state is missing");
      if (frame.method === "notifications/initialized") {
        if (handshake.stage !== "initialized" || frame.id !== undefined) {
          throw new HostError("PROTOCOL_MISMATCH", "notifications/initialized is invalid at this handshake stage");
        }
        handshake.stage = "ready";
        return;
      }
      if (handshake.stage === "initialize") {
        const expected = protocol === V1_PROTOCOL ? "1.0" : "2.0.0";
        const actual = (frame.params as { protocolVersion?: unknown } | undefined)?.protocolVersion;
        if (frame.method !== "connection/initialize" || actual !== expected) {
          throw new HostError("PROTOCOL_MISMATCH", "connection/initialize with a matching protocolVersion is required");
        }
      } else if (handshake.stage === "initialized") {
        throw new HostError("PROTOCOL_MISMATCH", "notifications/initialized is required before business requests");
      } else if (frame.method === "connection/initialize") {
        throw new HostError("PROTOCOL_MISMATCH", "connection/initialize is already complete");
      }
    } else if (frame.method === "connection/initialize") {
      auth = null;
    } else if (token && token.startsWith("pdt2.")) {
      auth = { device: await service.tokens.authenticate(token) };
      if (socket.readyState !== socket.OPEN) return;
      registry.authenticate(socket, auth.device.deviceId, "loopback", credentialHash(token));
    } else if (!token || !token.startsWith("ppt2.")) {
      throw new HostError("UNAUTHORIZED", "a device or pairing token is required");
    }
    // The frozen v1 handshake sends `notifications/initialized` (a notification:
    // no id, no response) after `connection/initialize`. It carries no authority
    // and must never be dispatched as a business method on the loopback listener.
    // Returning an INVALID_ARGUMENT error here breaks the contract: strict clients
    // treat an error frame for the initialization notification as a handshake
    // failure and close the socket immediately after it was established. Accept it
    // for both a valid device token (authenticated above) and a pairing token.
    if (listener === "loopback" && frame.method === "notifications/initialized") {
      if (frame.id !== undefined && frame.id !== null) {
        throw new HostError("PROTOCOL_MISMATCH", "notifications/initialized must not carry an id");
      }
      return;
    }
    let rotatedCredential: { deviceId: string; credentialHash: string } | undefined;
    const result = await service.handle(
      frame.method,
      frame.params,
      auth,
      listener === "loopback" && frame.method === "connection/pair" && token?.startsWith("ppt2.") ? token : undefined,
      {
        rotationConfirmed: (deviceId, previousCredentialHash) => {
          rotatedCredential = { deviceId, credentialHash: previousCredentialHash };
        }
      }
    );
    if (listener === "direct" && frame.method === "connection/initialize" && handshake?.stage === "initialize") {
      handshake.stage = "initialized";
    }
    let closeRevokedSockets = false;
    if (frame.method === "connection/revoke" && result && typeof result === "object") {
      const revoked = (result as { revoked?: boolean }).revoked;
      const targetDevice = (frame.params as { deviceId?: string } | undefined)?.deviceId;
      closeRevokedSockets = revoked === true && typeof targetDevice === "string";
    }
    if (frame.method === "events/subscribe" && result && typeof result === "object") {
      const subscription = result as { subscriptionId: string; replay?: unknown[] };
      if (socket.readyState !== socket.OPEN) {
        service.removeSubscription(subscription.subscriptionId);
        return;
      }
      registry.addSubscription(socket, subscription.subscriptionId);
      for (const event of subscription.replay ?? []) {
        send(socket, { jsonrpc: "2.0", method: "events/event", params: { event } });
      }
      service.setSubscriptionSink(subscription.subscriptionId, (event) => {
        send(socket, { jsonrpc: "2.0", method: "events/event", params: { event } });
      });
      delete subscription.replay;
    }
    if (frame.method === "events/unsubscribe") {
      const id = (frame.params as { subscriptionId?: unknown } | undefined)?.subscriptionId;
      if (typeof id === "string") registry.removeSubscription(socket, id);
    }
    const response = { jsonrpc: "2.0", id: frame.id, result };
    if (closeRevokedSockets || rotatedCredential) {
      const closeSockets = () => {
        if (closeRevokedSockets) {
          registry.closeDevice((frame.params as { deviceId: string }).deviceId);
        }
        if (rotatedCredential) {
          registry.closeCredential(rotatedCredential.deviceId, rotatedCredential.credentialHash);
        }
      };
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify(response), closeSockets);
      } else {
        closeSockets();
      }
    } else {
      send(socket, response);
    }
  } catch (error) {
    const hostError = asHostError(error);
    const response = hostError.toJSONRPC(frame.id ?? null);
    if (hostError.code === "UNAUTHORIZED") {
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify(response), () => {
          registry.release(socket);
          socket.close(1008, "device revoked");
        });
      } else {
        registry.release(socket);
      }
      return;
    }
    send(socket, response);
  }
}
