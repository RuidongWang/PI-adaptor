import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import WebSocket from "ws";
import { describe, expect, it } from "vitest";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import type { AgentDriver, AgentTurnHandle, AgentTurnRequest } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
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
    await new Promise((resolve) => setTimeout(resolve, 30));
    expect(events.some((frame) => frame.params.event.kind === "turn.completed")).toBe(true);

    const history = await rpc(socket, 6, "session/attach", { sessionId });
    expect(history.result.snapshot.items.some((item: any) => item.text === "hello")).toBe(true);

    const closed = new Promise<void>((resolve) => socket.once("close", () => resolve()));
    socket.close();
    await closed;
    await new Promise((resolve) => setTimeout(resolve, 10));
    expect((service as any).subscriptions.size).toBe(0);
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
});
