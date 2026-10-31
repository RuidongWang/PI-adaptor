import { mkdir, readdir } from "node:fs/promises";
import { join, resolve } from "node:path";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import type { SessionEntry } from "@earendil-works/pi-coding-agent";
import { AgentDriver, type AgentEvent } from "../agent/driver.js";
import { HostConfig } from "../config.js";
import { HostError } from "../errors.js";
import { EventJournal, type Cursor, type HostEvent } from "../events/journal.js";
import { BlobStore, type AttachmentRecord } from "../media/blob-store.js";
import { MetaStore, type SessionMeta } from "../meta/store.js";
import { NativeSessionCatalog } from "../pi/session-catalog.js";
import { ProviderStore } from "../providers/store.js";
import { SkillRegistry } from "../skills/registry.js";
import { TokenStore, type DeviceRecord } from "../security/tokens.js";
import { sha256, uuid } from "../util/id.js";
import { KeyedMutex } from "../util/keyed-mutex.js";
import { IdempotencyStore, requestDigest } from "./idempotency.js";
import { ACTIVE_TURN_STATUSES, TurnStore, type TurnRecord } from "./turn-store.js";

/**
 * Mutating methods that must be replay-safe. Retries carrying the same
 * `context.idempotencyKey` return the first result instead of executing twice
 * (contract §3.1 idempotency matrix).
 */
const IDEMPOTENT_METHODS = new Set([
  "connection/revoke",
  "connection/confirm-rotation",
  // NOTE: `device/pairing-token` is intentionally NOT idempotent. Its result
  // carries a plaintext pairing token that would otherwise be persisted (and
  // replayed) from `meta/idempotency.json`; it is a one-shot mint instead.
  "project/register",
  "project/update",
  "project/delete",
  "session/create",
  "session/configure",
  "session/rename",
  "session/archive",
  "session/branch",
  "session/delete",
  "turn/start",
  "turn/interrupt",
  "turn/cancel",
  "provider/create",
  "provider/update",
  "provider/delete",
  "skill/install",
  "skill/update",
  "skill/delete",
  "attachment/create",
  "attachment/chunk",
  "attachment/complete"
]);

/** Partial live output for a turn, used to rebuild `snapshot.activeItems`. */
type LiveItem = {
  itemId: string;
  itemType: string;
  kind: string;
  role?: string | undefined;
  text: string;
  toolName?: string | undefined;
  status: string;
};

export type AuthContext = { device: DeviceRecord };
export type EventSink = (event: HostEvent) => void;

type Subscription = {
  id: string;
  scope: "host" | "session";
  sessionId: string | undefined;
  sink?: EventSink;
  buffer: HostEvent[];
};

type TurnState = {
  id: string;
  sessionId: string;
  status: string;
  createdAt: string;
  settledAt: string | null;
  settledReason?: string;
  /** True once a stop was requested, so an abort-induced end is not read as success. */
  stopRequested?: boolean;
  handle?: { abort(): Promise<void>; wait(): Promise<void> };
};

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

function context(params: Record<string, unknown>): {
  requestId: string;
  idempotencyKey: string | undefined;
  expectedRevision: number | undefined;
} {
  const raw = obj(params.context);
  return {
    requestId: str(raw.requestId, "context.requestId"),
    idempotencyKey: typeof raw.idempotencyKey === "string" ? raw.idempotencyKey : undefined,
    expectedRevision: typeof raw.expectedRevision === "number" ? raw.expectedRevision : undefined
  };
}

/** `context.idempotencyKey` if present; the request is a one-shot write otherwise. */
function idempotencyKeyFrom(params: Record<string, unknown>): string | undefined {
  const raw = params.context;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const key = (raw as { idempotencyKey?: unknown }).idempotencyKey;
  return typeof key === "string" && key.length > 0 ? key : undefined;
}

function imageExtension(mimeType: string): string {
  return mimeType === "image/png" ? "png" : mimeType === "image/webp" ? "webp" : "jpg";
}

async function projectContent(
  sessionId: string,
  itemId: string,
  content: unknown,
  role: string,
  blobs: BlobStore
): Promise<{
  text: string;
  attachments: AttachmentRecord[];
  content: unknown;
}> {
  if (typeof content === "string") {
    return { text: content, attachments: [], content };
  }
  if (!Array.isArray(content)) {
    return { text: "", attachments: [], content };
  }
  const attachments: AttachmentRecord[] = [];
  const projected: unknown[] = [];
  for (const [index, part] of content.entries()) {
    const block = part as { type?: string; text?: string; data?: string; mimeType?: string };
    if (
      block.type === "image" &&
      typeof block.data === "string" &&
      typeof block.mimeType === "string"
    ) {
      try {
        const attachment = await blobs.importImageBase64({
          sessionId,
          dataBase64: block.data,
          mimeType: block.mimeType,
          fileName: `${itemId}-${index}.${imageExtension(block.mimeType)}`,
          kind: role === "user" ? "input" : "output"
        });
        attachments.push(attachment);
        projected.push({
          type: "image",
          attachmentId: attachment.id,
          mimeType: attachment.mimeType
        });
      } catch {
        projected.push(block);
      }
    } else {
      projected.push(block);
    }
  }
  return {
    text: projected
      .map((part) => (part as { text?: string }).text)
      .filter((text): text is string => typeof text === "string")
      .join(""),
    attachments,
    content: projected
  };
}

async function itemFromEntry(
  entry: SessionEntry,
  sessionId: string,
  blobs: BlobStore
): Promise<Record<string, unknown> | null> {
  if (entry.type !== "message") return null;
  const message = entry.message as {
    role?: string;
    content?: unknown;
    toolName?: string;
    isError?: boolean;
    timestamp?: number;
  };
  const role = message.role ?? "assistant";
  const projected = await projectContent(sessionId, entry.id, message.content, role, blobs);
  // Pi 把工具结果写成 `role: "toolResult"` 的消息条目（含 `toolName` / `isError`）。
  // 契约 §3.5 的 `tool` 条目才是客户端渲染的工具卡片，所以历史投影必须给出
  // `itemType: "tool"` 与 `toolName`；否则重新 attach 后同一次工具调用会从卡片
  // 退化成一条没有归属的正文消息，卡片正文也就永远看不到。
  const tool = role === "toolResult";
  return {
    id: entry.id,
    itemType: tool ? "tool" : "message",
    kind: tool ? "tool" : "message",
    role,
    text: projected.text,
    status: tool && message.isError ? "failed" : "completed",
    turnId: null,
    toolName: tool ? (message.toolName ?? null) : null,
    attachments: projected.attachments,
    content: { ...message, content: projected.content }
  };
}

