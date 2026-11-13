import { createHash, randomBytes } from "node:crypto";
import { execFile, spawn, type ChildProcess } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, stat, symlink, writeFile } from "node:fs/promises";
import { createServer as createTcpServer } from "node:net";
import { connect as tlsConnect } from "node:tls";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { request as httpsRequest } from "node:https";
import { promisify } from "node:util";
import WebSocket from "ws";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig, type HostConfig } from "../src/config.js";
import { loadDirectTlsIdentity } from "../src/security/direct-tls.js";
import { HostService } from "../src/server/host-service.js";
import { SocketDeviceRegistry, startDirectWebSocketServer, startWebSocketServer, type RunningDirectServer } from "../src/server/ws.js";

const execFileAsync = promisify(execFile);
const DIRECT_PATH = "/v1/racp/ws";
const V1 = "pi-racp.v1.jsonrpc";
const V2 = "pi-racp.v2.jsonrpc";

type Frame = { id?: number; result?: any; error?: any; method?: string; params?: any };
type TlsFixture = { root: string; certificateFile: string; privateKeyFile: string; certificatePem: string };
type DirectFixture = TlsFixture & {
  config: HostConfig;
  service: HostService;
  device: { deviceId: string; deviceToken: string };
  pairingToken: string;
  registry: SocketDeviceRegistry;
  server: RunningDirectServer;
  url: string;
};

const cleanups: Array<() => Promise<void> | void> = [];
afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

async function freePort(): Promise<number> {
  const server = createTcpServer();
  await new Promise<void>((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", resolve);
  });
  const address = server.address();
  if (!address || typeof address === "string") throw new Error("missing test port");
  const port = address.port;
  await new Promise<void>((resolve) => server.close(() => resolve()));
  return port;
}

async function makeCertificate(overrides: {
  basicConstraints?: string;
  keyUsage?: string;
  extendedKeyUsage?: string;
  subjectAltName?: string;
  rsaBits?: number;
  signatureHash?: string;
} = {}): Promise<TlsFixture> {
  const { rsaBits = 2048, signatureHash = "sha256", ...extensionOverrides } = overrides;
  const root = await mkdtemp(join(tmpdir(), "pi-adaptor-direct-tls-"));
  const tlsDir = join(root, "tls");
  await mkdir(tlsDir, { mode: 0o700 });
  await chmod(tlsDir, 0o700);
  const certificateFile = join(tlsDir, "direct-cert.pem");
  const privateKeyFile = join(tlsDir, "direct-key.pem");
  const extensions = {
    basicConstraints: "critical,CA:FALSE",
    keyUsage: "critical,digitalSignature,keyEncipherment",
    extendedKeyUsage: "serverAuth",
    subjectAltName: "DNS:localhost,IP:127.0.0.1",
    ...extensionOverrides
  };
  const args = [
    "req", "-x509", "-newkey", `rsa:${rsaBits}`, `-${signatureHash}`, "-days", "2", "-nodes",
    "-keyout", privateKeyFile,
    "-out", certificateFile,
    "-subj", "/CN=pi-adaptor"
  ];
  for (const [name, value] of Object.entries(extensions)) {
    if (value) args.push("-addext", `${name}=${value}`);
  }
  await execFileAsync("openssl", args);
  await chmod(privateKeyFile, 0o600);
  return { root, certificateFile, privateKeyFile, certificatePem: await readFile(certificateFile, "utf8") };
}

async function makeDirectFixture(overrides: Partial<HostConfig["direct"]> = {}): Promise<DirectFixture> {
  const tls = await makeCertificate();
  const port = await freePort();
  const config = parseHostConfig([
    "--home", tls.root,
    "--data-dir", join(tls.root, "data"),
    "--agent-dir", join(tls.root, "agent"),
    "--port", "0",
    "--direct",
    "--direct-host", "127.0.0.1",
    "--direct-port", String(port),
    "--direct-cert", tls.certificateFile,
    "--direct-key", tls.privateKeyFile
  ], {}, tls.root);
  Object.assign(config.direct, overrides);
  await ensureHostDirectories(config);
  const service = new HostService(config, new DeterministicAgentDriver());
  await service.init();
  const pairing = await service.createPairingToken();
  const device = await service.tokens.pair(pairing.token, "direct-test");
  const unusedPairing = await service.createPairingToken();
  const registry = new SocketDeviceRegistry(service);
  const server = await startDirectWebSocketServer(service, config.direct, registry);
  cleanups.push(() => server.close());
  return {
    ...tls,
    config,
    service,
    device,
    pairingToken: unusedPairing.token,
    registry,
    server,
    url: `wss://127.0.0.1:${server.port}${DIRECT_PATH}`
  };
}

function connectDirect(
  fixture: DirectFixture,
  protocol = V1,
  token = fixture.device.deviceToken
): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(fixture.url, protocol, {
      ca: fixture.certificatePem,
      headers: { Authorization: `Bearer ${token}` }
    });
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
  });
}

function closeSocket(socket: WebSocket): Promise<void> {
  if (socket.readyState === WebSocket.CLOSED) return Promise.resolve();
  return new Promise((resolve) => {
    socket.once("close", () => resolve());
    socket.close();
  });
}

