import { join } from "node:path";
import { AgentDriver, textFromToolResult, type AgentEvent, type AgentTurnHandle, type AgentTurnRequest } from "../agent/driver.js";
import type { HostConfig } from "../config.js";
import { HostError } from "../errors.js";
import type { HostEvent } from "../events/journal.js";
import type { ExtensionRegistry } from "../extensions/registry.js";
import type { ExtensionSnapshotStore } from "../extensions/snapshot-store.js";
import type { ExtensionSnapshot } from "../extensions/types.js";
import type { BlobStore } from "../media/blob-store.js";
import type { MetaStore, SessionMeta } from "../meta/store.js";
import type { NativeSessionCatalog } from "../pi/session-catalog.js";
import type { ProviderStore } from "../providers/store.js";
import type { SkillRegistry } from "../skills/registry.js";
import { sha256, uuid } from "../util/id.js";
import { KeyedMutex } from "../util/keyed-mutex.js";
import {
  HISTORY_TEXT_CHUNK_BYTES,
  HISTORY_TEXT_PREVIEW_BYTES,
  LIVE_EVENT_PAYLOAD_BYTES,
  SNAPSHOT_ACTIVE_ITEMS_BYTES,
  SNAPSHOT_QUEUE_TEXT_BYTES,
  projectContent,
  textPreview
} from "./history-projector.js";
import { ACTIVE_TURN_STATUSES, TurnStore, type TurnRecord } from "./turn-store.js";

const APPROVAL_INLINE_BYTES = 4 * 1024;
const MAX_APPROVAL_INPUT_BYTES = 16 * 1024 * 1024;
const MAX_PENDING_APPROVAL_BYTES = 64 * 1024 * 1024;
const MAX_PENDING_SESSION_APPROVALS = 16;
const MAX_QUEUED_TURNS_PER_SESSION = 20;
const MAX_QUEUED_TURNS_TOTAL = 200;
const MAX_QUEUED_TEXT_BYTES_TOTAL = 8 * 1024 * 1024;

export type LiveItem = {
  itemId: string;
  itemType: string;
  kind: string;
  role?: string | undefined;
  text: string;
  toolName?: string | undefined;
  status: string;
};

export type TurnState = {
  id: string;
  sessionId: string;
  status: string;
  createdAt: string;
  settledAt: string | null;
  settledReason?: string;
  stopRequested?: boolean;
  handle?: { abort(): Promise<void>; wait(): Promise<void> };
};

export type PendingApproval = {
  sessionId: string;
  turnId: string;
  toolName: string;
  input: unknown;
  fullInput?: Buffer;
  inputDigest?: string;
  revision: number;
  resolve: (allowed: boolean) => void;
};

export type QueuedTurnStart = {
  turnId: string;
  text: string;
  attachmentCount: number;
  run: () => Promise<void>;
};

export type TurnProvider = Awaited<ReturnType<ProviderStore["list"]>>[number];

function str(value: unknown, field: string): string {
  if (typeof value !== "string" || value.length === 0) {
    throw new HostError("INVALID_ARGUMENT", `${field} is required`);
  }
  return value;
}

function obj(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new HostError("INVALID_ARGUMENT", "object params are required");
  }
  return value as Record<string, unknown>;
}

function providerCredentialScope(provider: TurnProvider | undefined): string | undefined {
  if (!provider) return undefined;
  return JSON.stringify([provider.id, provider.baseUrl, provider.protocol, provider.authKind]);
}

export function transientApiKey(params: Record<string, unknown>): string | undefined {
  const value = params.apiKey;
  if (value === undefined) return undefined;
  if (typeof value !== "string" || value.length === 0) {
    throw new HostError("INVALID_ARGUMENT", "apiKey must be a non-empty string", { field: "apiKey" });
  }
  if (value.length > 16_384 || /[\r\n]/.test(value)) {
    throw new HostError("INVALID_ARGUMENT", "apiKey must be at most 16384 characters without CR/LF", {
      field: "apiKey"
    });
  }
  return value;
}

export type TurnCoordinatorDeps = {
  config: HostConfig;
  meta: MetaStore;
  catalog: NativeSessionCatalog;
  blobs: BlobStore;
  providers: ProviderStore;
  skills: SkillRegistry;
  extensions: ExtensionRegistry;
  extensionSnapshots: ExtensionSnapshotStore;
  turnStore: TurnStore;
  driver: AgentDriver;
  sessionLocks: KeyedMutex;
  getHostId: () => string;
  isShuttingDown: () => boolean;
  trackWork: <T>(work: Promise<T>) => Promise<T>;
  emit: (scope: "host" | "session", kind: string, payload: Record<string, unknown>, extra?: Partial<HostEvent>) => Promise<HostEvent>;
  requireSession: (sessionId: string) => Promise<SessionMeta>;
  updateSessionWriteState: (session: SessionMeta, reason: string | null) => Promise<SessionMeta>;
};