export class HostService {
  readonly tokens: TokenStore;
  readonly meta: MetaStore;
  readonly catalog: NativeSessionCatalog;
  readonly journal: EventJournal;
  readonly blobs: BlobStore;
  readonly providers: ProviderStore;
  readonly skills: SkillRegistry;
  hostId: string;

  private readonly subscriptions = new Map<string, Subscription>();
  private readonly turns = new Map<string, TurnState>();
  private readonly sessionFiles = new Map<string, string>();
  private readonly idempotency: IdempotencyStore;
  private readonly turnStore: TurnStore;
  /** Serialises per-session native writes and session-scoped event emission. */
  private readonly sessionLocks = new KeyedMutex();
  /** Serialises per-turn driver event processing in strict FIFO order. */
  private readonly turnEventChains = new Map<string, Promise<void>>();
  /** turnId → (itemId → partial output) for the in-flight turn's active items. */
  private readonly liveItems = new Map<string, Map<string, LiveItem>>();
  /** sessionId → queued turn starts awaiting the running turn (contract §8.1). */
  private readonly queuedStarts = new Map<string, Array<{ turnId: string; run: () => Promise<void> }>>();
  private maintenanceTimer: NodeJS.Timeout | undefined;
  private readonly pendingApprovals = new Map<
    string,
    {
      sessionId: string;
      turnId: string;
      toolName: string;
      input: unknown;
      revision: number;
      resolve: (allowed: boolean) => void;
    }
  >();
  private readonly allowedSessionTools = new Map<string, Set<string>>();
  private approvalRevision = 0;

  constructor(
    readonly config: HostConfig,
    private readonly driver: AgentDriver
  ) {
    this.tokens = new TokenStore(config.dataDir);
    this.meta = new MetaStore(config.dataDir);
    this.catalog = new NativeSessionCatalog(config.sessionRoots);
    this.journal = new EventJournal(config.dataDir);
    this.blobs = new BlobStore(config.dataDir);
    this.providers = new ProviderStore(config.dataDir, config.dataDir.includes("test"));
    this.skills = new SkillRegistry(config.dataDir, join(config.agentDir, ".."), config.dataDir.includes("test"));
    this.idempotency = new IdempotencyStore(config.dataDir);
    this.turnStore = new TurnStore(config.dataDir);
    this.hostId = config.hostId || uuid();
  }