function rpc(socket: WebSocket, id: number, method: string, params: unknown = {}): Promise<Frame> {
  return new Promise((resolve, reject) => {
    const onMessage = (raw: WebSocket.RawData) => {
      const frame = JSON.parse(raw.toString()) as Frame;
      if (frame.id !== id) return;
      cleanup();
      resolve(frame);
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    const onClose = () => {
      cleanup();
      reject(new Error(`socket closed before response ${id}`));
    };
    const cleanup = () => {
      socket.off("message", onMessage);
      socket.off("error", onError);
      socket.off("close", onClose);
    };
    socket.on("message", onMessage);
    socket.once("error", onError);
    socket.once("close", onClose);
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

function notifyInitialized(socket: WebSocket): void {
  socket.send(JSON.stringify({ jsonrpc: "2.0", method: "notifications/initialized", params: {} }));
}

async function initializeDirect(socket: WebSocket, id: number, protocolVersion: "1.0" | "2.0.0"): Promise<Frame> {
  const initialized = await rpc(socket, id, "connection/initialize", { protocolVersion });
  expect(initialized.error).toBeUndefined();
  notifyInitialized(socket);
  return initialized;
}

function upgradeError(
  fixture: DirectFixture,
  options: { path?: string; token?: string; protocol?: string } = {}
): Promise<{ status: number; body: any }> {
  return new Promise((resolve, reject) => {
    const request = httpsRequest({
      host: "127.0.0.1",
      port: fixture.server.port,
      path: options.path ?? DIRECT_PATH,
      method: "GET",
      ca: fixture.certificatePem,
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": randomBytes(16).toString("base64"),
        "Sec-WebSocket-Protocol": options.protocol ?? V1,
        ...(options.token === undefined ? {} : { Authorization: `Bearer ${options.token}` })
      }
    }, (response) => {
      let raw = "";
      response.setEncoding("utf8");
      response.on("data", (chunk: string) => { raw += chunk; });
      response.on("end", () => resolve({ status: response.statusCode ?? 0, body: JSON.parse(raw) }));
    });
    request.once("upgrade", (response, socket) => {
      socket.destroy();
      resolve({ status: response.statusCode ?? 101, body: null });
    });
    request.once("error", reject);
    request.end();
  });
}

function spawnHost(args: string[]): {
  child: ChildProcess;
  lines: string[];
  stderr: () => string;
  waitFor: (predicate: () => boolean) => Promise<void>;
} {
  const child = spawn(process.execPath, ["--import", "tsx", "src/main.ts", ...args], {
    cwd: join(import.meta.dirname, ".."),
    env: { ...process.env, PI_ADAPTOR_DETERMINISTIC: "1" },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const lines: string[] = [];
  let pending = "";
  let stderr = "";
  child.stdout!.setEncoding("utf8");
  child.stdout!.on("data", (chunk: string) => {
    pending += chunk;
    while (pending.includes("\n")) {
      const index = pending.indexOf("\n");
      lines.push(pending.slice(0, index));
      pending = pending.slice(index + 1);
    }
  });
  child.stderr!.setEncoding("utf8");
  child.stderr!.on("data", (chunk: string) => { stderr += chunk; });
  cleanups.push(() => new Promise<void>((resolve) => {
    if (child.exitCode !== null || child.signalCode !== null) {
      resolve();
      return;
    }
    const timer = setTimeout(resolve, 2_000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
    child.kill("SIGTERM");
  }));
  return {
    child,
    lines,
    stderr: () => stderr,
    async waitFor(predicate) {
      const deadline = Date.now() + 8_000;
      while (!predicate()) {
        if (Date.now() >= deadline) throw new Error(`timed out waiting for host output: ${lines.join("\n")}\n${stderr}`);
        await new Promise((resolve) => setTimeout(resolve, 20));
      }
    }
  };
}

function payload(lines: string[], prefix: string): any {
  const line = lines.find((candidate) => candidate.startsWith(prefix));
  if (!line) throw new Error(`missing ${prefix}`);
  return JSON.parse(line.slice(prefix.length));
}

function identityConfig(tls: TlsFixture, certificateFile = tls.certificateFile, privateKeyFile = tls.privateKeyFile): HostConfig {
  return parseHostConfig([
    "--direct",
    "--direct-host", "127.0.0.1",
    "--direct-cert", certificateFile,
    "--direct-key", privateKeyFile
  ], {}, tls.root);
}

describe("direct OpenSSL identity", () => {
  it("loads one matching leaf and hashes its complete DER bytes", async () => {
    const tls = await makeCertificate();
    const config = parseHostConfig([
      "--direct",
      "--direct-host", "127.0.0.1",
      "--direct-cert", tls.certificateFile,
      "--direct-key", tls.privateKeyFile
    ], {}, tls.root);
    const identity = await loadDirectTlsIdentity(config.direct);
    const { X509Certificate } = await import("node:crypto");
    const der = new X509Certificate(tls.certificatePem).raw;
    expect(identity.certificateSha256).toBe(createHash("sha256").update(der).digest("hex"));
    expect(identity.certificatePem).toContain("BEGIN CERTIFICATE");
    expect(identity.certificatePem.match(/BEGIN CERTIFICATE/g)).toHaveLength(1);
    expect(Date.parse(identity.notBefore)).toBeLessThan(Date.now());
    expect(Date.parse(identity.notAfter)).toBeGreaterThan(Date.now());
  });

  it("accepts SHA-384 signatures and RSA-3072 while keeping a SHA-256 DER pin", async () => {
    const tls = await makeCertificate({ rsaBits: 3072, signatureHash: "sha384" });
    const identity = await loadDirectTlsIdentity(identityConfig(tls).direct);
    const { X509Certificate } = await import("node:crypto");
    expect(identity.certificateSha256).toBe(createHash("sha256").update(new X509Certificate(tls.certificatePem).raw).digest("hex"));
  });

  it("fails closed for invalid extensions, validity, chains, key permissions, symlinks, and key mismatch", async () => {
    const invalidExtensions: Array<[{ basicConstraints?: string; keyUsage?: string; extendedKeyUsage?: string; subjectAltName?: string }, RegExp]> = [
      [{ basicConstraints: "critical,CA:TRUE" }, /CA:FALSE|self-signed/],
      [{ basicConstraints: "CA:FALSE" }, /critical/],
      [{ basicConstraints: "" }, /extensions|CA:FALSE/],
      [{ keyUsage: "" }, /keyUsage|extensions/],
      [{ keyUsage: "digitalSignature,keyEncipherment" }, /keyUsage.*critical/],
      [{ keyUsage: "critical,digitalSignature" }, /keyUsage/],
      [{ keyUsage: "critical,keyEncipherment" }, /keyUsage/],
      [{ keyUsage: "critical,keyCertSign" }, /keyUsage/],
      [{ extendedKeyUsage: "" }, /serverAuth|extensions/],
      [{ extendedKeyUsage: "clientAuth" }, /serverAuth/],
      [{ subjectAltName: "" }, /SAN/],
      [{ subjectAltName: "email:admin@example.com" }, /SAN/]
    ];
    for (const [extensions, error] of invalidExtensions) {
      const tls = await makeCertificate(extensions);
      await expect(loadDirectTlsIdentity(identityConfig(tls).direct), JSON.stringify(extensions)).rejects.toThrow(error);
    }

    const validity = await makeCertificate();
    const valid = await loadDirectTlsIdentity(identityConfig(validity).direct);
    await expect(loadDirectTlsIdentity(identityConfig(validity).direct, new Date(Date.parse(valid.notBefore) - 1_000))).rejects.toThrow(/not yet valid/);
    await expect(loadDirectTlsIdentity(identityConfig(validity).direct, new Date(Date.parse(valid.notAfter) + 1_000))).rejects.toThrow(/expired/);

    const chain = await makeCertificate();
    await writeFile(chain.certificateFile, `${chain.certificatePem}${chain.certificatePem}`, "utf8");
    await expect(loadDirectTlsIdentity(identityConfig(chain).direct)).rejects.toThrow(/exactly one/);

    const permissions = await makeCertificate();
    await chmod(permissions.privateKeyFile, 0o640);
    await expect(loadDirectTlsIdentity(identityConfig(permissions).direct)).rejects.toThrow(/0600/);
    await chmod(permissions.privateKeyFile, 0o600);
    await chmod(join(permissions.root, "tls"), 0o777);
    await expect(loadDirectTlsIdentity(identityConfig(permissions).direct)).rejects.toThrow(/directory/);
    await chmod(join(permissions.root, "tls"), 0o700);
    await chmod(permissions.root, 0o777);
    await expect(loadDirectTlsIdentity(identityConfig(permissions).direct)).rejects.toThrow(/ancestor|directory/);

    const linked = await makeCertificate();
    const link = join(linked.root, "tls", "linked-key.pem");
    await symlink(linked.privateKeyFile, link);
    await expect(loadDirectTlsIdentity(identityConfig(linked, linked.certificateFile, link).direct)).rejects.toThrow(/non-symlink/);

    const first = await makeCertificate();
    const second = await makeCertificate();
    await expect(loadDirectTlsIdentity(identityConfig(first, first.certificateFile, second.privateKeyFile).direct)).rejects.toThrow(/do not match/);
  });
});

describe("native direct HTTPS/WSS entry", () => {
  it("authenticates pdt2 at upgrade, enforces the v1/v2 matrix, and forbids pair", async () => {
    const fixture = await makeDirectFixture();

    const missing = await upgradeError(fixture);
    expect(missing.status).toBe(401);
    expect(missing.body.code).toBe("UNAUTHORIZED");
    expect(missing.body.requestId).toMatch(/^req_/);
    expect(JSON.stringify(missing.body)).not.toContain(fixture.device.deviceToken);
    expect((await upgradeError(fixture, { token: fixture.pairingToken })).status).toBe(401);
    expect((await upgradeError(fixture, { token: "not-a-device-token" })).status).toBe(401);
    expect((await upgradeError(fixture, { path: `${DIRECT_PATH}?token=secret` })).status).toBe(404);
    expect((await upgradeError(fixture, { path: `${DIRECT_PATH}/` })).status).toBe(404);
    expect((await upgradeError(fixture, { protocol: "pi-racp.v3.jsonrpc" })).status).toBe(400);

    const v1 = await connectDirect(fixture, V1);
    const initialized = await rpc(v1, 1, "connection/initialize", { protocolVersion: "1.0" });
    expect(initialized.result.protocolVersion).toBe("1.0");
    expect(initialized.result.capabilities.directTransport).toBe(true);
    expect(initialized.result.capabilities.providerDiscovery).toBe(true);
    notifyInitialized(v1);
    const ping = await rpc(v1, 2, "connection/ping");
    expect(ping.result).toMatchObject({ ok: true, pong: true, hostId: fixture.service.hostId });
    expect(Date.parse(ping.result.serverTime)).toBeGreaterThan(0);
    const wrongV1 = await rpc(v1, 3, "connection/initialize", { protocolVersion: "2.0.0" });
    expect(wrongV1.error.data.code).toBe("PROTOCOL_MISMATCH");

    const v2 = await connectDirect(fixture, V2);
    expect((await rpc(v2, 4, "connection/initialize", { protocolVersion: "2.0.0" })).result.protocolVersion).toBe("2.0.0");
    notifyInitialized(v2);
    expect((await rpc(v2, 5, "connection/initialize", { protocolVersion: "1.0" })).error.data.code).toBe("PROTOCOL_MISMATCH");

    const devicesBefore = (await fixture.service.tokens.listDevices()).length;
    const pairClosed = new Promise<number>((resolve) => v1.once("close", (code) => resolve(code)));
    const pair = await rpc(v1, 6, "connection/pair", { deviceLabel: "must-not-pair" });
    expect(pair.error.data.code).toBe("FORBIDDEN");
    expect(await pairClosed).toBe(1008);
    expect((await fixture.service.tokens.listDevices()).length).toBe(devicesBefore);
    await expect(fixture.service.tokens.pair(fixture.pairingToken, "still-available")).resolves.toMatchObject({
      deviceId: expect.any(String)
    });

    await closeSocket(v2);
  });
});

describe("direct admission, frames, and shared revocation", () => {
  it("bounds preAuth windows with LRU eviction and expires old entries", async () => {
    const { DirectPreAuthRateLimiter } = await import("../src/server/ws.js") as any;
    const limiter = new DirectPreAuthRateLimiter({ count: 1, windowMs: 1_000 }, 2);
    expect(limiter.consume("192.0.2.1", 0).allowed).toBe(true);
    expect(limiter.consume("192.0.2.1", 1).allowed).toBe(false);
    expect(limiter.consume("192.0.2.2", 2).allowed).toBe(true);
    expect(limiter.size).toBe(2);
    expect(limiter.consume("192.0.2.3", 3).allowed).toBe(true);
    expect(limiter.size).toBe(2);
    expect(limiter.consume("192.0.2.3", 4).allowed).toBe(false);
    expect(limiter.consume("192.0.2.2", 2_000).allowed).toBe(true);
    expect(limiter.size).toBe(1);
  });

  it("enforces N before writing 101", async () => {
    const fixture = await makeDirectFixture({ maxConnections: 1 });
    const first = await connectDirect(fixture);
    const second = await upgradeError(fixture).then(
      (response) => ({ response }),
      (error: Error) => ({ error })
    );
    if ("response" in second) {
      expect(second.response.status).toBe(429);
      expect(second.response.body).toMatchObject({ code: "RATE_LIMITED", reason: "connection_limit" });
    } else {
      expect(second.error.message).toMatch(/hang up|reset|closed/i);
    }
    await closeSocket(first);
  });

  it("enforces R after upgrade with a structured error and rate-limited close", async () => {
    const fixture = await makeDirectFixture({ messageRateCount: 4, messageRateWindowMs: 1_000 });
    const socket = await connectDirect(fixture);
    await initializeDirect(socket, 10, "1.0");
    await rpc(socket, 1, "connection/ping");
    await rpc(socket, 2, "connection/ping");
    const closed = new Promise<{ code: number; reason: string }>((resolve) => {
      socket.once("close", (code, reason) => resolve({ code, reason: reason.toString() }));
    });
    const limited = await rpc(socket, 3, "connection/ping");
    expect(limited.error.data).toMatchObject({ code: "RATE_LIMITED" });
    expect(limited.error.data.retryAfterMs).toBeGreaterThan(0);
    expect(await closed).toEqual({ code: 1008, reason: "rate limited" });
  });

  it("enforces T from TCP accept without using a WebSocket close before 101", async () => {
    const fixture = await makeDirectFixture({ unauthenticatedTimeoutMs: 1_000 });
    const response = await new Promise<string>((resolve, reject) => {
      let raw = "";
      const socket = tlsConnect({ host: "127.0.0.1", port: fixture.server.port, ca: fixture.certificatePem });
      socket.setEncoding("utf8");
      socket.on("data", (chunk: string) => { raw += chunk; });
      socket.on("end", () => resolve(raw));
      socket.on("error", reject);
      const timer = setTimeout(() => {
        socket.destroy();
        reject(new Error("authentication timeout was not enforced"));
      }, 3_000);
      socket.on("close", () => {
        clearTimeout(timer);
        if (raw) resolve(raw);
      });
    });
    expect(response).toContain(" 429 ");
    expect(response).toContain("authentication_timeout");
    expect(response).not.toContain("1008");
    const recovered = await connectDirect(fixture);
    await initializeDirect(recovered, 1, "1.0");
    await closeSocket(recovered);
  });

  it("releases N admission after ordinary HTTP and rejected Upgrade responses", async () => {
    const fixture = await makeDirectFixture({ maxConnections: 1 });
    const ordinary = await new Promise<number>((resolve, reject) => {
      const request = httpsRequest({
        host: "127.0.0.1",
        port: fixture.server.port,
        path: DIRECT_PATH,
        ca: fixture.certificatePem
      }, (response) => {
        response.resume();
        response.on("end", () => resolve(response.statusCode ?? 0));
      });
      request.on("error", reject);
      request.end();
    });
    expect(ordinary).toBe(426);
    const first = await connectDirect(fixture);
    await closeSocket(first);
    expect((await upgradeError(fixture)).status).toBe(401);
    const second = await connectDirect(fixture);
    await closeSocket(second);
  });

  it("accepts exactly 1 MiB, closes oversized messages with 1009 and binary with 1003", async () => {
    const fixture = await makeDirectFixture();
    const socket = await connectDirect(fixture);
    const parsed = new Promise<Frame>((resolve) => socket.once("message", (raw) => resolve(JSON.parse(raw.toString()) as Frame)));
    socket.send(" ".repeat(1024 * 1024));
    expect((await parsed).error.code).toBe(-32700);
    const oversizedClosed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    socket.send(" ".repeat(1024 * 1024 + 1));
    expect(await oversizedClosed).toBe(1009);

    const binary = await connectDirect(fixture);
    const binaryClosed = new Promise<number>((resolve) => binary.once("close", (code) => resolve(code)));
    binary.send(Buffer.from([1, 2, 3]));
    expect(await binaryClosed).toBe(1003);
  });

  it("uses explicit ordinary HTTPS request handling without redirects", async () => {
    const fixture = await makeDirectFixture();
    const response = await new Promise<{ status: number; body: any; location?: string }>((resolve, reject) => {
      const request = httpsRequest({
        host: "127.0.0.1",
        port: fixture.server.port,
        path: DIRECT_PATH,
        ca: fixture.certificatePem
      }, (incoming) => {
        let raw = "";
        incoming.on("data", (chunk) => { raw += chunk; });
        incoming.on("end", () => resolve({
          status: incoming.statusCode ?? 0,
          body: JSON.parse(raw),
          ...(incoming.headers.location ? { location: incoming.headers.location } : {})
        }));
      });
      request.on("error", reject);
      request.end();
    });
    expect(response.status).toBe(426);
    expect(response.body.code).toBe("UPGRADE_REQUIRED");
    expect(response.location).toBeUndefined();
  });

  it("keeps a fixed direct port on conflict instead of selecting another listener", async () => {
    const fixture = await makeDirectFixture();
    await expect(startDirectWebSocketServer(fixture.service, fixture.config.direct, fixture.registry)).rejects.toThrow(/EADDRINUSE/);
    expect(fixture.server.port).toBe(fixture.config.direct.port);
    const socket = await connectDirect(fixture);
    await initializeDirect(socket, 10, "1.0");
    expect((await rpc(socket, 1, "connection/ping")).result.hostId).toBe(fixture.service.hostId);
    await closeSocket(socket);
  });

  it("revokes every loopback and direct socket through the shared registry", async () => {
    const fixture = await makeDirectFixture();
    const loopback = await startWebSocketServer(fixture.service, 0, fixture.registry);
    cleanups.push(() => loopback.close());
    const loopUrl = `ws://127.0.0.1:${loopback.port}${DIRECT_PATH}`;
    const loop = await new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(loopUrl, { headers: { Authorization: `Bearer ${fixture.device.deviceToken}` } });
      socket.once("open", () => resolve(socket));
      socket.once("error", reject);
    });
    const direct = await connectDirect(fixture);
    await initializeDirect(direct, 20, "1.0");
    await rpc(loop, 1, "events/subscribe", { scope: "host" });
    await rpc(direct, 2, "events/subscribe", { scope: "host" });
    const loopClosed = new Promise<{ code: number; reason: string }>((resolve) => {
      loop.once("close", (code, reason) => resolve({ code, reason: reason.toString() }));
    });
    const directClosed = new Promise<{ code: number; reason: string }>((resolve) => {
      direct.once("close", (code, reason) => resolve({ code, reason: reason.toString() }));
    });
    const revoked = await rpc(loop, 3, "connection/revoke", {
      deviceId: fixture.device.deviceId,
      context: { requestId: "shared-revoke", idempotencyKey: "shared-revoke" }
    });
    expect(revoked.result.revoked).toBe(true);
    expect(await loopClosed).toEqual({ code: 1008, reason: "device revoked" });
    expect(await directClosed).toEqual({ code: 1008, reason: "device revoked" });
    expect((fixture.service as any).subscriptions.size).toBe(0);
    expect((await upgradeError(fixture)).status).toBe(401);

    const rejected = await new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(loopUrl, { headers: { Authorization: `Bearer ${fixture.device.deviceToken}` } });
      socket.once("open", () => resolve(socket));
      socket.once("error", reject);
    });
    expect((await rpc(rejected, 4, "project/list")).error.data.code).toBe("UNAUTHORIZED");
    await closeSocket(rejected);
  });
});

describe("direct handshake and credential lifecycle", () => {
  it("requires initialize then initialized before business and never answers the notification", async () => {
    const fixture = await makeDirectFixture();
    const socket = await connectDirect(fixture);
    expect((await rpc(socket, 1, "connection/ping")).error.data.code).toBe("PROTOCOL_MISMATCH");
    expect((await rpc(socket, 2, "connection/initialize", { protocolVersion: "1.0" })).result.protocolVersion).toBe("1.0");
    expect((await rpc(socket, 3, "connection/ping")).error.data.code).toBe("PROTOCOL_MISMATCH");
    const frames: Frame[] = [];
    socket.on("message", (raw) => frames.push(JSON.parse(raw.toString()) as Frame));
    notifyInitialized(socket);
    expect((await rpc(socket, 4, "connection/ping")).result.pong).toBe(true);
    await new Promise((resolve) => setTimeout(resolve, 20));
    expect(frames.filter((frame) => frame.id === null || frame.id === undefined)).toHaveLength(0);

    expect((await rpc(socket, 5, "not/a-method")).error.data.code).toBe("INVALID_ARGUMENT");
    expect((await rpc(socket, 6, "connection/ping")).result.pong).toBe(true);
    await closeSocket(socket);
  });

  it("closes method-level unauthorized sockets and synchronously releases their subscriptions", async () => {
    const fixture = await makeDirectFixture();
    const socket = await connectDirect(fixture);
    await initializeDirect(socket, 1, "1.0");
    await rpc(socket, 2, "events/subscribe", { scope: "host" });
    await fixture.service.tokens.revoke(fixture.device.deviceId);
    const closed = new Promise<{ code: number; reason: string }>((resolve) => {
      socket.once("close", (code, reason) => resolve({ code, reason: reason.toString() }));
    });
    expect((await rpc(socket, 3, "connection/ping")).error.data.code).toBe("UNAUTHORIZED");
    const terminal = await Promise.race([
      closed,
      new Promise<null>((resolve) => setTimeout(() => resolve(null), 300))
    ]);
    expect(terminal).toEqual({ code: 1008, reason: "device revoked" });
    expect((fixture.service as any).subscriptions.size).toBe(0);
    expect((fixture.registry as any).bySocket.size).toBe(0);
  });

  it("makes registry unsubscribe and repeated release idempotent without closing the socket", async () => {
    const fixture = await makeDirectFixture();
    const socket = await connectDirect(fixture);
    await initializeDirect(socket, 1, "1.0");
    const subscribed = await rpc(socket, 2, "events/subscribe", { scope: "host" });
    const id = subscribed.result.subscriptionId as string;
    expect((fixture.service as any).subscriptions.size).toBe(1);
    const serverSocket = (fixture.registry as any).bySocket.keys().next().value as WebSocket;
    fixture.registry.removeSubscription(serverSocket, id);
    expect((fixture.service as any).subscriptions.size).toBe(0);
    fixture.registry.removeSubscription(serverSocket, id);
    fixture.registry.release(serverSocket);
    fixture.registry.release(serverSocket);
    expect((fixture.registry as any).bySocket.size).toBe(0);
    expect((fixture.service as any).subscriptions.size).toBe(0);
    await closeSocket(socket);
  });

  it("does not let another socket unsubscribe or delete the owner's subscription", async () => {
    const fixture = await makeDirectFixture();
    const owner = await connectDirect(fixture);
    const other = await connectDirect(fixture);
    await initializeDirect(owner, 1, "1.0");
    await initializeDirect(other, 2, "1.0");
    const subscribed = await rpc(owner, 3, "events/subscribe", { scope: "host" });
    const subscriptionId = subscribed.result.subscriptionId as string;
    const ownerEntry = [...(fixture.registry as any).bySocket.values()]
      .find((entry: any) => entry.subscriptions.has(subscriptionId));
    expect(ownerEntry).toBeDefined();

    expect((await rpc(other, 4, "events/unsubscribe", { subscriptionId })).result.unsubscribed).toBe(true);
    expect((fixture.service as any).subscriptions.has(subscriptionId)).toBe(true);
    expect(ownerEntry.subscriptions.has(subscriptionId)).toBe(true);
    expect((await rpc(other, 5, "events/unsubscribe", { subscriptionId: "unknown-subscription" })).result.unsubscribed).toBe(true);
    expect((await rpc(other, 6, "connection/ping")).result.pong).toBe(true);
    expect((await rpc(owner, 7, "connection/ping")).result.pong).toBe(true);

    await closeSocket(owner);
    await vi.waitFor(() => {
      expect((fixture.service as any).subscriptions.has(subscriptionId)).toBe(false);
    });
    const reopened = await connectDirect(fixture);
    await initializeDirect(reopened, 20, "1.0");
    const second = await rpc(reopened, 21, "events/subscribe", { scope: "host" });
    const secondId = second.result.subscriptionId as string;
    expect((await rpc(reopened, 22, "events/unsubscribe", { subscriptionId: secondId })).result.unsubscribed).toBe(true);
    expect((await rpc(reopened, 23, "events/unsubscribe", { subscriptionId: secondId })).result.unsubscribed).toBe(true);
    expect((await rpc(reopened, 24, "connection/ping")).result.pong).toBe(true);
    await closeSocket(reopened);
    await closeSocket(other);
  });

  it("closes only the previous credential generation across listeners after rotation confirmation", async () => {
    const fixture = await makeDirectFixture();
    const oldDirect = await connectDirect(fixture);
    await initializeDirect(oldDirect, 1, "1.0");
    await rpc(oldDirect, 2, "events/subscribe", { scope: "host" });
    const loopback = await startWebSocketServer(fixture.service, 0, fixture.registry);
    cleanups.push(() => loopback.close());
    const oldLoop = await new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(`ws://127.0.0.1:${loopback.port}${DIRECT_PATH}`, {
        headers: { Authorization: `Bearer ${fixture.device.deviceToken}` }
      });
      socket.once("open", () => resolve(socket));
      socket.once("error", reject);
    });
    await rpc(oldLoop, 3, "events/subscribe", { scope: "host" });
    const rotated = await fixture.service.tokens.rotate(fixture.device.deviceId);
    const newDirect = await connectDirect(fixture, V1, rotated.deviceToken);
    await initializeDirect(newDirect, 4, "1.0");
    const newSubscription = await rpc(newDirect, 5, "events/subscribe", { scope: "host" });
    const oldEvents: Frame[] = [];
    oldDirect.on("message", (raw) => {
      const frame = JSON.parse(raw.toString()) as Frame;
      if (frame.method === "events/closed") oldEvents.push(frame);
    });
    const oldDirectClosed = new Promise<number>((resolve) => oldDirect.once("close", (code) => resolve(code)));
    const oldLoopClosed = new Promise<number>((resolve) => oldLoop.once("close", (code) => resolve(code)));
    const confirmed = await rpc(newDirect, 6, "connection/confirm-rotation", {
      rotationId: rotated.rotationId,
      context: { requestId: "confirm-rotation", idempotencyKey: "confirm-rotation" }
    });
    expect(confirmed.result.confirmed).toBe(true);
    const terminals = await Promise.race([
      Promise.all([oldDirectClosed, oldLoopClosed]),
      new Promise<null>((resolve) => setTimeout(() => resolve(null), 300))
    ]);
    expect(terminals).toEqual([1008, 1008]);
    expect(oldEvents).toHaveLength(1);
    expect(oldEvents[0]?.params.code).toBe("UNAUTHORIZED");
    expect((await rpc(newDirect, 7, "connection/ping")).result.pong).toBe(true);
    expect((fixture.service as any).subscriptions.size).toBe(1);
    expect((fixture.service as any).subscriptions.has(newSubscription.result.subscriptionId)).toBe(true);
    await closeSocket(newDirect);
  });
});

