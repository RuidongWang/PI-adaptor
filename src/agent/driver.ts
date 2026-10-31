import { join } from "node:path";
import {
  DefaultResourceLoader,
  ModelRuntime,
  SessionManager,
  SettingsManager,
  createAgentSession,
  type ExtensionFactory,
  type AgentSessionEvent
} from "@earendil-works/pi-coding-agent";
import type { ImageContent } from "@earendil-works/pi-ai";
import { HostError } from "../errors.js";
import { uuid } from "../util/id.js";

export type AgentEvent = {
  kind:
    | "turn.started"
    | "item.delta"
    | "item.completed"
    | "tool.started"
    | "tool.updated"
    | "tool.completed"
    | "turn.completed"
    | "turn.failed";
  payload: Record<string, unknown>;
};

export type AgentTurnRequest = {
  turnId: string;
  sessionId: string;
  cwd: string;
  sessionDir: string;
  sessionFile?: string | undefined;
  provider?: {
    id: string;
    name: string;
    baseUrl: string;
    apiKey: string | null;
    authKind?: "api_key" | "none";
    models: Array<{
      id: string;
      displayName: string;
      contextWindow: number;
      maxTokens: number;
      thinkingLevels: string[];
      defaultThinkingLevel: string | null;
      supportsImages: boolean;
    }>;
  } | undefined;
  modelId?: string | undefined;
  thinkingLevel?: string | undefined;
  text: string;
  images: ImageContent[];
  requestApproval?: ((toolName: string, input: unknown) => Promise<boolean>) | undefined;
  onEvent(event: AgentEvent): void;
};

export type AgentTurnHandle = {
  turnId: string;
  abort(): Promise<void>;
  wait(): Promise<void>;
};

export interface AgentDriver {
  readonly appendsPrompt: boolean;
  start(request: AgentTurnRequest): AgentTurnHandle;
}

export class DeterministicAgentDriver implements AgentDriver {
  readonly appendsPrompt = false;
  start(request: AgentTurnRequest): AgentTurnHandle {
    const turnId = request.turnId;
    let aborted = false;
    let resolveWait!: () => void;
    const waitPromise = new Promise<void>((resolve) => {
      resolveWait = resolve;
    });
    queueMicrotask(() => {
      if (aborted) return;
      request.onEvent({ kind: "turn.started", payload: { turnId } });
      const itemId = uuid();
      request.onEvent({
        kind: "item.delta",
        payload: { itemId, itemType: "message", delta: `Echo: ${request.text}` }
      });
      request.onEvent({
        kind: "item.completed",
        payload: {
          item: {
            id: itemId,
            itemType: "message",
            kind: "message",
            role: "assistant",
            text: `Echo: ${request.text}`,
            content: { text: `Echo: ${request.text}` }
          }
        }
      });
      request.onEvent({ kind: "turn.completed", payload: { turnId } });
      resolveWait();
    });
    return {
      turnId,
      async abort() {
        aborted = true;
        resolveWait();
      },
      wait: () => waitPromise
    };
  }
}

function itemIdFor(message: unknown): string {
  const value = message as { id?: unknown };
  return typeof value?.id === "string" ? value.id : uuid();
}
function textFromMessage(message: unknown): string {
  const content = (message as { content?: unknown })?.content;
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((part) => (part as { text?: unknown }).text)
    .filter((text): text is string => typeof text === "string")
    .join("");
}

/**
 * Pi 的 `tool_execution_update` 带的是 `AgentToolResult`（正文在 `content[].text`）。
 * 契约 §7.2 规定 `tool.updated` 的 `delta` 是**文本**；用 `String(object)` 会把
 * `[object Object]` 当成工具输出推给客户端，卡片正文因此全是噪声。
 */
export function textFromToolResult(result: unknown): string {
  if (typeof result === "string") return result;
  if (!result || typeof result !== "object") return "";
  const record = result as { text?: unknown; content?: unknown };
  if (typeof record.text === "string") return record.text;
  return textFromMessage(record);
}

