import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import WebSocket from "ws";
import { describe, expect, it, vi } from "vitest";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import type { AgentDriver, AgentTurnHandle, AgentTurnRequest } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
import type { ProviderDiscoveryRequest, ProviderDiscoveryTestOnly } from "../src/providers/discovery.js";
import { HostService } from "../src/server/host-service.js";
import { startWebSocketServer } from "../src/server/ws.js";

type Frame = { id?: number; result?: any; error?: any; method?: string; params?: any };

function rpc(socket: WebSocket, id: number, method: string, params: unknown = {}): Promise<Frame> {
  return new Promise((resolve, reject) => {
    const onMessage = (raw: WebSocket.RawData) => {
      const frame = JSON.parse(raw.toString()) as Frame;
      if (frame.id !== id) return;
      socket.off("message", onMessage);
      resolve(frame);
    };
    socket.on("message", onMessage);
    socket.once("error", reject);
    socket.send(JSON.stringify({ jsonrpc: "2.0", id, method, params }));
  });
}

function connect(url: string, token: string): Promise<WebSocket> {
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(url, {
      headers: { Authorization: `Bearer ${token}` }
    });
    socket.once("open", () => resolve(socket));
    socket.once("error", reject);
  });
}

describe("RACP v2 websocket", () => {
  it("pairs, authenticates, registers a project, and streams a turn", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-ws-"));
    const project = join(root, "project");
    await mkdir(project, { recursive: true });
    const config = parseHostConfig(
      ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
      {},
      root
    );
    await ensureHostDirectories(config);
    const service = new HostService(config, new DeterministicAgentDriver());
    await service.init();
    const pairing = await service.createPairingToken();
    const server = await startWebSocketServer(service, 0);
    const url = `ws://127.0.0.1:${server.port}/v1/racp/ws`;

    const anonymous = await connect(url, "ppt2.invalid");
    const initialized = await rpc(anonymous, 1, "connection/initialize", {
      client: { name: "test", version: "1", capabilities: {} },
      protocolVersion: "2.0.0"
    });
    expect(initialized.result.protocolVersion).toBe("2.0.0");
    expect(initialized.result.capabilities).toMatchObject({ directTransport: true, providerDiscovery: true });
    const legacy = await rpc(anonymous, 10, "connection/initialize", {
      client: { name: "legacy", version: "1", capabilities: {} },
      protocolVersion: "1.0"
    });
    expect(legacy.result.protocolVersion).toBe("1.0");
    const invalidPair = await rpc(anonymous, 11, "connection/pair", { deviceLabel: "intruder" });
    expect(invalidPair.error.data.code).toBe("PAIRING_FAILED");
    const invalidFrame = new Promise<Frame>((resolve) => anonymous.once("message", (raw) => resolve(JSON.parse(raw.toString()) as Frame)));
    anonymous.send("null");
    expect((await invalidFrame).error.code).toBe(-32600);
    anonymous.close();

    const pairingSocket = await connect(url, pairing.token);
    const paired = await rpc(pairingSocket, 2, "connection/pair", {
      deviceLabel: "test-device",
      context: { requestId: "pair" }
    });
    expect(paired.result.deviceToken).toMatch(/^pdt2\./);
    pairingSocket.close();

    const v1Pairing = await service.createPairingToken();
    const v1PairingSocket = await connect(url, v1Pairing.token);
    const v1Initialized = await rpc(v1PairingSocket, 12, "connection/initialize", {
      client: { name: "bootstrap", version: "0.0.2", capabilities: {} },
      protocolVersion: "1.0"
    });
    expect(v1Initialized.result.protocolVersion).toBe("1.0");
    v1PairingSocket.send(JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
      params: {}
    }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(v1PairingSocket.readyState).toBe(WebSocket.OPEN);
    const v1Paired = await rpc(v1PairingSocket, 13, "connection/pair", { deviceLabel: "bootstrap-device" });
    expect(v1Paired.result.deviceToken).toMatch(/^pdt2\./);
    v1PairingSocket.close();

    // The v1 handshake notification must also be accepted on a device-token
    // connection. Returning INVALID_ARGUMENT made strict clients treat the
    // handshake as failed and close the socket immediately after it opened.
    const v1DeviceSocket = await connect(url, paired.result.deviceToken);
    const v1DeviceInitialized = await rpc(v1DeviceSocket, 21, "connection/initialize", {
      client: { name: "device", version: "0.0.3", capabilities: {} },
      protocolVersion: "1.0"
    });
    expect(v1DeviceInitialized.result.protocolVersion).toBe("1.0");
    const unexpected: Frame[] = [];
    v1DeviceSocket.on("message", (raw) => unexpected.push(JSON.parse(raw.toString()) as Frame));
    v1DeviceSocket.send(JSON.stringify({
      jsonrpc: "2.0",
      method: "notifications/initialized",
      params: {}
    }));
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(unexpected).toEqual([]);
    expect(v1DeviceSocket.readyState).toBe(WebSocket.OPEN);
    const v1DevicePing = await rpc(v1DeviceSocket, 22, "connection/ping", {});
    expect(v1DevicePing.result.ok).toBe(true);
    v1DeviceSocket.close();

    const socket = await connect(url, paired.result.deviceToken);
    const projectResult = await rpc(socket, 3, "project/register", {
      path: project,
      label: "Test",
      context: { requestId: "project", idempotencyKey: "project" }
    });
    expect(projectResult.result.project.path).toBe(project);

    const created = await rpc(socket, 4, "session/create", {
      projectId: projectResult.result.project.id,
      title: "Test session",
      context: { requestId: "session", idempotencyKey: "session" }
    });
    const sessionId = created.result.session.id;

    const events: Frame[] = [];
    socket.on("message", (raw) => {
      const frame = JSON.parse(raw.toString()) as Frame;
      if (frame.method === "events/event") events.push(frame);
    });
    const subscribed = await rpc(socket, 50, "events/subscribe", {
      scope: "session",
      sessionId
    });
    expect(subscribed.result.subscriptionId).toBeTruthy();
    const turn = await rpc(socket, 5, "turn/start", {
      sessionId,
      input: { text: "hello", attachments: [] },
      context: { requestId: "turn", idempotencyKey: "turn" }
    });
    expect(turn.result.turn.id).toBeTruthy();
    // Poll for the terminal event instead of assuming 30 ms is always enough under load.
    await vi.waitFor(
      () => {
        expect(events.some((frame) => frame.params.event.kind === "turn.completed")).toBe(true);
      },
      { timeout: 2_000 }
    );

    const history = await rpc(socket, 6, "session/attach", { sessionId });
    expect(history.result.snapshot.items.some((item: any) => item.text === "hello")).toBe(true);

    const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.close();
    await closed;
    await vi.waitFor(
      () => {
        expect((service as any).subscriptions.size).toBe(0);
      },
      { timeout: 2_000 }
    );
    await server.close();
  });

  it("blocks an ask-mode tool call until approval/respond", async () => {
    class ApprovalDriver implements AgentDriver {
      readonly appendsPrompt = false;
      start(request: AgentTurnRequest): AgentTurnHandle {
        let resolveWait!: () => void;
        const wait = new Promise<void>((resolve) => { resolveWait = resolve; });
        queueMicrotask(async () => {
          const allowed = await request.requestApproval?.("bash", { command: "echo hi" });
          request.onEvent({
            kind: allowed ? "turn.completed" : "turn.failed",
            payload: { turnId: request.turnId, allowed: allowed ?? false }
          });
          resolveWait();
        });
        return { turnId: request.turnId, abort: async () => resolveWait(), wait: () => wait };
      }
    }
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-approval-"));
    const config = parseHostConfig(
      ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
      {},
      root
    );
    await ensureHostDirectories(config);
    const service = new HostService(config, new ApprovalDriver());
    await service.init();
    const pairing = await service.createPairingToken();
    const server = await startWebSocketServer(service, 0);
    const url = `ws://127.0.0.1:${server.port}/v1/racp/ws`;
    const pairingSocket = await connect(url, pairing.token);
    const paired = await rpc(pairingSocket, 1, "connection/pair", { deviceLabel: "approval" });
    pairingSocket.close();
    const socket = await connect(url, paired.result.deviceToken);
    const created = await rpc(socket, 2, "session/create", {
      title: "approval",
      permissionMode: "ask",
      context: { requestId: "create", idempotencyKey: "create" }
    });
    const sessionId = created.result.session.id;
    const events: Frame[] = [];
    socket.on("message", (raw) => {
      const frame = JSON.parse(raw.toString()) as Frame;
      if (frame.method === "events/event") events.push(frame);
    });
    await rpc(socket, 3, "events/subscribe", { scope: "session", sessionId });
    const turn = await rpc(socket, 4, "turn/start", {
      sessionId,
      input: { text: "run", attachments: [] },
      context: { requestId: "turn", idempotencyKey: "turn" }
    });
    for (let i = 0; i < 50 && !events.some((frame) => frame.params.event.kind === "approval.requested"); i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const requested = events.find((frame) => frame.params.event.kind === "approval.requested");
    expect(requested).toBeTruthy();
    const approvalId = requested!.params.event.payload.approval.id;
    const responded = await rpc(socket, 5, "approval/respond", {
      approvalId,
      decision: "allow-once",
      context: { requestId: "approval", idempotencyKey: "approval", expectedRevision: 1 }
    });
    expect(responded.result.resolved).toBe(true);
    for (let i = 0; i < 50 && !events.some((frame) => frame.params.event.kind === "turn.completed"); i++) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(events.some((frame) => frame.params.event.kind === "turn.completed")).toBe(true);
    expect(turn.result.turn.id).toBeTruthy();
    socket.close();
    await server.close();
  });

  it("acknowledges a device's self-revoke before closing its socket", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-revoke-"));
    const config = parseHostConfig(
      ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
      {},
      root
    );
    await ensureHostDirectories(config);
    const service = new HostService(config, new DeterministicAgentDriver());
    await service.init();
    const pairing = await service.createPairingToken();
    const server = await startWebSocketServer(service, 0);
    const url = `ws://127.0.0.1:${server.port}/v1/racp/ws`;

    const pairingSocket = await connect(url, pairing.token);
    const paired = await rpc(pairingSocket, 1, "connection/pair", { deviceLabel: "self-revoke" });
    pairingSocket.close();

    // The owner revokes itself. The acknowledgement must arrive before the host
    // tears the device's socket down; otherwise the client sees only a close and
    // reports an offline failure for a revoke that already took effect.
    const socket = await connect(url, paired.result.deviceToken);
    const closed = new Promise<number>((resolve) => socket.once("close", (code) => resolve(code)));
    const response = await rpc(socket, 2, "connection/revoke", {
      deviceId: paired.result.deviceId,
      context: { requestId: "revoke", idempotencyKey: "revoke" }
    });
    expect(response.result.revoked).toBe(true);
    expect(await closed).toBe(1008);

    // AC-03.1: the device token is unusable afterwards (initialize stays anonymous,
    // so probe an owner-only read instead).
    const rejected = await connect(url, paired.result.deviceToken);
    const unauthorized = await rpc(rejected, 3, "project/list");
    expect(unauthorized.error.data.code).toBe("UNAUTHORIZED");
    rejected.close();
    await server.close();
  });

  it("answers a repeated revoke with revoked=false without dropping the caller", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-revoke-repeat-"));
    const config = parseHostConfig(
      ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
      {},
      root
    );
    await ensureHostDirectories(config);
    const service = new HostService(config, new DeterministicAgentDriver());
    await service.init();
    const first = await service.createPairingToken();
    const second = await service.createPairingToken();
    const server = await startWebSocketServer(service, 0);
    const url = `ws://127.0.0.1:${server.port}/v1/racp/ws`;

    const ownerPairing = await connect(url, first.token);
    const ownerPaired = await rpc(ownerPairing, 1, "connection/pair", { deviceLabel: "owner" });
    ownerPairing.close();
    const targetPairing = await connect(url, second.token);
    const target = await rpc(targetPairing, 2, "connection/pair", { deviceLabel: "target" });
    targetPairing.close();

    // Revoke the target from an owner socket, then repeat with a fresh key.
    // The owner must stay connected and receive `revoked=false` (contract §2.4).
    const owner = await connect(url, ownerPaired.result.deviceToken);
    const firstRevoke = await rpc(owner, 3, "connection/revoke", {
      deviceId: target.result.deviceId,
      context: { requestId: "revoke-1", idempotencyKey: "revoke-1" }
    });
    expect(firstRevoke.result.revoked).toBe(true);
    const secondRevoke = await rpc(owner, 4, "connection/revoke", {
      deviceId: target.result.deviceId,
      context: { requestId: "revoke-2", idempotencyKey: "revoke-2" }
    });
    expect(secondRevoke.result.revoked).toBe(false);
    owner.close();
    await server.close();
  });

  it("rejects a wrong loopback path before entering RACP", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-loopback-path-"));
    const config = parseHostConfig([
      "--data-dir", join(root, "data"),
      "--agent-dir", join(root, "agent")
    ], {}, root);
    await ensureHostDirectories(config);
    const service = new HostService(config, new DeterministicAgentDriver());
    await service.init();
    const server = await startWebSocketServer(service, 0);
    const wrongPath = new Promise<WebSocket>((resolve, reject) => {
      const socket = new WebSocket(`ws://127.0.0.1:${server.port}/v1/racp/ws/`);
      socket.once("open", () => resolve(socket));
      socket.once("error", reject);
    });
    await expect(wrongPath).rejects.toThrow(/404/);
    await server.close();
  });

  it("carries provider discovery success and stable errors over authenticated RACP", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-discovery-ws-"));
    const config = parseHostConfig([
      "--data-dir", join(root, "data"),
      "--agent-dir", join(root, "agent"),
      "--port", "0"
    ], {}, root);
    await ensureHostDirectories(config);
    const requests: ProviderDiscoveryRequest[] = [];
    let statusCode = 200;
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
              body: Readable.from([JSON.stringify({ data: [{ id: "model-a" }] })]),
              close: vi.fn()
            };
          },
          close: vi.fn()
        };
      }
    };
    const service = new HostService(config, new DeterministicAgentDriver(), { testOnly });
    await service.init();
    const pairing = await service.createPairingToken();
    const paired = await service.tokens.pair(pairing.token, "discovery-ws");
    const server = await startWebSocketServer(service, 0);
    const url = `ws://127.0.0.1:${server.port}/v1/racp/ws`;
    const socket = await connect(url, paired.deviceToken);
    const initialized = await rpc(socket, 1, "connection/initialize", { protocolVersion: "2.0.0" });
    expect(initialized.result.capabilities).toMatchObject({ directTransport: true, providerDiscovery: true });
    const temporaryKey = "temporary-ws-discovery-key";
    const discovered = await rpc(socket, 2, "provider/discover", {
      baseUrl: "https://provider.unit/v1",
      apiKey: temporaryKey,
      context: { requestId: "req_ws_discovery" }
    });
    expect(discovered.result.models.map((model: any) => model.id)).toEqual(["model-a"]);
    expect(JSON.stringify(discovered)).not.toContain(temporaryKey);

    statusCode = 503;
    const unavailable = await rpc(socket, 3, "provider/discover", {
      baseUrl: "https://provider.unit/v1",
      apiKey: temporaryKey,
      context: { requestId: "req_ws_unavailable" }
    });
    expect(unavailable.error).toMatchObject({
      code: -32029,
      data: {
        code: "UPSTREAM_UNAVAILABLE",
        reason: "upstream_http",
        upstreamStatus: 503,
        requestId: "req_ws_unavailable"
      }
    });
    expect(JSON.stringify(unavailable)).not.toContain(temporaryKey);
    const invalid = await rpc(socket, 4, "provider/discover", {
      baseUrl: "https://provider.unit/v1",
      context: { requestId: "req_ws_invalid" }
    });
    expect(invalid.error).toMatchObject({ code: -32004, data: { code: "INVALID_ARGUMENT" } });

    await service.tokens.revoke(paired.deviceId);
    const rejected = await connect(url, paired.deviceToken);
    const countBefore = requests.length;
    const revoked = await rpc(rejected, 5, "provider/discover", {
      baseUrl: "https://provider.unit/v1",
      apiKey: temporaryKey
    });
    expect(revoked.error).toMatchObject({ code: -32001, data: { code: "UNAUTHORIZED" } });
    expect(requests).toHaveLength(countBefore);
    rejected.close();
    socket.close();
    await server.close();
  });
});
