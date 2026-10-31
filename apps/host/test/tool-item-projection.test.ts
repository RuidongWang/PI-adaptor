import { mkdir, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import {
  DeterministicAgentDriver,
  ToolOutputDeltaTracker,
  textFromToolResult
} from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
import { HostService } from "../src/server/host-service.js";

/// 契约 §7.2：`tool.updated` 的 `delta` 必须是**文本**。Pi 的
/// `tool_execution_update` 给的是 `AgentToolResult`，直接 `String(object)`
/// 会把 `[object Object]` 当作工具输出推给客户端。
describe("tool result text projection", () => {
  it("extracts the text of an AgentToolResult instead of stringifying the object", () => {
    expect(
      textFromToolResult({ content: [{ type: "text", text: "hello-from-tool" }], details: {} })
    ).toBe("hello-from-tool");
    expect(textFromToolResult({ content: [{ type: "text", text: "a" }, { type: "text", text: "b" }] })).toBe("ab");
    expect(textFromToolResult("plain")).toBe("plain");
    expect(textFromToolResult({ text: "typed" })).toBe("typed");
    expect(textFromToolResult({ content: [] })).toBe("");
    expect(textFromToolResult(undefined)).toBe("");
    expect(textFromToolResult({ content: [{ type: "text", text: "x" }] })).not.toContain("[object Object]");
  });

/// 契约 §7.2 的 `tool.updated` 是**追加**语义（`delta`），而 Pi 的
/// `tool_execution_update` 推的是**累计快照**：Host 必须换算成新增后缀，
/// 否则客户端把快照当增量拼接会得到重复文本。
describe("tool output delta synthesis", () => {
  it("emits only the new suffix of a cumulative snapshot", () => {
    const tracker = new ToolOutputDeltaTracker();
    expect(tracker.accept("call_1", "")).toBe("");
    expect(tracker.accept("call_1", "line 1\n")).toBe("line 1\n");
    expect(tracker.accept("call_1", "line 1\nline 2\n")).toBe("line 2\n");
    expect(tracker.accept("call_1", "line 1\nline 2\n")).toBe("");
    // 独立的工具调用各自记账。
    expect(tracker.accept("call_2", "other")).toBe("other");
  });

  it("does not emit an append delta when the snapshot was rewritten", () => {
    const tracker = new ToolOutputDeltaTracker();
    expect(tracker.accept("call_1", "a\nb\nc\n")).toBe("a\nb\nc\n");
    // 截断重写（例如只保留最后 N 行）：无法用追加表达，保持静默。
    expect(tracker.accept("call_1", "b\nc\nd\n")).toBe("");
    // 重写之后继续追加时，只发相对于新基线的新增部分。
    expect(tracker.accept("call_1", "b\nc\nd\ne\n")).toBe("e\n");
  });
});
});

async function setupWithHistory(): Promise<{
  service: HostService;
  auth: { device: { deviceId: string; label: string; role: "owner"; tokenHash: string; createdAt: string; lastUsedAt: string; revokedAt: null } };
  sessionId: string;
}> {
  const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tool-item-"));
  const project = join(root, "project");
  await mkdir(project, { recursive: true });
  const config = parseHostConfig(
    ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
    {},
    root
  );
  await ensureHostDirectories(config);
  // 真实 pi 历史：工具结果是 `role: "toolResult"` 的消息条目，带 `toolName` / `isError`。
  const sessionId = "sess_tool_fixture";
  const manager = SessionManager.create(project, config.sessionRoots[0]!, { id: sessionId });
  manager.appendMessage({ role: "user", content: "运行 bash", timestamp: 1 });
  manager.appendMessage({
    role: "toolResult",
    toolCallId: "call_1",
    toolName: "bash",
    content: [{ type: "text", text: "hello-from-tool" }],
    isError: false,
    timestamp: 2
  } as never);

  const service = new HostService(config, new DeterministicAgentDriver());
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
  // 扫描原生会话目录，让该会话进入 meta（attach 前必须先被发现）。
  await service.handle("session/list", {}, auth);
  return { service, auth, sessionId };
}

describe("tool items in the session history projection", () => {
  it("projects a native toolResult entry as a tool card carrying its body", async () => {
    const { service, auth, sessionId } = await setupWithHistory();
    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: {
        items: Array<{ id: string; itemType: string; toolName: string | null; text: string; status: string }>;
      };
    };
    const tool = attached.snapshot.items.find((item) => item.toolName === "bash");
    expect(tool, JSON.stringify(attached.snapshot.items)).toBeDefined();
    // 契约 §3.5：客户端按 `itemType`/`toolName` 决定渲染成工具卡片。
    expect(tool?.itemType).toBe("tool");
    expect(tool?.text).toBe("hello-from-tool");
    expect(tool?.status).toBe("completed");
  });
});