/**
 * Pi 的 `tool_execution_update.partialResult.content[].text` 是**累计快照**
 * （bash 工具每次 `output.snapshot()` 推全量），而契约 §7.2 的 `tool.updated`
 * 携带的是追加语义的 `delta`。这里把快照换算成新增后缀，客户端与服务端的
 * live item 才能直接拼接而不重复。
 */
export class ToolOutputDeltaTracker {
  private readonly emitted = new Map<string, string>();

  /** 本次该推送的增量；无新增时返回空串。 */
  accept(itemId: string, snapshot: string): string {
    const previous = this.emitted.get(itemId) ?? "";
    if (snapshot === previous) return "";
    this.emitted.set(itemId, snapshot);
    // 快照被重写（例如输出被截断成最后 N 行）时无法用追加表达：不推送，
    // 完整结果仍由 `tool.completed` 的 `result` 给出。
    if (!snapshot.startsWith(previous)) return "";
    return snapshot.slice(previous.length);
  }

  forget(itemId: string): void {
    this.emitted.delete(itemId);
  }
}

export class PiAgentDriver implements AgentDriver {
  readonly appendsPrompt = true;
  constructor(private readonly agentDir: string, private readonly skillPaths: string[] = []) {}

  start(request: AgentTurnRequest): AgentTurnHandle {
    const turnId = request.turnId;
    let session: Awaited<ReturnType<typeof createAgentSession>>["session"] | undefined;
    let aborted = false;
    const waitPromise = (async () => {
      try {
        if (!request.provider) throw new HostError("PROVIDER_NOT_CONFIGURED", "provider is required");
        if (!request.modelId) throw new HostError("PROVIDER_NOT_CONFIGURED", "model is required");
        if (request.provider.authKind !== "none" && !request.provider.apiKey) {
          throw new HostError("PROVIDER_SECRET_MISSING", "provider secret is missing");
        }
        const runtime = await ModelRuntime.create({
          authPath: join(request.cwd, ".pi-host-auth.json"),
          modelsPath: null
        });
        runtime.registerProvider(request.provider.id, {
          name: request.provider.name,
          baseUrl: request.provider.baseUrl,
          apiKey: request.provider.apiKey ?? "none",
          api: "openai-completions",
          models: request.provider.models.map((model) => ({
            id: model.id,
            name: model.displayName,
            api: "openai-completions",
            input: model.supportsImages ? ["text", "image"] : ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: model.contextWindow,
            maxTokens: model.maxTokens,
            reasoning: model.thinkingLevels.length > 0
          }))
        });
        const model = runtime.getModel(request.provider.id, request.modelId);
        if (!model) throw new HostError("PROVIDER_NOT_CONFIGURED", "model is not configured");
        const settings = SettingsManager.inMemory({
          defaultProvider: request.provider.id,
          defaultModel: request.modelId,
          defaultThinkingLevel: request.thinkingLevel as never
        });
        const loader = new DefaultResourceLoader({
          cwd: request.cwd,
          agentDir: this.agentDir,
          settingsManager: settings,
          additionalSkillPaths: this.skillPaths,
          noExtensions: true,
          extensionFactories: request.requestApproval
            ? [
                ((pi) => {
                  pi.on("tool_call", async (event) => {
                    const allowed = await request.requestApproval?.(event.toolName, event.input);
                    return allowed === false
                      ? { block: true, reason: "Tool call denied by user" }
                      : undefined;
                  });
                }) satisfies ExtensionFactory
              ]
            : []
        });
        await loader.reload();
        const manager = request.sessionFile
          ? SessionManager.open(request.sessionFile)
          : SessionManager.create(request.cwd, request.sessionDir, { id: request.sessionId });
        const created = await createAgentSession({
          cwd: request.cwd,
          agentDir: this.agentDir,
          modelRuntime: runtime,
          model,
          thinkingLevel: request.thinkingLevel as never,
          sessionManager: manager,
          settingsManager: settings,
          resourceLoader: loader
        });
        session = created.session;
        if (aborted) {
          await session.abort();
          return;
        }
        // Pi streams cumulative snapshots via `message_update`; the authoritative
        // incremental text lives in `assistantMessageEvent`. Keep one stable item
        // id for the whole message so clients can append deltas into one bubble.
        let streamItemId: string | null = null;
        let terminalError: string | null = null;
        const toolOutput = new ToolOutputDeltaTracker();
        session.subscribe((event: AgentSessionEvent) => {
          const raw = event as unknown as Record<string, unknown>;
          const type = String(raw.type ?? "");
          if (type === "message_start") {
            const message = raw.message as { role?: string } | undefined;
            const role = message?.role ?? "assistant";
            if (role === "assistant") {
              streamItemId = itemIdFor(message);
              request.onEvent({
                kind: "item.delta",
                payload: { itemId: streamItemId, itemType: "message", delta: "" }
              });
            } else {
              streamItemId = null;
            }
          } else if (type === "message_update") {
            const update = raw.assistantMessageEvent as
              | { type?: string; delta?: string }
              | undefined;
            if (
              update?.type === "text_delta" &&
              typeof update.delta === "string" &&
              update.delta.length > 0
            ) {
              if (!streamItemId) streamItemId = uuid();
              request.onEvent({
                kind: "item.delta",
                payload: { itemId: streamItemId, itemType: "message", delta: update.delta }
              });
            }
          } else if (type === "message_end") {
            const message = raw.message as { role?: string; stopReason?: string; errorMessage?: string } | undefined;
            const role = message?.role ?? "assistant";
            if (message?.stopReason === "error" || message?.errorMessage) {
              terminalError = message.errorMessage ?? "Model returned error stopReason";
            }
            if (role === "system") {
              streamItemId = null;
              return;
            }
            const id = streamItemId ?? itemIdFor(message);
            streamItemId = null;
            request.onEvent({
              kind: "item.completed",
              payload: {
                item: {
                  id,
                  itemType: "message",
                  kind: "message",
                  role,
                  text: textFromMessage(message),
                  content: message,
                  attachments: []
                }
              }
            });
          } else if (type === "tool_execution_start") {
            request.onEvent({
              kind: "tool.started",
              payload: {
                itemId: String(raw.toolCallId ?? uuid()),
                toolName: String(raw.toolName ?? "tool"),
                input: raw.args ?? {}
              }
            });
          } else if (type === "tool_execution_update") {
            // Pi 推的是累计快照，契约要求追加增量：只发新增后缀（见 Tracker）。
            const itemId = String(raw.toolCallId ?? "");
            const delta = toolOutput.accept(itemId, textFromToolResult(raw.partialResult));
            if (delta) {
              request.onEvent({ kind: "tool.updated", payload: { itemId, delta } });
            }
          } else if (type === "tool_execution_end") {
            const itemId = String(raw.toolCallId ?? "");
            toolOutput.forget(itemId);
            request.onEvent({
              kind: "tool.completed",
              payload: {
                itemId,
                status: raw.isError ? "failed" : "completed",
                result: raw.result ?? {}
              }
            });
          } else if (type === "agent_settled") {
            if (terminalError) {
              request.onEvent({
                kind: "turn.failed",
                payload: { turnId, error: terminalError }
              });
            } else {
              request.onEvent({ kind: "turn.completed", payload: { turnId } });
            }
          }
        });
        request.onEvent({ kind: "turn.started", payload: { turnId } });
        await session.prompt(request.text, { images: request.images, streamingBehavior: "followUp" });
      } catch (error) {
        request.onEvent({
          kind: "turn.failed",
          payload: { turnId, error: error instanceof Error ? error.message : String(error) }
        });
      }
    })();
    return {
      turnId,
      async abort() {
        aborted = true;
        await session?.abort();
      },
      wait: () => waitPromise
    };
  }
}