export class TurnCoordinator {
  readonly executingDrivers = new Map<string, string>();
  readonly turns = new Map<string, TurnState>();
  readonly turnEventChains = new Map<string, Promise<void>>();
  readonly liveItems = new Map<string, Map<string, LiveItem>>();
  readonly queuedStarts = new Map<string, QueuedTurnStart[]>();
  readonly pendingApprovals = new Map<string, PendingApproval>();
  private readonly draining = new Set<string>();
  private readonly turnStopLocks = new KeyedMutex();
  private readonly allowedSessionTools = new Map<string, Set<string>>();
  public approvalRevision = 0;

  constructor(private readonly deps: TurnCoordinatorDeps) {}

  seedRecoveredTurns(records: TurnRecord[]): void {
    for (const record of records) {
      this.turns.set(record.id, {
        id: record.id,
        sessionId: record.sessionId,
        status: record.status,
        createdAt: record.createdAt,
        settledAt: record.settledAt,
        ...(record.settledReason ? { settledReason: record.settledReason } : {})
      });
    }
  }

  async shutdown(): Promise<void> {
    const active = [...this.turns.values()].filter((turn) => ACTIVE_TURN_STATUSES.has(turn.status));
    await Promise.allSettled(active.map((turn) => this.stopTurn(turn.id, "interrupted")));
    for (const turnId of this.executingDrivers.values()) {
      this.settleApprovalsForTurn(turnId);
      const handle = this.turns.get(turnId)?.handle;
      if (handle) this.deps.trackWork(handle.abort());
    }
  }

  activeTurnIdFor(sessionId: string): string | null {
    const executing = this.executingDrivers.get(sessionId);
    if (executing) return executing;
    for (const turn of this.turns.values()) {
      if (turn.sessionId === sessionId && turn.status !== "queued" && ACTIVE_TURN_STATUSES.has(turn.status)) {
        return turn.id;
      }
    }
    return null;
  }

  sessionBusy(sessionId: string): boolean {
    return this.activeTurnIdFor(sessionId) !== null || (this.queuedStarts.get(sessionId)?.length ?? 0) > 0;
  }

  clearSessionQueue(sessionId: string): void {
    this.queuedStarts.delete(sessionId);
  }

  publicTurn(turn: TurnState): Record<string, unknown> {
    return {
      id: turn.id,
      sessionId: turn.sessionId,
      status: turn.status,
      createdAt: turn.createdAt,
      settledAt: turn.settledAt,
      ...(turn.settledReason ? { settledReason: turn.settledReason } : {})
    };
  }

  activeItemPreviews(turnId: string) {
    const previews = [];
    let bytes = 2;
    for (const item of [...(this.liveItems.get(turnId)?.values() ?? [])].reverse()) {
      const preview = {
        id: item.itemId,
        itemType: item.itemType,
        kind: item.kind,
        role: item.role ?? null,
        text: textPreview(item.text, HISTORY_TEXT_PREVIEW_BYTES),
        status: item.status,
        turnId,
        toolName: item.toolName ?? null
      };
      const size = Buffer.byteLength(JSON.stringify(preview), "utf8") + 1;
      if (bytes + size > SNAPSHOT_ACTIVE_ITEMS_BYTES) continue;
      previews.push(preview);
      bytes += size;
    }
    return previews.reverse();
  }

  queuedTurnSnapshots(sessionId: string) {
    return (this.queuedStarts.get(sessionId) ?? []).flatMap((entry) => {
      const turn = this.turns.get(entry.turnId);
      if (!turn) return [];
      return [
        {
          ...this.publicTurn(turn),
          text: textPreview(entry.text, SNAPSHOT_QUEUE_TEXT_BYTES),
          attachmentCount: entry.attachmentCount
        }
      ];
    });
  }

  pendingApprovalSnapshots(sessionId: string) {
    return [...this.pendingApprovals.entries()]
      .filter(([, pending]) => pending.sessionId === sessionId)
      .map(([id, pending]) => this.approvalProjection(id, pending));
  }

  async sessionProvider(session: SessionMeta): Promise<TurnProvider | undefined> {
    return session.providerId
      ? (await this.deps.providers.list()).find((entry) => entry.id === session.providerId)
      : undefined;
  }

  assertProviderKey(provider: TurnProvider | undefined, apiKey: string | undefined, rawBinding: unknown): void {
    if (rawBinding !== undefined) {
      const binding = obj(rawBinding);
      const providerId = str(binding.providerId, "providerBinding.providerId");
      const baseUrl = str(binding.baseUrl, "providerBinding.baseUrl");
      if (provider?.id !== providerId || provider.baseUrl !== baseUrl) {
        throw new HostError("CONFLICT", "Model service or endpoint changed. Review its settings and retry.", {
          field: "providerBinding"
        });
      }
    }
    if (provider?.authKind !== "api_key") return;
    if (!apiKey) {
      throw new HostError("PROVIDER_SECRET_MISSING", "apiKey is required for this provider", { field: "apiKey" });
    }
    if (rawBinding === undefined) {
      throw new HostError("INVALID_ARGUMENT", "An API key requires a provider binding. Update the client and retry.", {
        field: "providerBinding"
      });
    }
  }