describe("main direct lifecycle and bootstrap trust", () => {
  it("keeps full loopback pairing available and emits no trust when direct TLS fails", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-main-direct-failure-"));
    const bootstrapDir = join(root, ".bootstrap");
    await mkdir(bootstrapDir, { recursive: true, mode: 0o700 });
    await writeFile(join(bootstrapDir, "state.json"), JSON.stringify({ attemptId: "boot_failed", status: "running" }), { mode: 0o600 });
    await writeFile(join(bootstrapDir, "direct-trust.json"), JSON.stringify({ attemptId: "boot_stale" }), { mode: 0o600 });
    const host = spawnHost([
      "--home", root,
      "--port", "0",
      "--pair",
      "--direct",
      "--direct-host", "127.0.0.1",
      "--direct-port", String(await freePort()),
      "--direct-cert", join(root, "missing-cert.pem"),
      "--direct-key", join(root, "missing-key.pem")
    ]);
    await host.waitFor(() =>
      host.lines.some((line) => line.startsWith("PI_HOST_READY ")) &&
      host.lines.some((line) => line.startsWith("PI_HOST_PAIRING_TOKEN ")) &&
      host.stderr().includes("PI_HOST_DIRECT_ERROR")
    );
    expect(host.lines.some((line) => line.startsWith("PI_HOST_DIRECT_TRUST "))).toBe(false);
    await expect(stat(join(bootstrapDir, "direct-trust.json"))).rejects.toMatchObject({ code: "ENOENT" });
    expect(host.stderr()).not.toContain("BEGIN PRIVATE KEY");
    const ready = payload(host.lines, "PI_HOST_READY ");
    const pairing = payload(host.lines, "PI_HOST_PAIRING_TOKEN ");
    const url = `ws://127.0.0.1:${ready.port}${DIRECT_PATH}`;
    const pairingSocket = await new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(url, { headers: { Authorization: `Bearer ${pairing.token}` } });
      socket.once("open", () => resolve(socket));
      socket.once("error", reject);
    });
    const paired = await rpc(pairingSocket, 1, "connection/pair", { deviceLabel: "loopback-rescue" });
    expect(paired.result.deviceToken).toMatch(/^pdt2\./);
    await closeSocket(pairingSocket);
    const socket = await new Promise<WebSocket>((resolve, reject) => {
      const candidate = new WebSocket(url, { headers: { Authorization: `Bearer ${paired.result.deviceToken}` } });
      candidate.once("open", () => resolve(candidate));
      candidate.once("error", reject);
    });
    const ping = await rpc(socket, 2, "connection/ping");
    expect(ping.result).toMatchObject({ ok: true, pong: true, hostId: ready.hostId });
    await closeSocket(socket);
  });

  it("invalidates stale trust when a new attempt has direct disabled", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-main-direct-disabled-"));
    const bootstrapDir = join(root, ".bootstrap");
    await mkdir(bootstrapDir, { recursive: true, mode: 0o700 });
    // No state.json/current attempt exists: any previous authorization is stale.
    await writeFile(join(bootstrapDir, "direct-trust.json"), JSON.stringify({ attemptId: "boot_stale" }), { mode: 0o600 });
    const host = spawnHost(["--home", root, "--port", "0"]);
    await host.waitFor(() => host.lines.some((line) => line.startsWith("PI_HOST_READY ")));
    await expect(stat(join(bootstrapDir, "direct-trust.json"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("invalidates a previous valid trust when restarting the same attempt with direct disabled", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-main-same-attempt-disabled-"));
    const bootstrapDir = join(root, ".bootstrap");
    await mkdir(bootstrapDir, { recursive: true, mode: 0o700 });
    await writeFile(join(bootstrapDir, "state.json"), JSON.stringify({ attemptId: "boot_same_disabled", status: "running" }), { mode: 0o600 });
    await writeFile(join(bootstrapDir, "direct-trust.json"), JSON.stringify({
      schemaVersion: 1,
      attemptId: "boot_same_disabled",
      hostId: "previous-host",
      certificateSha256: "0123456789abcdef".repeat(4),
      notBefore: "2026-11-05T00:00:00.000Z",
      notAfter: "2028-02-08T00:00:00.000Z"
    }), { mode: 0o600 });
    const host = spawnHost(["--home", root, "--port", "0"]);
    await host.waitFor(() => host.lines.some((line) => line.startsWith("PI_HOST_READY ")));
    await expect(stat(join(bootstrapDir, "direct-trust.json"))).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("emits independent trust and atomically staged owner-only metadata for the current attempt", async () => {
    const tls = await makeCertificate();
    const bootstrapDir = join(tls.root, ".bootstrap");
    await mkdir(bootstrapDir, { recursive: true, mode: 0o700 });
    await writeFile(join(bootstrapDir, "state.json"), JSON.stringify({
      attemptId: "boot_direct_test",
      status: "running"
    }), { mode: 0o600 });
    const host = spawnHost([
      "--home", tls.root,
      "--port", "0",
      "--pair",
      "--direct",
      "--direct-host", "127.0.0.1",
      "--direct-port", String(await freePort()),
      "--direct-cert", tls.certificateFile,
      "--direct-key", tls.privateKeyFile
    ]);
    await host.waitFor(() =>
      host.lines.some((line) => line.startsWith("PI_HOST_READY ")) &&
      host.lines.some((line) => line.startsWith("PI_HOST_DIRECT_TRUST "))
    );
    const trust = payload(host.lines, "PI_HOST_DIRECT_TRUST ");
    const ready = payload(host.lines, "PI_HOST_READY ");
    const expectedFingerprint = createHash("sha256").update(
      new (await import("node:crypto")).X509Certificate(tls.certificatePem).raw
    ).digest("hex");
    const certificate = new (await import("node:crypto")).X509Certificate(tls.certificatePem);
    expect(trust).toMatchObject({
      schemaVersion: 1,
      attemptId: "boot_direct_test",
      hostId: ready.hostId,
      certificateSha256: expectedFingerprint
    });
    // Derive validity independently from the certificate instead of comparing
    // the actual values with themselves.
    expect(new Date(String(trust.notBefore)).getTime()).toBe(new Date(certificate.validFrom).getTime());
    expect(new Date(String(trust.notAfter)).getTime()).toBe(new Date(certificate.validTo).getTime());
    expect(new Date(String(trust.notBefore)).getTime()).toBeLessThan(new Date(String(trust.notAfter)).getTime());
    expect(ready.fingerprint).not.toBe(expectedFingerprint);
    expect(JSON.stringify(trust)).not.toContain("endpoint");
    expect(JSON.stringify(trust)).not.toContain("privateKey");
    const trustPath = join(bootstrapDir, "direct-trust.json");
    expect(JSON.parse(await readFile(trustPath, "utf8"))).toEqual(trust);
    expect((await stat(trustPath)).mode & 0o777).toBe(0o600);
    expect((await stat(bootstrapDir)).mode & 0o777).toBe(0o700);
    host.child.kill("SIGTERM");
    await new Promise<void>((resolve) => host.child.once("exit", () => resolve()));
    await expect(stat(trustPath)).rejects.toMatchObject({ code: "ENOENT" });
  });
});