  async init(): Promise<void> {
    await this.blobs.init();
    await this.journal.load();
    const hostPath = join(this.config.dataDir, "meta", "host.json");
    const stored = await readJsonFile<{ version: 1; hostId: string } | null>(hostPath, null);
    if (stored?.version === 1 && stored.hostId) this.hostId = stored.hostId;
    else await writeJsonFileAtomic(hostPath, { version: 1, hostId: this.hostId }, 0o600);
    // A rotation issued but never confirmed is void across a restart; the old
    // token stays valid (contract §2.4).
    await this.tokens.recoverUnconfirmedRotations();
    // Reconcile turns that were active when the previous process exited. The
    // live execution is gone and cannot be proven stopped, so they become
    // `uncertain` and are never auto-resumed (contract §9).
    const reconciled = await this.turnStore.reconcileAfterRestart();
    for (const record of reconciled) {
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

  /** Start periodic media GC. Call from the process entrypoint after `init()`. */
  startMaintenance(intervalMs = 60 * 60 * 1000): void {
    if (this.maintenanceTimer) return;
    void this.runMaintenance().catch(() => undefined);
    this.maintenanceTimer = setInterval(() => {
      void this.runMaintenance().catch(() => undefined);
    }, intervalMs);
    this.maintenanceTimer.unref?.();
  }

  stopMaintenance(): void {
    if (this.maintenanceTimer) clearInterval(this.maintenanceTimer);
    this.maintenanceTimer = undefined;
  }

  /**
   * Collect attachment ids and image content hashes that committed messages still
   * reference by walking each live session's native history, then drop unreferenced blobs.
   * If any session's history cannot be read, maintenance is aborted to prevent accidental GC.
   */
  async runMaintenance(now = new Date()): Promise<number> {
    try {
      const { ids, hashes } = await this.collectReferencedAttachments();
      return await this.blobs.gc(ids, hashes, now);
    } catch (error) {
      console.warn("maintenance run aborted due to history read failure:", error);
      return 0;
    }
  }

  private async collectReferencedAttachments(): Promise<{ ids: Set<string>; hashes: Set<string> }> {
    const ids = new Set<string>();
    const hashes = new Set<string>();
    for (const session of await this.meta.listSessions(true)) {
      if (!session.nativePath) continue;
      const entries = await this.catalog.history(session.nativePath);
      for (const entry of entries) {
        if (entry.type !== "message") continue;
        const content = (entry.message as { content?: unknown }).content;
        if (!Array.isArray(content)) continue;
        for (const part of content) {
          const block = part as { attachmentId?: unknown; type?: unknown; data?: unknown };
          if (typeof block.attachmentId === "string") ids.add(block.attachmentId);
          if (block.type === "image" && typeof block.data === "string") {
            hashes.add(sha256(Buffer.from(block.data, "base64")));
          }
        }
      }
    }
    return { ids, hashes };
  }

  async initialize(params: Record<string, unknown>) {
    if (params.protocolVersion === "1.0") {
      return {
        protocolVersion: "1.0",
        server: {
          name: "pi-adaptor",
          version: this.config.hostVersion,
          hostId: this.hostId,
          piVersion: this.config.piVersion
        },
        connectionId: uuid(),
        principal: { subject: "paired-device", roles: ["owner"] },
        policy: {
          remoteMaxPermissionMode: "auto",
          applyCeilingToPairedDevices: false
        },
        capabilities: {
          attachments: true,
          imageOutput: true,
          skills: true,
          providers: true,
          sessionBranches: true,
          sessionDelete: true,
          nativePiSessions: true
        }
      };
    }
    return {
      protocolVersion: "2.0.0",
      server: {
        name: "pi-adaptor",
        version: this.config.hostVersion,
        hostId: this.hostId,
        piVersion: this.config.piVersion
      },
      connectionId: uuid(),
      roles: ["owner"],
      policy: {
        defaultPermissionMode: "ask",
        allowedPermissionModes: ["ask", "auto"],
        maxImageBytes: 20 * 1024 * 1024,
        maxImagesPerMessage: 10,
        approvalDisconnectSeconds: 86400
      },
      capabilities: {
        attachments: true,
        imageOutput: true,
        skills: true,
        providers: true,
        sessionBranches: true,
        sessionDelete: true,
        nativePiSessions: true
      }
    };
  }

  async pair(params: Record<string, unknown>, token: string) {
    const label = typeof params.deviceLabel === "string" ? params.deviceLabel : "device";
    const paired = await this.tokens.pair(token, label);
    return { ...paired, hostId: this.hostId, roles: ["owner"] };
  }

  async createPairingToken(ttlSeconds = 600) {
    return this.tokens.createPairingToken(ttlSeconds);
  }

  async handle(method: string, rawParams: unknown, auth: AuthContext | null, pairingToken?: string): Promise<unknown> {
    const params = rawParams === undefined ? {} : obj(rawParams);
    if (method === "connection/initialize") return this.initialize(params);
    if (method === "connection/pair") {
      if (!pairingToken) throw new HostError("UNAUTHORIZED", "pairing token is required");
      return this.pair(params, pairingToken);
    }
    if (!auth) throw new HostError("UNAUTHORIZED", "device authentication is required");
    if (IDEMPOTENT_METHODS.has(method)) {
      const key = idempotencyKeyFrom(params);
      if (key) {
        return this.idempotency.run(
          key,
          method,
          requestDigest(params),
          () => this.dispatch(method, params, auth, pairingToken),
          auth.device.deviceId
        );
      }
    }
    return this.dispatch(method, params, auth, pairingToken);
  }

  private async dispatch(
    method: string,
    params: Record<string, unknown>,
    auth: AuthContext,
    pairingToken?: string
  ): Promise<unknown> {
    switch (method) {
      case "connection/ping":
        return { pong: true };
      case "device/list":
        return { devices: await this.tokens.listDevices() };
      case "device/pairing-token":
        return this.createPairingToken(typeof params.ttlSeconds === "number" ? params.ttlSeconds : 600);
      case "connection/rotate-token":
        return this.tokens.rotate(auth.device.deviceId, idempotencyKeyFrom(params));
      case "connection/confirm-rotation":
        return {
          confirmed: await this.tokens.confirmRotation(
            auth.device.deviceId,
            str(params.rotationId, "rotationId")
          )
        };
      case "connection/revoke":
        return { revoked: await this.tokens.revoke(str(params.deviceId, "deviceId")) };
      case "project/list":
        return { projects: await this.meta.listProjects(true) };
      case "project/browse":
        return this.browseProject(typeof params.path === "string" ? params.path : undefined);
      case "project/register": {
        const path = resolve(str(params.path, "path"));
        const label = typeof params.label === "string" ? params.label : path.split("/").pop() ?? path;
        return { project: await this.meta.registerProject(path, label) };
      }
      case "project/update": {
        const changes: { label?: string; archived?: boolean } = {};
        if (typeof params.label === "string") changes.label = params.label;
        if (typeof params.archived === "boolean") changes.archived = params.archived;
        return { project: await this.meta.updateProject(str(params.projectId, "projectId"), changes) };
      }
      case "project/delete": {
        const projectId = str(params.projectId, "projectId");
        if (str(params.confirmProjectId, "confirmProjectId") !== projectId) {
          throw new HostError("INVALID_ARGUMENT", "project confirmation does not match");
        }
        // Contract §5.5: a project with an active session cannot be deleted.
        if ([...this.turns.values()].some((turn) => ACTIVE_TURN_STATUSES.has(turn.status))) {
          throw new HostError("SESSION_BUSY", "a session is running");
        }
        return { deleted: true, projectId: (await this.meta.deleteProject(projectId)).id };
      }
      case "session/list":
        return this.listSessions(typeof params.includeArchived === "boolean" ? params.includeArchived : true);
      case "session/search":
        return this.searchSessions(str(params.query, "query"), typeof params.limit === "number" ? params.limit : 50);
      case "session/get":
        return { session: this.summarize(await this.requireSession(str(params.sessionId, "sessionId"))) };
      case "session/create":
        return { session: this.summarize(await this.createSession(params)) };
      case "session/attach":
        return this.attachSession(str(params.sessionId, "sessionId"));
      case "session/history":
        return this.history(str(params.sessionId, "sessionId"), params);
      case "session/configure":
        return { session: this.summarize(await this.configureSession(params)) };
      case "session/rename":
        return { session: this.summarize(await this.renameSession(params)) };
      case "session/archive":
        return { session: this.summarize(await this.archiveSession(params)) };
      case "session/branch":
        return { session: this.summarize(await this.branchSession(params)) };
      case "session/delete":
        return this.deleteSession(params);
      case "events/subscribe":
        return this.subscribe(params, auth);
      case "events/unsubscribe":
        this.subscriptions.delete(str(params.subscriptionId, "subscriptionId"));
        return { unsubscribed: true };
      case "events/ack":
        return { acknowledged: true };
      case "turn/start":
        return this.startTurn(params);
      case "turn/get":
        return { turn: this.getTurn(str(params.turnId, "turnId")) };
      case "turn/interrupt":
        return this.stopTurn(str(params.turnId, "turnId"), "interrupted");
      case "turn/cancel":
        return this.stopTurn(str(params.turnId, "turnId"), "canceled");
      case "approval/respond":
        return this.respondApproval(params, auth);
      case "input/respond":
        return { resolved: true, alreadyResolved: false };
      case "provider/list":
        return { providers: await this.providers.list(), revision: 1 };
      case "provider/create":
        return { provider: await this.providers.create(obj(params.provider) as never) };
      case "provider/update":
        return {
          provider: await this.providers.update(str(params.providerId, "providerId"), obj(params.provider) as never)
        };
      case "provider/delete": {
        const providerId = str(params.providerId, "providerId");
        if (str(params.confirmProviderId, "confirmProviderId") !== providerId) {
          throw new HostError("INVALID_ARGUMENT", "provider confirmation does not match");
        }
        return { deleted: await this.providers.delete(providerId) };
      }
      case "provider/test":
        return { ok: (await this.providers.secret(str(params.providerId, "providerId"))) !== null, checkedAt: new Date().toISOString() };
      case "provider/discover":
        return { models: [] };
      case "skill/list":
        return { skills: await this.skills.list() };
      case "skill/get":
        return this.skills.get(str(params.skillId, "skillId"));
      case "skill/install":
        return { skill: await this.skills.install(obj(params.source) as never, params.replace === true) };
      case "skill/update":
        return { skill: await this.skills.update(str(params.skillId, "skillId"), obj(params.source) as never) };
      case "skill/delete": {
        const skillId = str(params.skillId, "skillId");
        if (str(params.confirmSkillId, "confirmSkillId") !== skillId) {
          throw new HostError("INVALID_ARGUMENT", "skill confirmation does not match");
        }
        return { deleted: await this.skills.delete(skillId) };
      }
      case "attachment/create":
        return this.createAttachment(params);
      case "attachment/chunk":
        return {
          receivedBytes: await this.blobs.appendChunk(
            str(params.attachmentId, "attachmentId"),
            typeof params.offset === "number" ? params.offset : 0,
            str(params.dataBase64, "dataBase64")
          )
        };
      case "attachment/complete":
        return {
          attachment: await this.blobs.complete(
            str(params.attachmentId, "attachmentId"),
            str(params.sha256, "sha256")
          )
        };
      case "attachment/read":
        return this.blobs.read(
          str(params.attachmentId, "attachmentId"),
          typeof params.offset === "number" ? params.offset : 0,
          typeof params.length === "number" ? params.length : 262144
        );
      default:
        throw new HostError("INVALID_ARGUMENT", `unknown method: ${method}`);
    }
  }

  private async browseProject(path?: string) {
    const target = resolve(path ?? process.env.HOME ?? "/");
    const entries = await readdir(target, { withFileTypes: true });
    return {
      path: target,
      entries: entries.map((entry) => ({
        name: entry.name,
        path: join(target, entry.name),
        kind: entry.isDirectory() ? "directory" : "file",
        readable: true
      }))
    };
  }

  private async requireSession(sessionId: string): Promise<SessionMeta> {
    const session = await this.meta.getSession(sessionId);
    if (!session || session.deletedAt) throw new HostError("NOT_FOUND", "session not found");
    return session;
  }

  /// 当前运行或排队中的 turn id；契约 §3.4 要求会话摘要带 `activeTurnId`。
  /// 该字段是运行期状态，不在持久化的 SessionMeta 上，故每次序列化时按 `this.turns` 计算。
  private activeTurnIdFor(sessionId: string): string | null {
    for (const turn of this.turns.values()) {
      if (turn.sessionId === sessionId && turn.status !== "queued" && ACTIVE_TURN_STATUSES.has(turn.status)) {
        return turn.id;
      }
    }
    return null;
  }

  /** A session is busy while it has a running turn or anything queued behind it. */
  private sessionBusy(sessionId: string): boolean {
    return this.activeTurnIdFor(sessionId) !== null || (this.queuedStarts.get(sessionId)?.length ?? 0) > 0;
  }

  /// 会话摘要 + 计算字段 `activeTurnId`（契约 §3.4）。
  private summarize(session: SessionMeta): SessionMeta & { activeTurnId: string | null } {
    return { ...session, activeTurnId: this.activeTurnIdFor(session.id) };
  }


  private async listSessions(includeArchived: boolean) {
    const native = await this.catalog.scan();
    const projects = await this.meta.listProjects(true);
    const existing = new Map((await this.meta.listSessions(true)).map((session) => [session.id, session]));
    for (const item of native) {
      const meta =
        existing.get(item.id) ??
        ({
          id: item.id,
          title: item.title,
          projectId: projects.find((project) => project.path === item.cwd)?.id ?? null,
          projectPath: item.cwd,
          mode: "agent",
          permissionMode: "ask",
          providerId: null,
          modelId: null,
          thinkingLevel: null,
          revision: 1,
          archived: false,
          createdAt: item.createdAt,
          updatedAt: item.updatedAt,
          nativePath: item.path,
          readOnlyReason: item.readOnlyReason
        } satisfies SessionMeta);
      await this.meta.upsertSession(meta);
    }
    const sessions = await this.meta.listSessions(includeArchived);
    return {
      sessions: sessions.filter((session) => !session.deletedAt).map((session) => this.summarize(session)),
      revision: 1
    };
  }

  private async searchSessions(query: string, limit: number) {
    const result = await this.listSessions(true);
    const lower = query.toLowerCase();
    return {
      sessions: result.sessions
        .filter((session) => `${session.title} ${session.projectPath}`.toLowerCase().includes(lower))
        .slice(0, Math.max(1, Math.min(limit, 200)))
        .map((session) => this.summarize(session))
    };
  }

  private async createSession(params: Record<string, unknown>): Promise<SessionMeta> {
    const projectId = typeof params.projectId === "string" ? params.projectId : null;
    const project = projectId ? await this.meta.getProject(projectId) : null;
    const id = uuid();
    const now = new Date().toISOString();
    const session: SessionMeta = {
      id,
      title: typeof params.title === "string" && params.title ? params.title : "New session",
      projectId,
      projectPath: project?.path ?? process.cwd(),
      mode: params.mode === "plan" ? "plan" : "agent",
      permissionMode: params.permissionMode === "auto" ? "auto" : "ask",
      providerId: typeof params.providerId === "string" ? params.providerId : null,
      modelId: typeof params.modelId === "string" ? params.modelId : null,
      thinkingLevel: typeof params.thinkingLevel === "string" ? params.thinkingLevel : null,
      revision: 1,
      archived: false,
      createdAt: now,
      updatedAt: now,
      nativePath: null
    };
    await this.meta.upsertSession(session);
    await this.emit("host", "session.created", { session });
    return session;
  }

  private async attachSession(sessionId: string) {
    const session = await this.requireSession(sessionId);
    // Capture the cursor *before* reading history and hold the session lock
    // across both. Any event emitted after the cursor is therefore replayable,
    // so a message that lands mid-snapshot can never be silently lost
    // (contract §3.8 / AC-25). A message read into the snapshot whose event also
    // replays is deduplicated by the client on item id.
    const { cursor, items } = await this.sessionLocks.run(sessionId, async () => {
      const seq = this.journal.currentCursor();
      const history = session.nativePath ? await this.catalog.history(session.nativePath) : [];
      const projected = (
        await Promise.all(history.map((entry) => itemFromEntry(entry, session.id, this.blobs)))
      ).filter((item): item is Record<string, unknown> => item !== null);
      return { cursor: seq, items: projected };
    });
    // A pending tool approval is not part of the native JSONL history, so it has
    // to be replayed from the live turn state. Without this, a client that
    // reattaches while a tool call is waiting for approval sees no card and the
    // turn hangs forever (the model never gets a tool result).
    const pendingApprovals = [...this.pendingApprovals.entries()]
      .filter(([, pending]) => pending.sessionId === sessionId)
      .map(([id, pending]) => ({
        id,
        revision: pending.revision,
        kind: "tool",
        title: pending.toolName,
        toolName: pending.toolName,
        input: pending.input,
        expiresAt: null
      }));
    const summary = this.summarize(session);
    const activeTurn = summary.activeTurnId ? this.turns.get(summary.activeTurnId) ?? null : null;
    const activeItems = activeTurn
      ? [...(this.liveItems.get(activeTurn.id)?.values() ?? [])].map((item) => ({
          id: item.itemId,
          itemType: item.itemType,
          kind: item.kind,
          role: item.role ?? null,
          text: item.text,
          status: item.status,
          turnId: activeTurn.id,
          toolName: item.toolName ?? null
        }))
      : [];
    const queuedTurns = (this.queuedStarts.get(sessionId) ?? [])
      .map((entry) => this.turns.get(entry.turnId))
      .filter((turn): turn is TurnState => turn !== undefined)
      .map((turn) => this.publicTurn(turn));
    return {
      session: summary,
      snapshot: {
        session: summary,
        revision: session.revision,
        cursor,
        items,
        activeItems,
        // 契约 §3.4：会话摘要带 activeTurnId；重连/切后台后客户端据此恢复运行态与中止入口。
        activeTurn: activeTurn
          ? {
              id: activeTurn.id,
              sessionId: activeTurn.sessionId,
              status: activeTurn.status,
              createdAt: activeTurn.createdAt,
              settledAt: activeTurn.settledAt,
              settledReason: activeTurn.settledReason ?? null
            }
          : null,
        queuedTurns,
        pendingApprovals,
        pendingInputs: [],
        hasMoreHistory: false,
        replayComplete: true
      },
      replayComplete: true
    };
  }

  private async history(sessionId: string, params: Record<string, unknown> = {}) {
    const session = await this.requireSession(sessionId);
    let allItems = session.nativePath
      ? (
          await Promise.all(
            (await this.catalog.history(session.nativePath)).map((entry) =>
              itemFromEntry(entry, session.id, this.blobs)
            )
          )
        ).filter((item): item is Record<string, unknown> => item !== null)
      : [];
    const limit = typeof params.limit === "number" ? Math.max(1, Math.min(200, params.limit)) : 100;
    const beforeItemId = typeof params.beforeItemId === "string" ? params.beforeItemId : undefined;
    if (beforeItemId) {
      const idx = allItems.findIndex((item) => item.id === beforeItemId);
      if (idx >= 0) {
        allItems = allItems.slice(0, idx);
      }
    }
    const hasMore = allItems.length > limit;
    const items = hasMore ? allItems.slice(allItems.length - limit) : allItems;
    return { items, hasMore, revision: session.revision };
  }

  private async configureSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const session = await this.requireSession(sessionId);
    const changes: Partial<SessionMeta> = { revision: session.revision + 1 };
    if (params.mode === "agent" || params.mode === "plan") changes.mode = params.mode;
    if (params.permissionMode === "ask" || params.permissionMode === "auto") changes.permissionMode = params.permissionMode;
    if (typeof params.providerId === "string") changes.providerId = params.providerId;
    if (typeof params.modelId === "string") changes.modelId = params.modelId;
    if (typeof params.thinkingLevel === "string") changes.thinkingLevel = params.thinkingLevel;
    const updated = await this.meta.updateSession(sessionId, changes);
    await this.emit("host", "session.changed", { session: updated }, { sessionId });
    return updated;
  }

  private async renameSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const title = str(params.title, "title");
    const session = await this.requireSession(sessionId);
    if (session.nativePath) await this.catalog.appendSessionInfo(session.nativePath, title);
    const updated = await this.meta.updateSession(sessionId, { title, revision: session.revision + 1 });
    await this.emit("host", "session.changed", { session: updated }, { sessionId });
    return updated;
  }