  async startTurn(params: Record<string, unknown>) {
    if (this.deps.isShuttingDown()) throw new HostError("CAPABILITY_UNAVAILABLE", "host is shutting down");
    const sessionId = str(params.sessionId, "sessionId");
    const input = obj(params.input);
    const text = typeof input.text === "string" ? input.text : "";
    const attachments = Array.isArray(input.attachments)
      ? input.attachments.filter((value): value is string => typeof value === "string")
      : [];
    if (!text && attachments.length === 0) throw new HostError("INVALID_ARGUMENT", "message is empty");
    if (attachments.length > 10) throw new HostError("ATTACHMENT_INVALID", "too many images");
    const admission = params.admission === "queue" ? "queue" : "reject_if_busy";
    const apiKey = transientApiKey(params);

    const plan = await this.deps.sessionLocks.run(sessionId, async () => {
      const session = await this.deps.requireSession(sessionId);
      if (session.readOnlyReason) throw new HostError("SESSION_READ_ONLY", session.readOnlyReason);
      const provider = await this.sessionProvider(session);
      this.assertProviderKey(provider, apiKey, params.providerBinding);
      if (this.deps.isShuttingDown()) throw new HostError("CAPABILITY_UNAVAILABLE", "host is shutting down");
      if (this.sessionBusy(sessionId)) {
        if (admission === "reject_if_busy") {
          throw new HostError("SESSION_BUSY", "session already has a running or queued turn");
        }
        const queue = this.queuedStarts.get(sessionId) ?? [];
        const queuedBytes = [...this.queuedStarts.values()]
          .flat()
          .reduce((total, entry) => total + Buffer.byteLength(entry.text, "utf8"), 0);
        const queuedCount = [...this.queuedStarts.values()].reduce((total, entries) => total + entries.length, 0);
        if (
          queue.length >= MAX_QUEUED_TURNS_PER_SESSION ||
          queuedCount >= MAX_QUEUED_TURNS_TOTAL ||
          queuedBytes + Buffer.byteLength(text, "utf8") > MAX_QUEUED_TEXT_BYTES_TOTAL
        ) {
          throw new HostError("QUEUE_FULL", "queued turn limit reached; retry after the queue drains");
        }
        const queuedId = uuid();
        const queued: TurnState = {
          id: queuedId,
          sessionId,
          status: "queued",
          createdAt: new Date().toISOString(),
          settledAt: null
        };
        const keyScope = providerCredentialScope(provider);
        this.turns.set(queuedId, queued);
        queue.push({
          turnId: queuedId,
          text,
          attachmentCount: attachments.length,
          run: async () => {
            const fresh = await this.deps.requireSession(sessionId);
            if (fresh.readOnlyReason) throw new HostError("SESSION_READ_ONLY", fresh.readOnlyReason);
            const currentProvider = await this.sessionProvider(fresh);
            if (apiKey && providerCredentialScope(currentProvider) !== keyScope) {
              throw new HostError("CONFLICT", "Model service changed while queued. Review the service and resend.", {
                field: "providerId"
              });
            }
            this.assertProviderKey(currentProvider, apiKey, params.providerBinding);
            await this.launchTurn(fresh, queuedId, text, attachments, currentProvider, apiKey);
          }
        });
        this.queuedStarts.set(sessionId, queue);
        try {
          await this.persistTurnBeforeStart(queued);
        } catch (error) {
          this.turns.delete(queuedId);
          this.removeQueuedStart(sessionId, queuedId);
          throw error;
        }
        return { kind: "queued" as const, turn: queued };
      }
      const turnId = uuid();
      const placeholder: TurnState = {
        id: turnId,
        sessionId,
        status: "running",
        createdAt: new Date().toISOString(),
        settledAt: null
      };
      this.turns.set(turnId, placeholder);
      return { kind: "running" as const, turnId, session, provider };
    });

    if (plan.kind === "queued") {
      return { turn: this.publicTurn(plan.turn) };
    }

    try {
      const turn = await this.launchTurn(plan.session, plan.turnId, text, attachments, plan.provider, apiKey);
      return { turn: this.publicTurn(turn) };
    } catch (error) {
      if (error instanceof HostError && error.code === "SESSION_READ_ONLY") {
        await this.deps.sessionLocks
          .run(sessionId, async () => {
            await this.deps.updateSessionWriteState(await this.deps.requireSession(sessionId), error.message);
          })
          .catch(() => undefined);
      }
      if (!this.turns.get(plan.turnId)?.stopRequested) {
        await this.settleTurn(plan.turnId, "failed", "turn_start_failed").catch(() => undefined);
      }
      void this.drainQueue(sessionId);
      throw error;
    }
  }

