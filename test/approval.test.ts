import { mkdtemp, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { AgentDriver, AgentTurnHandle, AgentTurnRequest } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
import { HostService } from "../src/server/host-service.js";

/// A driver that always asks for a tool approval and leaves the turn pending, so
/// the service holds a live approval the way a real "ask"-mode turn does.
class ApprovalToolDriver implements AgentDriver {
  readonly appendsPrompt = true;
  start(request: AgentTurnRequest): AgentTurnHandle {
    let resolveWait!: () => void;
    const wait = new Promise<void>((resolve) => {
      resolveWait = resolve;
    });
    queueMicrotask(async () => {
      request.onEvent({ kind: "turn.started", payload: { turnId: request.turnId } });
      request.onEvent({
        kind: "tool.started",
        payload: { itemId: "call_1", toolName: "bash", input: { command: "echo hi" } }
      });
      await request.requestApproval?.("bash", { command: "echo hi" });
      request.onEvent({
        kind: "tool.completed",
        payload: { itemId: "call_1", status: "completed", result: {} }
      });
      request.onEvent({ kind: "turn.completed", payload: { turnId: request.turnId } });
      resolveWait();
    });
    return { turnId: request.turnId, async abort() {}, wait: () => wait };
  }
}

async function setup() {
  const root = await mkdtemp(join(tmpdir(), "pi-host-approval-test-"));
  const project = join(root, "project");
  await mkdir(project, { recursive: true });
  const config = parseHostConfig(
    ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
    {},
    root
  );
  await ensureHostDirectories(config);
  const service = new HostService(config, new ApprovalToolDriver());
  await service.init();
  const pairing = await service.createPairingToken();
  const paired = await service.pair({ deviceLabel: "test" }, pairing.token);
  const auth = {
    device: {
      deviceId: paired.deviceId,
      label: "test",
      role: "owner" as const,
      tokenHash: "test-hash",
      createdAt: new Date().toISOString(),
      lastUsedAt: new Date().toISOString(),
      revokedAt: null
    }
  };
  const projectRecord = await service.meta.registerProject(project, "project");
  const session = (await service.handle(
    "session/create",
    { projectId: projectRecord.id, permissionMode: "ask" },
    auth
  )) as { session: { id: string } };
  return { service, auth, sessionId: session.session.id };
}

describe("pending tool approvals", () => {
  it("replays a live approval through session/attach", async () => {
    const { service, auth, sessionId } = await setup();
    await service.handle("turn/start", { sessionId, input: { text: "run a tool" } }, auth);
    // The approval is created asynchronously after the turn starts.
    for (let i = 0; i < 50 && service["pendingApprovals"].size === 0; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { pendingApprovals: Array<{ id: string; title: string; toolName: string }> };
    };
    expect(attached.snapshot.pendingApprovals).toHaveLength(1);
    const approval = attached.snapshot.pendingApprovals[0]!;
    expect(approval.title).toBe("bash");
    expect(approval.toolName).toBe("bash");
    const responded = (await service.handle(
      "approval/respond",
      { approvalId: approval.id, decision: "allow-once" },
      auth
    )) as { resolved: boolean; alreadyResolved: boolean };
    expect(responded.resolved).toBe(true);
    expect(responded.alreadyResolved).toBe(false);
  });

  it("drops a pending approval once its turn is stopped", async () => {
    const { service, auth, sessionId } = await setup();
    const started = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "run a tool" } },
      auth
    )) as { turn: { id: string } };
    for (let i = 0; i < 50 && service["pendingApprovals"].size === 0; i += 1) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(service["pendingApprovals"].size).toBe(1);
    await service.handle("turn/interrupt", { turnId: started.turn.id }, auth);
    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { pendingApprovals: unknown[] };
    };
    expect(attached.snapshot.pendingApprovals).toHaveLength(0);
    // 客户端只按 `approval.resolved` 收敛卡片：turn 结束时必须显式告知，
    // 否则这张「权限请求」会永久留在会话里（用户点了必定失败）。
    let resolved: Array<{ kind: string; payload: unknown }> = [];
    for (let i = 0; i < 50 && resolved.length === 0; i += 1) {
      resolved = service.journal
        .replay("session", sessionId, { epoch: service.journal.epoch, sequence: 0 })
        .filter((event) => event.kind === "approval.resolved");
      if (resolved.length === 0) await new Promise((resolve) => setTimeout(resolve, 10));
    }
    expect(resolved).toHaveLength(1);
    expect(resolved[0]?.payload).toMatchObject({ status: "denied" });
  });
});