  private async archiveSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const session = await this.requireSession(sessionId);
    const updated = await this.meta.updateSession(sessionId, {
      archived: params.archived === true,
      revision: session.revision + 1
    });
    await this.emit("host", "session.changed", { session: updated }, { sessionId });
    return updated;
  }

  private async branchSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const session = await this.requireSession(sessionId);
    if (!session.nativePath) throw new HostError("NOT_FOUND", "session has no native file");
    const childPath = await this.catalog.branch(session.nativePath, str(params.fromItemId, "fromItemId"));
    const child = await this.catalog.scan().then((items) => items.find((item) => item.path === childPath));
    if (!child) throw new HostError("INTERNAL", "branch was not discoverable");
    return this.meta.upsertSession({
      ...session,
      id: child.id,
      title: typeof params.title === "string" ? params.title : `${session.title} branch`,
      nativePath: child.path,
      revision: 1,
      createdAt: child.createdAt,
      updatedAt: child.updatedAt,
      archived: false
    });
  }

  private async deleteSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    if (str(params.confirmSessionId, "confirmSessionId") !== sessionId) {
      throw new HostError("INVALID_ARGUMENT", "session confirmation does not match");
    }
    const session = await this.requireSession(sessionId);
    if (this.sessionBusy(sessionId)) {
      throw new HostError("SESSION_BUSY", "session is running or has queued turns");
    }
    this.queuedStarts.delete(sessionId);
    // Delete side effects in retry-safe order: media and the native file are
    // removed while the session still exists, so a failure leaves a session that
    // the same delete request can retry — instead of a tombstone whose media
    // can never be cleaned up again.
    await this.blobs.deleteSession(sessionId);
    if (session.nativePath) {
      const { rm } = await import("node:fs/promises");
      await rm(session.nativePath, { force: true });
    }
    await this.meta.deleteSession(sessionId);
    await this.emit("host", "session.deleted", { sessionId }, { sessionId });
    return { deleted: true, sessionId };
  }

  private subscribe(params: Record<string, unknown>, _auth: AuthContext) {
    const scope = params.scope === "host" ? "host" : "session";
    const sessionId = typeof params.sessionId === "string" ? params.sessionId : undefined;
    const after = params.after as Cursor | undefined;
    // Take the resume point before replaying so the replay is contiguous with
    // `starting`: the client continues from `starting` with nothing in between.
    const starting = this.journal.currentCursor();
    const replay = after ? this.journal.replay(scope, sessionId, after) : [];
    const id = uuid();
    this.subscriptions.set(id, {
      id,
      scope,
      sessionId,
      buffer: []
    });
    return { subscriptionId: id, starting, replayComplete: true, replay };
  }

  setSubscriptionSink(id: string, sink: EventSink): void {
    const subscription = this.subscriptions.get(id);
    if (!subscription) return;
    subscription.sink = sink;
    const pending = subscription.buffer.splice(0);
    for (const event of pending) {
      sink(event);
    }
  }

  removeSubscription(id: string): void {
    this.subscriptions.delete(id);
  }

  private async emit(
    scope: "host" | "session",
    kind: string,
    payload: Record<string, unknown>,
    extra: Partial<HostEvent> = {}
  ): Promise<HostEvent> {
    const event = await this.journal.append(scope, kind, payload, extra);
    for (const subscription of this.subscriptions.values()) {
      if (subscription.scope !== scope) continue;
      if (scope === "session" && subscription.sessionId !== extra.sessionId) continue;
      if (subscription.sink) {
        subscription.sink(event);
      } else {
        subscription.buffer.push(event);
      }
    }
    return event;
  }

  private async startTurn(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const input = obj(params.input);
    const text = typeof input.text === "string" ? input.text : "";
    const attachments = Array.isArray(input.attachments) ? input.attachments.filter((value): value is string => typeof value === "string") : [];
    if (!text && attachments.length === 0) throw new HostError("INVALID_ARGUMENT", "message is empty");
    if (attachments.length > 10) throw new HostError("ATTACHMENT_INVALID", "too many images");
    const admission = params.admission === "queue" ? "queue" : "reject_if_busy";
    const session = await this.requireSession(sessionId);
    if (session.readOnlyReason) throw new HostError("SESSION_READ_ONLY", session.readOnlyReason);
    // Single in-process writer actor per session (contract §6.2): serialize
    // admission, reservation, and queue insertion under the session mutex.
    const plan = await this.sessionLocks.run(sessionId, async () => {
      if (this.sessionBusy(sessionId)) {
        if (admission === "reject_if_busy") {
          throw new HostError("SESSION_BUSY", "session already has a running or queued turn");
        }
        const queuedId = uuid();
        const queued: TurnState = {
          id: queuedId,
          sessionId,
          status: "queued",
          createdAt: new Date().toISOString(),
          settledAt: null
        };
        this.turns.set(queuedId, queued);
        const queue = this.queuedStarts.get(sessionId) ?? [];
        queue.push({
          turnId: queuedId,
          run: async () => {
            const fresh = await this.requireSession(sessionId);
            if (fresh.readOnlyReason) return;
            await this.launchTurn(fresh, queuedId, text, attachments);
          }
        });
        this.queuedStarts.set(sessionId, queue);
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
      return { kind: "running" as const, turnId };
    });

    if (plan.kind === "queued") {
      await this.turnStore.upsert(this.toRecord(plan.turn));
      return { turn: plan.turn };
    }

    try {
      const turn = await this.launchTurn(session, plan.turnId, text, attachments);
      return { turn };
    } catch (error) {
      this.turns.delete(plan.turnId);
      void this.drainQueue(sessionId);
      throw error;
    }
  }

  private async launchTurn(
    session: SessionMeta,
    turnId: string,
    text: string,
    attachmentIds: string[]
  ): Promise<TurnState> {
    if (!session.nativePath) {
      const sessionDir = join(this.config.dataDir, "sessions");
      session.nativePath = await this.sessionLocks.run(session.id, () =>
        this.catalog.createFile(session.projectPath, sessionDir, session.id)
      );
      await this.meta.updateSession(session.id, { nativePath: session.nativePath });
    }
    const provider = session.providerId ? (await this.providers.list()).find((entry) => entry.id === session.providerId) : undefined;
    const providerSecret = provider ? await this.providers.secret(provider.id) : null;
    const images = [];
    for (const id of attachmentIds) {
      const read = await this.blobs.read(id, 0, 20 * 1024 * 1024);
      if (read.attachment.sessionId !== session.id || read.attachment.state !== "ready") {
        throw new HostError("ATTACHMENT_INVALID", "attachment does not belong to session");
      }
      images.push({ type: "image", data: read.dataBase64, mimeType: read.attachment.mimeType });
    }
    if (!this.driver.appendsPrompt && text) {
      const nativePath = session.nativePath;
      await this.sessionLocks.run(session.id, () => this.catalog.appendUserMessage(nativePath, text));
    }
    const handle = this.driver.start({
      turnId,
      sessionId: session.id,
      cwd: session.projectPath,
      sessionDir: join(this.config.dataDir, "sessions"),
      sessionFile: session.nativePath,
      provider: provider
        ? {
            id: provider.id,
            name: provider.name,
            baseUrl: provider.baseUrl,
            apiKey: providerSecret,
            authKind: provider.authKind,
            models: provider.models
          }
        : undefined,
      modelId: session.modelId ?? undefined,
      thinkingLevel: session.thinkingLevel ?? undefined,
      text,
      images: images as never,
      requestApproval: async (toolName: string, toolInput: unknown) => {
        const currentSession = await this.requireSession(session.id);
        if (currentSession.permissionMode === "auto") return true;
        return this.requestApproval(currentSession, turnId, toolName, toolInput);
      },
      onEvent: (event) => {
        const prev = this.turnEventChains.get(turnId) ?? Promise.resolve();
        const next = prev.then(async () => {
          await this.handleAgentEvent(session.id, turnId, event);
        }).catch((err) => {
          console.error("handleAgentEvent error:", err);
        });
        this.turnEventChains.set(turnId, next);
      }
    });
    const turn: TurnState = {
      id: handle.turnId,
      sessionId: session.id,
      status: "running",
      createdAt: new Date().toISOString(),
      settledAt: null,
      handle
    };
    this.turns.set(handle.turnId, turn);
    await this.turnStore.upsert(this.toRecord(turn));
    void handle.wait().then(async () => {
      await (this.turnEventChains.get(turn.id) ?? Promise.resolve());
      this.turnEventChains.delete(turn.id);
      const current = this.turns.get(turn.id);
      // A stop request drives the terminal state itself; only an unrequested end
      // is treated as a normal completion.
      if (current && ACTIVE_TURN_STATUSES.has(current.status) && !current.stopRequested) {
        await this.settleTurn(turn.id, "completed");
      }
    });
    return turn;
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

  /**
   * Move a turn to a terminal state exactly once, persist it, drop its live
   * output, settle its approvals, and let the queue advance. A turn that is
   * already terminal keeps its first terminal status.
   */
  private async settleTurn(turnId: string, status: string, settledReason?: string): Promise<void> {
    const turn = this.turns.get(turnId);
    if (!turn) return;
    if (!ACTIVE_TURN_STATUSES.has(turn.status)) return;
    turn.status = status;
    turn.settledAt = new Date().toISOString();
    if (settledReason) turn.settledReason = settledReason;
    this.liveItems.delete(turnId);
    this.settleApprovalsForTurn(turnId);
    await this.turnStore.upsert(this.toRecord(turn));
  }

  /** Contract-shaped turn view without the in-process handle. */
  private publicTurn(turn: TurnState): Record<string, unknown> {
    return {
      id: turn.id,
      sessionId: turn.sessionId,
      status: turn.status,
      createdAt: turn.createdAt,
      settledAt: turn.settledAt,
      ...(turn.settledReason ? { settledReason: turn.settledReason } : {})
    };
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

  private async drainQueue(sessionId: string): Promise<void> {
    const next = await this.sessionLocks.run(sessionId, async () => {
      if (this.activeTurnIdFor(sessionId)) return undefined;
      const queue = this.queuedStarts.get(sessionId);
      if (!queue || queue.length === 0) return undefined;
      const item = queue.shift()!;
      if (queue.length === 0) this.queuedStarts.delete(sessionId);
      return item;
    });
    if (!next) return;
    try {
      await next.run();
    } catch {
      const queued = this.turns.get(next.turnId);
      if (queued && ACTIVE_TURN_STATUSES.has(queued.status)) {
        await this.settleTurn(next.turnId, "failed", "queue_start_failed");
      }
      void this.drainQueue(sessionId);
    }
  }

  private async requestApproval(
    session: SessionMeta,
    turnId: string,
    toolName: string,
    input: unknown
  ): Promise<boolean> {
    if (this.allowedSessionTools.get(session.id)?.has(toolName)) return true;
    const approvalId = uuid();
    const revision = ++this.approvalRevision;
    const approval = {
      id: approvalId,
      revision,
      kind: "tool",
      title: toolName,
      toolName,
      input,
      expiresAt: null
    };
    return new Promise<boolean>((resolve) => {
      const timer = setTimeout(() => {
        this.pendingApprovals.delete(approvalId);
        resolve(false);
      }, 24 * 60 * 60 * 1000);
      this.pendingApprovals.set(approvalId, {
        sessionId: session.id,
        turnId,
        toolName,
        input,
        revision,
        resolve: (allowed) => {
          clearTimeout(timer);
          resolve(allowed);
        }
      });
      this.emit(
        "session",
        "approval.requested",
        { approval },
        { sessionId: session.id, turnId, revision }
      ).catch(() => {
        clearTimeout(timer);
        this.pendingApprovals.delete(approvalId);
        resolve(false);
      });
    });
  }

  private async respondApproval(params: Record<string, unknown>, auth: AuthContext) {
    const approvalId = str(params.approvalId, "approvalId");
    const pending = this.pendingApprovals.get(approvalId);
    if (!pending) return { resolved: true, alreadyResolved: true, effectivePermissionMode: "ask" };
    if (auth.device.role !== "owner") throw new HostError("FORBIDDEN", "approval requires owner");
    const expectedRevision = typeof params.expectedRevision === "number"
      ? params.expectedRevision
      : typeof (params.context as { expectedRevision?: unknown } | undefined)?.expectedRevision === "number"
      ? (params.context as { expectedRevision: number }).expectedRevision
      : undefined;
    if (expectedRevision !== undefined && expectedRevision !== pending.revision) {
      throw new HostError("APPROVAL_STALE", "approval revision does not match");
    }
    const decision = str(params.decision, "decision");
    const allowed = decision === "allow-once" || decision === "allow-session" || decision === "approve";
    if (decision === "allow-session") {
      const tools = this.allowedSessionTools.get(pending.sessionId) ?? new Set<string>();
      tools.add(pending.toolName);
      this.allowedSessionTools.set(pending.sessionId, tools);
    }
    this.pendingApprovals.delete(approvalId);
    pending.resolve(allowed);
    await this.emit(
      "session",
      "approval.resolved",
      { approvalId, status: allowed ? "allowed" : "denied" },
      { sessionId: pending.sessionId, turnId: pending.turnId, revision: pending.revision }
    );
    return { resolved: true, alreadyResolved: false, effectivePermissionMode: "ask" };
  }

  /**
   * Drop every pending approval owned by `turnId` and settle its promise as
   * denied. Called when the turn settles (completed/failed) or is stopped, so a
   * tool result can never be awaited by a turn that is already gone.
   */
  private settleApprovalsForTurn(turnId: string): void {
    for (const [approvalId, pending] of [...this.pendingApprovals.entries()]) {
      if (pending.turnId !== turnId) continue;
      this.pendingApprovals.delete(approvalId);
      pending.resolve(false);
      // 客户端只按 `approval.resolved` 收敛卡片。turn 结束时静默丢弃待审批项，会让
      // 「权限请求」卡片永久留在会话里（用户点它必定失败，而工具早已不在等它）。
      this.emit(
        "session",
        "approval.resolved",
        { approvalId, status: "denied" },
        { sessionId: pending.sessionId, turnId: pending.turnId, revision: pending.revision }
      );
    }
  }

  private async handleAgentEvent(sessionId: string, turnId: string, event: AgentEvent) {
    // A user-requested stop aborts the execution, which surfaces here as
    // turn.failed. That is not a real failure: `stopTurn` owns the terminal state
    // and emits turn.interrupted, so swallow the abort-induced failure entirely.
    if (event.kind === "turn.failed" && this.turns.get(turnId)?.stopRequested) {
      return;
    }
    let payload = event.payload;
    if (event.kind === "item.delta") {
      this.trackLiveItem(turnId, payload);
    } else if (event.kind === "tool.started" || event.kind === "tool.updated") {
      this.trackLiveItem(turnId, payload, true);
    } else if (event.kind === "item.completed") {
      const item = payload.item as
        | { id?: string; role?: string; text?: unknown; content?: unknown }
        | undefined;
      const rawContent = item?.content;
      // Live `item.completed` frames wrap the whole Pi message in `content`,
      // while the history projection passes the raw content value directly.
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
          this.blobs
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
            text:
              typeof item.text === "string" && item.text.length > 0
                ? item.text
                : projected.text,
            attachments: projected.attachments,
            content: mergedContent
          }
        };
      }
      if (item?.id) this.removeLiveItem(turnId, { itemId: item.id });
    } else if (event.kind === "tool.completed") {
      this.removeLiveItem(turnId, payload);
    }
    if (event.kind === "turn.completed" || event.kind === "turn.failed") {
      // Settle before serialising so the payload carries the terminal status, and
      // drop any approval the turn was waiting on (contract §8.2).
      await this.settleTurn(turnId, event.kind === "turn.completed" ? "completed" : "failed");
      const turn = this.turns.get(turnId);
      payload = {
        turn: turn ? this.publicTurn(turn) : { id: turnId },
        ...(event.kind === "turn.failed" ? { error: payload.error } : {})
      };
    }
    // Emit under the session lock so a concurrent snapshot capture observes a
    // single, ordered state point (contract §6.2 step 6).
    await this.sessionLocks.run(sessionId, () =>
      this.emit("session", event.kind, payload, { sessionId, turnId })
    );
    if (event.kind === "turn.completed" || event.kind === "turn.failed") {
      void this.drainQueue(sessionId);
    }
  }

  private getTurn(turnId: string) {
    const turn = this.turns.get(turnId);
    if (!turn) throw new HostError("NOT_FOUND", "turn not found");
    return turn;
  }

  private async stopTurn(turnId: string, status: "interrupted" | "canceled") {
    const turn = this.getTurn(turnId);
    // Repeating an interrupt on an already-terminal turn returns the same
    // terminal state without a second execution or event (contract §8.2).
    if (!ACTIVE_TURN_STATUSES.has(turn.status) && turn.status !== "queued") {
      return { turn: this.publicTurn(turn) };
    }
    if (turn.status === "queued") {
      const queue = this.queuedStarts.get(turn.sessionId);
      if (queue) {
        const filtered = queue.filter((entry) => entry.turnId !== turnId);
        if (filtered.length === 0) {
          this.queuedStarts.delete(turn.sessionId);
        } else {
          this.queuedStarts.set(turn.sessionId, filtered);
        }
      }
      await this.settleTurn(turnId, "canceled");
      await this.sessionLocks.run(turn.sessionId, () =>
        this.emit(
          "session",
          "turn.completed",
          { turn: this.publicTurn(turn) },
          { sessionId: turn.sessionId, turnId }
        )
      );
      return { turn: this.publicTurn(turn) };
    }
    turn.stopRequested = true;
    if (turn.handle) {
      await turn.handle.abort();
      // Release any tool approval the execution is blocked on, otherwise its
      // `wait` never settles (deadlock). Then wait for it to actually stop; the
      // driver resolves `wait` once its terminal event has been routed.
      this.settleApprovalsForTurn(turnId);
      await turn.handle.wait().catch(() => undefined);
    }
    // Stopping a running turn also cancels anything queued behind it — those turns never
    // start, so they must be settled explicitly (and reported) rather than left
    // parked in `queued` forever.
    const queued = this.queuedStarts.get(turn.sessionId);
    if (queued && queued.length > 0) {
      this.queuedStarts.delete(turn.sessionId);
      for (const entry of queued) {
        const queuedTurn = this.turns.get(entry.turnId);
        if (!queuedTurn || !ACTIVE_TURN_STATUSES.has(queuedTurn.status)) continue;
        await this.settleTurn(entry.turnId, "canceled");
        await this.sessionLocks.run(turn.sessionId, () =>
          this.emit(
            "session",
            "turn.completed",
            { turn: this.publicTurn(queuedTurn) },
            { sessionId: turn.sessionId, turnId: entry.turnId }
          )
        );
      }
    }
    const settled = this.turns.get(turnId);
    if (!settled) throw new HostError("NOT_FOUND", "turn not found");
    if (ACTIVE_TURN_STATUSES.has(settled.status)) {
      await this.settleTurn(turnId, status);
    }
    // The frozen event list has no `turn.canceled`; cancel reuses turn.completed,
    // matching the pre-existing behaviour, while the turn status stays `canceled`.
    const eventKind = status === "interrupted" ? "turn.interrupted" : "turn.completed";
    await this.sessionLocks.run(turn.sessionId, () =>
      this.emit("session", eventKind, { turn: this.publicTurn(settled) }, { sessionId: turn.sessionId, turnId })
    );
    void this.drainQueue(turn.sessionId);
    return { turn: this.publicTurn(settled) };
  }

  private async createAttachment(params: Record<string, unknown>) {
    const session = await this.requireSession(str(params.sessionId, "sessionId"));
    const record = await this.blobs.create({
      sessionId: session.id,
      fileName: str(params.fileName, "fileName"),
      mimeType: str(params.mimeType, "mimeType"),
      byteLength: typeof params.byteLength === "number" ? params.byteLength : 0,
      sha256: str(params.sha256, "sha256")
    });
    return {
      attachmentId: record.id,
      chunkSize: 512 * 1024,
      expiresAt: record.expiresAt
    };
  }
}