  getTurn(turnId: string): TurnState {
    const turn = this.turns.get(turnId);
    if (!turn) throw new HostError("NOT_FOUND", "turn not found");
    return turn;
  }

  stopTurn(turnId: string, status: "interrupted" | "canceled") {
    return this.turnStopLocks.run(turnId, () => this.stopTurnOnce(turnId, status));
  }

  readApproval(params: Record<string, unknown>, deviceRole: string) {
    if (deviceRole !== "owner") throw new HostError("FORBIDDEN", "approval requires owner");
    const pending = this.pendingApprovals.get(str(params.approvalId, "approvalId"));
    if (!pending?.fullInput || pending.sessionId !== str(params.sessionId, "sessionId")) {
      throw new HostError("NOT_FOUND", "approval input is no longer available");
    }
    if (params.revision !== pending.revision) throw new HostError("APPROVAL_STALE", "approval revision does not match");
    const offset = params.offset;
    if (typeof offset !== "number" || !Number.isSafeInteger(offset) || offset < 0 || offset >= pending.fullInput.length) {
      throw new HostError("INVALID_ARGUMENT", "approval input offset is out of range");
    }
    return {
      dataBase64: pending.fullInput.subarray(offset, offset + HISTORY_TEXT_CHUNK_BYTES).toString("base64"),
      totalBytes: pending.fullInput.length
    };
  }

  async respondApproval(params: Record<string, unknown>, deviceRole: string) {
    const approvalId = str(params.approvalId, "approvalId");
    const pending = this.pendingApprovals.get(approvalId);
    if (!pending) return { resolved: true, alreadyResolved: true, effectivePermissionMode: "ask" };
    if (deviceRole !== "owner") throw new HostError("FORBIDDEN", "approval requires owner");
    const expectedRevision =
      typeof params.expectedRevision === "number"
        ? params.expectedRevision
        : typeof (params.context as { expectedRevision?: unknown } | undefined)?.expectedRevision === "number"
          ? (params.context as { expectedRevision: number }).expectedRevision
          : undefined;
    if (expectedRevision !== undefined && expectedRevision !== pending.revision) {
      throw new HostError("APPROVAL_STALE", "approval revision does not match");
    }
    const decision = str(params.decision, "decision");
    const allowed = decision === "allow-once" || decision === "allow-session" || decision === "approve";
    if (allowed && pending.fullInput && (expectedRevision !== pending.revision || params.inputDigest !== pending.inputDigest)) {
      throw new HostError("INVALID_ARGUMENT", "review the full approval input before allowing this request");
    }
    if (decision === "allow-session") {
      const tools = this.allowedSessionTools.get(pending.sessionId) ?? new Set<string>();
      tools.add(pending.toolName);
      this.allowedSessionTools.set(pending.sessionId, tools);
    }
    this.pendingApprovals.delete(approvalId);
    pending.resolve(allowed);
    await this.deps.emit(
      "session",
      "approval.resolved",
      { approvalId, status: allowed ? "allowed" : "denied" },
      { sessionId: pending.sessionId, turnId: pending.turnId, revision: pending.revision }
    );
    return { resolved: true, alreadyResolved: false, effectivePermissionMode: "ask" };
  }

  private removeQueuedStart(sessionId: string, turnId: string): void {
    const queue = this.queuedStarts.get(sessionId);
    if (!queue) return;
    const remaining = queue.filter((entry) => entry.turnId !== turnId);
    if (remaining.length === 0) this.queuedStarts.delete(sessionId);
    else this.queuedStarts.set(sessionId, remaining);
  }

  private async persistTurnBeforeStart(turn: TurnState): Promise<void> {
    try {
      await this.deps.turnStore.upsert(this.toRecord(turn));
    } catch {
      throw new HostError(
        "CAPABILITY_UNAVAILABLE",
        "Unable to save the turn before starting. Retry when Host storage is available."
      );
    }
  }

  private toRecord(turn: TurnState): TurnRecord {
    return {
      id: turn.id,
      sessionId: turn.sessionId,
      status: turn.status,
      createdAt: turn.createdAt,
      settledAt: turn.settledAt,
      ...(turn.settledReason ? { settledReason: turn.settledReason } : {})
    };
  }

