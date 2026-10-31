import { WebSocketServer, type WebSocket } from "ws";
import type { IncomingMessage } from "node:http";
import { HostError, asHostError } from "../errors.js";
import { HostService } from "./host-service.js";

type RequestFrame = {
  jsonrpc: "2.0";
  id?: string | number;
  method: string;
  params?: unknown;
};

function tokenFrom(request: IncomingMessage): string | null {
  const header = request.headers.authorization;
  if (!header?.startsWith("Bearer ")) return null;
  return header.slice("Bearer ".length);
}

function send(socket: WebSocket, value: unknown): void {
  if (socket.readyState === socket.OPEN) socket.send(JSON.stringify(value));
}

export type RunningHostServer = {
  port: number;
  close(): Promise<void>;
};

export async function startWebSocketServer(
  service: HostService,
  port: number
): Promise<RunningHostServer> {
  const server = new WebSocketServer({
    host: "127.0.0.1",
    port,
    maxPayload: 1024 * 1024
  });
  await new Promise<void>((resolve, reject) => {
    server.once("listening", resolve);
    server.once("error", reject);
  });
  const sockets = new Set<WebSocket>();
  const socketDevices = new Map<WebSocket, string>();
  server.on("connection", (socket, request) => {
    sockets.add(socket);
    const subscriptions = new Set<string>();
    socket.on("error", () => undefined);
    socket.on("close", () => {
      sockets.delete(socket);
      socketDevices.delete(socket);
      for (const id of subscriptions) service.removeSubscription(id);
      subscriptions.clear();
    });
    const token = tokenFrom(request);
    socket.on("message", (raw, isBinary) => {
      if (isBinary) {
        socket.close(1003, "text frames only");
        return;
      }
      void handleMessage(service, socket, token, raw.toString(), socketDevices, sockets, subscriptions);
    });
  });
  return {
    port: (server.address() as { port: number }).port,
    async close() {
      for (const socket of sockets) socket.close();
      await new Promise<void>((resolve) => server.close(() => resolve()));
    }
  };
}

async function handleMessage(
  service: HostService,
  socket: WebSocket,
  token: string | null,
  raw: string,
  socketDevices: Map<WebSocket, string>,
  sockets: Set<WebSocket>,
  subscriptions: Set<string>
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
    if (frame.method === "connection/initialize") {
      auth = null;
    } else if (token && token.startsWith("pdt2.")) {
      auth = { device: await service.tokens.authenticate(token) };
      if (socket.readyState !== socket.OPEN) return;
      socketDevices.set(socket, auth.device.deviceId);
    } else if (!token || !token.startsWith("ppt2.")) {
      throw new HostError("UNAUTHORIZED", "a device or pairing token is required");
    }
    const result = await service.handle(frame.method, frame.params, auth,
      frame.method === "connection/pair" && token?.startsWith("ppt2.") ? token : undefined);
    if (frame.method === "connection/revoke" && result && typeof result === "object") {
      const revoked = (result as { revoked?: boolean }).revoked;
      const targetDevice = (frame.params as { deviceId?: string } | undefined)?.deviceId;
      if (revoked && targetDevice) {
        for (const candidate of sockets) {
          if (socketDevices.get(candidate) === targetDevice) candidate.close(1008, "device revoked");
        }
      }
    }
    if (frame.method === "events/subscribe" && result && typeof result === "object") {
      const subscription = result as { subscriptionId: string; replay?: unknown[] };
      if (socket.readyState !== socket.OPEN) {
        service.removeSubscription(subscription.subscriptionId);
        return;
      }
      subscriptions.add(subscription.subscriptionId);
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
      if (typeof id === "string") subscriptions.delete(id);
    }
    send(socket, { jsonrpc: "2.0", id: frame.id, result });
  } catch (error) {
    const hostError = asHostError(error);
    send(socket, hostError.toJSONRPC(frame.id ?? null));
  }
}