  private async launchTurn(
    session: SessionMeta,
    turnId: string,
    text: string,
    attachmentIds: string[],
    provider: TurnProvider | undefined,
    apiKey?: string
  ): Promise<TurnState> {
    const turn = this.getTurn(turnId);
    if (turn.stopRequested || !ACTIVE_TURN_STATUSES.has(turn.status)) return turn;
    const skills = this.deps.driver.appendsPrompt ? await this.deps.skills.activeSkills() : undefined;
    const images = [];
    for (const id of attachmentIds) {
      const { dataBase64, mimeType } = await this.deps.blobs.readForTurn(id, session.id);
      images.push({ type: "image", data: dataBase64, mimeType });
    }
    const nativePath = await this.deps.sessionLocks.run(session.id, async () => {
      if (turn.stopRequested || !ACTIVE_TURN_STATUSES.has(turn.status)) return;
      await this.persistTurnBeforeStart(turn);
      if (turn.stopRequested) return;
      let path = (await this.deps.requireSession(session.id)).nativePath;
      if (!path) {
        path = await this.deps.catalog.createFile(session.projectPath, join(this.deps.config.dataDir, "sessions"), session.id);
        await this.deps.meta.updateSession(session.id, { nativePath: path });
      }
      if (!turn.stopRequested && !this.deps.driver.appendsPrompt && text) {
        await this.deps.catalog.appendUserMessage(path, text, Date.now(), session.id);
      }
      return path;
    });
    if (!nativePath || turn.stopRequested || !ACTIVE_TURN_STATUSES.has(turn.status)) return turn;

    let exited = false;
    const request: AgentTurnRequest = {
      turnId,
      sessionId: session.id,
      cwd: session.projectPath,
      sessionDir: join(this.deps.config.dataDir, "sessions"),
      sessionFile: nativePath,
      ...(skills ? { skills } : {}),
      provider: provider
        ? {
            id: provider.id,
            name: provider.name,
            baseUrl: provider.baseUrl,
            apiKey: provider.authKind === "api_key" ? (apiKey ?? null) : null,
            authKind: provider.authKind,
            protocol: provider.protocol,
            models: provider.models
          }
        : undefined,
      modelId: session.modelId ?? undefined,
      thinkingLevel: session.thinkingLevel ?? undefined,
      text,
      images: images as never,
      extensions: {
        registry: this.deps.extensions,
        hostId: this.deps.getHostId(),
        publish: (snapshot) => (exited ? Promise.resolve() : this.publishExtensionSnapshot(session.id, turnId, snapshot))
      },
      onSessionReadOnly: async (reason) => {
        await this.deps.sessionLocks
          .run(session.id, async () => {
            await this.deps.updateSessionWriteState(await this.deps.requireSession(session.id), reason);
          })
          .catch(() => undefined);
      },
      requestApproval: async (toolName: string, toolInput: unknown) => {
        const currentSession = await this.deps.requireSession(session.id);
        if (this.deps.isShuttingDown() || turn.stopRequested || !ACTIVE_TURN_STATUSES.has(turn.status)) return false;
        if (currentSession.permissionMode === "auto") return true;
        return this.requestApproval(currentSession, turnId, toolName, toolInput);
      },
      onEvent: (event) => {
        if (exited || this.executingDrivers.get(session.id) !== turnId) return;
        const prev = this.turnEventChains.get(turnId) ?? Promise.resolve();
        const next = prev
          .then(async () => {
            if (this.executingDrivers.get(session.id) !== turnId) return;
            await this.handleAgentEvent(session.id, turnId, event);
          })
          .catch((err) => {
            console.error(`handleAgentEvent failed for turn ${turnId}:`, err);
          });
        this.turnEventChains.set(turnId, next);
      }
    };

    // A driver can publish its initial extension snapshot from inside start().
    this.executingDrivers.set(session.id, turnId);
    let handle: AgentTurnHandle;
    try {
      handle = this.deps.driver.start(request);
    } catch (error) {
      this.executingDrivers.delete(session.id);
      this.turnEventChains.delete(turnId);
      throw error;
    }
    turn.handle = handle;
    const settled = this.deps.trackWork(
      handle
        .wait()
        .then(
          () => false,
          () => true
        )
        .then(async (failed) => {
          exited = true;
          await (this.turnEventChains.get(turn.id) ?? Promise.resolve());
          this.turnEventChains.delete(turn.id);
          const current = this.turns.get(turn.id);
          if (current && ACTIVE_TURN_STATUSES.has(current.status) && !current.stopRequested) {
            await this.handleAgentEvent(session.id, turn.id, {
              kind: failed ? "turn.failed" : "turn.completed",
              payload: failed ? { error: "Agent turn failed; sensitive error details withheld" } : {}
            });
          }
        })
        .finally(() => {
          delete turn.handle;
          if (this.executingDrivers.get(session.id) === turn.id) this.executingDrivers.delete(session.id);
          if (!turn.stopRequested) void this.drainQueue(session.id);
        })
    );
    await Promise.race([settled, this.deps.sessionLocks.run(session.id, async () => undefined)]);
    if (exited) await settled;
    return turn;
  }

  private async settleTurn(
    turnId: string,
    status: string,
    settledReason?: string,
    fromDriver = false
  ): Promise<boolean> {
    const turn = this.turns.get(turnId);
    if (!turn) return false;
    return this.deps.sessionLocks.run(turn.sessionId, async () => {
      if (!ACTIVE_TURN_STATUSES.has(turn.status) || (fromDriver && turn.stopRequested)) return false;
      turn.status = status;
      turn.settledAt = new Date().toISOString();
      if (settledReason) turn.settledReason = settledReason;
      this.liveItems.delete(turnId);
      this.settleApprovalsForTurn(turnId);
      await this.deps.turnStore.upsert(this.toRecord(turn));
      return true;
    });
  }

  private trackLiveItem(turnId: string, payload: Record<string, unknown>, tool = false): void {
    const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined;
    if (!itemId) return;
    let items = this.liveItems.get(turnId);
    if (!items) {
      items = new Map();
      this.liveItems.set(turnId, items);
    }
    const existing = items.get(itemId);
    const delta = typeof payload.delta === "string" ? payload.delta : "";
    const toolName = typeof payload.toolName === "string" ? payload.toolName : existing?.toolName;
    items.set(itemId, {
      itemId,
      itemType: tool ? "tool" : ((payload.itemType as string | undefined) ?? existing?.itemType ?? "message"),
      kind: tool ? "tool" : ((payload.kind as string | undefined) ?? existing?.kind ?? "message"),
      role: existing?.role ?? (tool ? undefined : "assistant"),
      text: `${existing?.text ?? ""}${delta}`,
      status: "streaming",
      ...(toolName ? { toolName } : {})
    });
  }

  private removeLiveItem(turnId: string, payload: Record<string, unknown>): void {
    const itemId = typeof payload.itemId === "string" ? payload.itemId : undefined;
    if (!itemId) return;
    this.liveItems.get(turnId)?.delete(itemId);
  }

  private drainQueue(sessionId: string): Promise<void> {
    if (this.deps.isShuttingDown()) return Promise.resolve();
    return this.deps.trackWork(this.drainQueueOnce(sessionId));
  }

  private async drainQueueOnce(sessionId: string): Promise<void> {
    if (this.draining.has(sessionId)) return;
    this.draining.add(sessionId);
    try {
      const next = await this.deps.sessionLocks.run(sessionId, async () => {
        if (this.deps.isShuttingDown() || this.activeTurnIdFor(sessionId)) return undefined;
        const queue = this.queuedStarts.get(sessionId);
        if (!queue || queue.length === 0) return undefined;
        const item = queue.shift()!;
        if (queue.length === 0) this.queuedStarts.delete(sessionId);
        const turn = this.turns.get(item.turnId);
        if (!turn || turn.status !== "queued") return undefined;
        turn.status = "running";
        turn.stopRequested = false;
        return item;
      });
      if (!next) return;
      try {
        await next.run();
      } catch (error) {
        const queued = this.turns.get(next.turnId);
        if (queued && !queued.stopRequested && ACTIVE_TURN_STATUSES.has(queued.status)) {
          await this.settleTurn(next.turnId, "failed", "queue_start_failed").catch(() => undefined);
          await this.deps.sessionLocks
            .run(sessionId, () =>
              this.deps.emit(
                "session",
                "turn.failed",
                {
                  turn: this.publicTurn(queued),
                  error: error instanceof HostError ? error.message : "Queued turn could not start."
                },
                { sessionId, turnId: next.turnId }
              )
            )
            .catch(() => undefined);
        }
      }
    } finally {
      this.draining.delete(sessionId);
    }
    void this.drainQueue(sessionId);
  }

  async requestApproval(
    session: SessionMeta,
    turnId: string,
    toolName: string,
    input: unknown
  ): Promise<boolean> {
    const turn = this.turns.get(turnId);
    if (this.deps.isShuttingDown() || !turn || turn.stopRequested || !ACTIVE_TURN_STATUSES.has(turn.status)) return false;
    if (this.allowedSessionTools.get(session.id)?.has(toolName)) return true;
    if (
      [...this.pendingApprovals.values()].filter((pending) => pending.sessionId === session.id).length >=
      MAX_PENDING_SESSION_APPROVALS
    ) {
      return false;
    }
    const encoded = Buffer.from(JSON.stringify(input) ?? "null", "utf8");
    if (encoded.length > MAX_APPROVAL_INPUT_BYTES) return false;
    if (encoded.length > APPROVAL_INLINE_BYTES) {
      const pendingBytes = [...this.pendingApprovals.values()].reduce(
        (total, pending) => total + (pending.fullInput?.length ?? 0),
        0
      );
      if (pendingBytes + encoded.length > MAX_PENDING_APPROVAL_BYTES) return false;
    }
    const approvalId = uuid();
    const revision = ++this.approvalRevision;
    const fullInput = encoded.length > APPROVAL_INLINE_BYTES ? encoded : undefined;
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this.pendingApprovals.delete(approvalId);
        resolve(false);
      }, 24 * 60 * 60 * 1000);
      const pending: PendingApproval = {
        sessionId: session.id,
        turnId,
        toolName,
        input: fullInput ? { preview: textPreview(encoded.subarray(0, 1024).toString("utf8"), 512) } : input,
        ...(fullInput ? { fullInput, inputDigest: sha256(fullInput) } : {}),
        revision,
        resolve: (allowed) => {
          clearTimeout(timer);
          resolve(allowed);
        }
      };
      this.pendingApprovals.set(approvalId, pending);
      this.deps
        .trackWork(
          this.deps.emit(
            "session",
            "approval.requested",
            { approval: this.approvalProjection(approvalId, pending) },
            { sessionId: session.id, turnId, revision }
          )
        )
        .catch(() => {
          clearTimeout(timer);
          this.pendingApprovals.delete(approvalId);
          resolve(false);
        });
    });
  }

  private approvalProjection(id: string, pending: PendingApproval) {
    return {
      id,
      revision: pending.revision,
      kind: "tool",
      title: textPreview(pending.toolName, 256),
      toolName: textPreview(pending.toolName, 256),
      input: pending.input,
      expiresAt: null,
      ...(pending.fullInput ? { inputByteLength: pending.fullInput.length } : {})
    };
  }

  private settleApprovalsForTurn(turnId: string): void {
    for (const [approvalId, pending] of [...this.pendingApprovals.entries()]) {
      if (pending.turnId !== turnId) continue;
      this.pendingApprovals.delete(approvalId);
      pending.resolve(false);
      void this.deps
        .trackWork(
          this.deps.emit(
            "session",
            "approval.resolved",
            { approvalId, status: "denied" },
            { sessionId: pending.sessionId, turnId: pending.turnId, revision: pending.revision }
          )
        )
        .catch((error) => console.error("approval resolution event failed:", error));
    }
  }

  private publishExtensionSnapshot(sessionId: string, turnId: string, snapshot: ExtensionSnapshot): Promise<void> {
    if (this.executingDrivers.get(sessionId) !== turnId) return Promise.resolve();
    const previous = this.turnEventChains.get(turnId) ?? Promise.resolve();
    const next = previous.then(() =>
      this.deps.sessionLocks.run(sessionId, async () => {
        await this.deps.requireSession(sessionId);
        const turn = this.turns.get(turnId);
        if (
          !turn ||
          this.executingDrivers.get(sessionId) !== turnId ||
          snapshot.turnId !== turnId ||
          snapshot.sessionId !== sessionId ||
          snapshot.hostId !== this.deps.getHostId()
        ) {
          return;
        }
        const saved = await this.deps.extensionSnapshots.put(snapshot);
        if (saved) await this.deps.emit("session", "session.extensions.updated", saved, { sessionId, turnId });
      })
    );
    this.turnEventChains.set(turnId, next.catch(() => undefined));
    return next;
  }

  private async handleAgentEvent(sessionId: string, turnId: string, event: AgentEvent) {
    let payload = event.payload;
    if (event.kind === "item.delta") {
      if (typeof payload.delta === "string") payload = { ...payload, delta: textPreview(payload.delta, 32 * 1024) };
      this.trackLiveItem(turnId, payload);
    } else if (event.kind === "tool.started" || event.kind === "tool.updated") {
      if (event.kind === "tool.updated" && typeof payload.delta === "string") {
        payload = { ...payload, delta: textPreview(payload.delta, 32 * 1024) };
      } else if (Buffer.byteLength(JSON.stringify(payload)) > LIVE_EVENT_PAYLOAD_BYTES) {
        payload = {
          itemId: payload.itemId,
          toolName: payload.toolName,
          input: { omitted: "Tool input exceeds the live preview limit" }
        };
      }
      this.trackLiveItem(turnId, payload, true);
    } else if (event.kind === "item.completed") {
      const item = payload.item as
        | { id?: string; role?: string; text?: unknown; content?: unknown }
        | undefined;
      const rawContent = item?.content;
      const contentValue =
        rawContent && typeof rawContent === "object" && !Array.isArray(rawContent) && "content" in rawContent
          ? (rawContent as { content: unknown }).content
          : rawContent;
      if (item?.id && contentValue !== undefined) {
        const projected = await projectContent(
          sessionId,
          item.id,
          contentValue,
          item.role ?? "assistant",
          this.deps.blobs
        );
        const mergedContent =
          projected.attachments.length > 0 &&
          rawContent &&
          typeof rawContent === "object" &&
          !Array.isArray(rawContent)
            ? { ...(rawContent as Record<string, unknown>), content: projected.content }
            : rawContent;
        payload = {
          ...payload,
          item: {
            ...item,
            text: typeof item.text === "string" && item.text.length > 0 ? item.text : projected.text,
            attachments: projected.attachments,
            content: mergedContent
          }
        };
      }
      const completed = payload.item as Record<string, unknown> | undefined;
      if (completed && Buffer.byteLength(JSON.stringify(payload)) > LIVE_EVENT_PAYLOAD_BYTES) {
        const text = typeof completed.text === "string" ? completed.text : "";
        const length = Buffer.byteLength(text, "utf8");
        payload = {
          item: {
            id: item?.id,
            historyItemId: completed.historyItemId,
            itemType: completed.itemType,
            kind: completed.kind,
            role: item?.role,
            text: textPreview(text, HISTORY_TEXT_PREVIEW_BYTES),
            toolName: completed.toolName,
            status: completed.status,
            attachments: Array.isArray(completed.attachments) ? completed.attachments.slice(0, 10) : [],
            ...(completed.historyItemId && length > HISTORY_TEXT_PREVIEW_BYTES ? { textByteLength: length } : {})
          }
        };
      }
      if (item?.id) this.removeLiveItem(turnId, { itemId: item.id });
    } else if (event.kind === "tool.completed") {
      this.removeLiveItem(turnId, payload);
      const { historyItemId, ...completion } = payload;
      payload = completion;
      if (Buffer.byteLength(JSON.stringify(payload)) > LIVE_EVENT_PAYLOAD_BYTES) {
        const text = textFromToolResult(payload.result);
        const length = Buffer.byteLength(text, "utf8");
        payload = {
          itemId: payload.itemId,
          status: payload.status,
          result: {
            text: text ? textPreview(text, HISTORY_TEXT_PREVIEW_BYTES) : "Tool result exceeds the live preview limit",
            ...(length > HISTORY_TEXT_PREVIEW_BYTES ? { historyItemId, textByteLength: length } : {})
          }
        };
      }
    }
    if (event.kind === "turn.completed" || event.kind === "turn.failed") {
      const status = event.kind === "turn.completed" ? "completed" : "failed";
      if (!(await this.settleTurn(turnId, status, undefined, true))) return;
      const turn = this.turns.get(turnId);
      payload = {
        turn: turn ? this.publicTurn(turn) : { id: turnId },
        ...(event.kind === "turn.failed" ? { error: payload.error } : {})
      };
    }
    await this.deps.sessionLocks.run(sessionId, () =>
      this.deps.emit("session", event.kind, payload, { sessionId, turnId })
    );
    if ((event.kind === "turn.completed" || event.kind === "turn.failed") && !this.executingDrivers.has(sessionId)) {
      void this.drainQueue(sessionId);
    }
  }

  private async stopTurnOnce(turnId: string, status: "interrupted" | "canceled") {
    const turn = this.getTurn(turnId);
    if (!ACTIVE_TURN_STATUSES.has(turn.status) && turn.status !== "queued") {
      return { turn: this.publicTurn(turn) };
    }
    if (turn.status === "queued") {
      this.removeQueuedStart(turn.sessionId, turnId);
      if (!(await this.settleTurn(turnId, "canceled"))) return { turn: this.publicTurn(turn) };
      await this.deps.sessionLocks.run(turn.sessionId, () =>
        this.deps.emit(
          "session",
          "turn.completed",
          { turn: this.publicTurn(turn) },
          { sessionId: turn.sessionId, turnId }
        )
      );
      return { turn: this.publicTurn(turn) };
    }
    turn.stopRequested = true;
    const handle = turn.handle;
    if (handle) {
      this.settleApprovalsForTurn(turnId);
      await handle.abort();
      this.settleApprovalsForTurn(turnId);
      await handle.wait().catch(() => undefined);
      await (this.turnEventChains.get(turnId) ?? Promise.resolve());
    }
    const queued = this.queuedStarts.get(turn.sessionId);
    if (status === "interrupted" && queued && queued.length > 0) {
      this.queuedStarts.delete(turn.sessionId);
      for (const entry of queued) {
        const queuedTurn = this.turns.get(entry.turnId);
        if (!queuedTurn || !(await this.settleTurn(entry.turnId, "canceled"))) continue;
        await this.deps.sessionLocks.run(turn.sessionId, () =>
          this.deps.emit(
            "session",
            "turn.completed",
            { turn: this.publicTurn(queuedTurn) },
            { sessionId: turn.sessionId, turnId: entry.turnId }
          )
        );
      }
    }
    if (!(await this.settleTurn(turnId, status))) return { turn: this.publicTurn(turn) };
    const eventKind = status === "interrupted" ? "turn.interrupted" : "turn.completed";
    await this.deps.sessionLocks.run(turn.sessionId, () =>
      this.deps.emit("session", eventKind, { turn: this.publicTurn(turn) }, { sessionId: turn.sessionId, turnId })
    );
    void this.drainQueue(turn.sessionId);
    return { turn: this.publicTurn(turn) };
  }
}
