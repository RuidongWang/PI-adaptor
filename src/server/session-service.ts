import { constants } from "node:fs";
import { access, readdir, stat } from "node:fs/promises";
import { join, resolve } from "node:path";
import { HostError } from "../errors.js";
import type { EventJournal, HostEvent } from "../events/journal.js";
import type { ExtensionSnapshotStore } from "../extensions/snapshot-store.js";
import type { BlobStore } from "../media/blob-store.js";
import type { MetaStore, SessionMeta } from "../meta/store.js";
import type { NativeSessionCatalog } from "../pi/session-catalog.js";
import { providerApi } from "../providers/protocol.js";
import { createProviderRuntime, publicAssistantMessage } from "../providers/runtime.js";
import type { ProviderStore } from "../providers/store.js";
import { sha256, uuid } from "../util/id.js";
import type { KeyedMutex } from "../util/keyed-mutex.js";
import {
  HISTORY_PAGE_MAX_ITEMS,
  HISTORY_TEXT_CHUNK_BYTES,
  SNAPSHOT_HISTORY_LIMIT,
  historyPage
} from "./history-projector.js";
import { IdempotencyStore, requestDigest } from "./idempotency.js";
import { transientApiKey, type TurnCoordinator } from "./turn-coordinator.js";

/** 标题只保留一行：去引号/句末标点，压缩空白，限长。 */
export function sanitizeSessionTitle(raw: string | undefined): string | undefined {
  if (!raw) return undefined;
  const cleaned = raw
    .replace(/\s+/g, " ")
    .replace(/^["'“”‘’。.，,：:；;\s]+/, "")
    .replace(/["'“”‘’。.，,：:；;\s]+$/, "")
    .trim();
  if (!cleaned) return undefined;
  return cleaned.length <= 40 ? cleaned : `${cleaned.slice(0, 40)}…`;
}

export function fallbackSessionTitle(instruction: string): string {
  const firstLine = instruction.split(/\r?\n/)[0] ?? instruction;
  const collapsed = firstLine.replace(/\s+/g, " ").trim();
  if (!collapsed) return "New session";
  return collapsed.length <= 24 ? collapsed : `${collapsed.slice(0, 24)}…`;
}

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

export type SessionServiceDeps = {
  meta: MetaStore;
  catalog: NativeSessionCatalog;
  journal: EventJournal;
  blobs: BlobStore;
  providers: ProviderStore;
  idempotency: IdempotencyStore;
  extensionSnapshots: ExtensionSnapshotStore;
  sessionLocks: KeyedMutex;
  turns: TurnCoordinator;
  emit: (scope: "host" | "session", kind: string, payload: Record<string, unknown>, extra?: Partial<HostEvent>) => Promise<HostEvent>;
};

export class SessionService {
  constructor(private readonly deps: SessionServiceDeps) {}

  async browseProject(path?: string) {
    const target = await this.projectDirectory(path ?? process.env.HOME ?? "/");
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

  async projectDirectory(path: string): Promise<string> {
    const target = resolve(path);
    try {
      if (!(await stat(target)).isDirectory()) {
        throw new HostError("INVALID_ARGUMENT", "project path is not a directory", { field: "path" });
      }
      await access(target, constants.R_OK | constants.X_OK);
      return target;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (code === "ENOENT" || code === "ENOTDIR") {
        throw new HostError("NOT_FOUND", "project directory does not exist", { field: "path" });
      }
      if (code === "EACCES" || code === "EPERM") {
        throw new HostError("FORBIDDEN", "project directory is not accessible", { field: "path" });
      }
      throw error;
    }
  }

  async deleteProject(projectId: string, confirmProjectId: string) {
    if (confirmProjectId !== projectId) {
      throw new HostError("INVALID_ARGUMENT", "project confirmation does not match");
    }
    const projectSessionIds = new Set(
      (await this.deps.meta.listSessions(true))
        .filter((session) => session.projectId === projectId)
        .map((session) => session.id)
    );
    return this.lockSessions([...projectSessionIds].sort(), async () => {
      if ([...projectSessionIds].some((sessionId) => this.deps.turns.sessionBusy(sessionId))) {
        throw new HostError("SESSION_BUSY", "a session is running or cleaning up");
      }
      for (const sessionId of projectSessionIds) await this.deps.extensionSnapshots.delete(sessionId);
      return { deleted: true, projectId: (await this.deps.meta.deleteProject(projectId)).id };
    });
  }

  async requireSession(sessionId: string): Promise<SessionMeta> {
    const session = await this.deps.meta.getSession(sessionId);
    if (!session || session.deletedAt) throw new HostError("NOT_FOUND", "session not found");
    return session;
  }

  summarize(session: SessionMeta): SessionMeta & { activeTurnId: string | null } {
    return { ...session, activeTurnId: this.deps.turns.activeTurnIdFor(session.id) };
  }

  async listSessions(includeArchived: boolean) {
    const native = await this.deps.catalog.scan();
    const projects = await this.deps.meta.listProjects(true);
    await this.deps.meta.importDiscoveredSessions(
      native.map((item): SessionMeta => ({
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
      }))
    );
    const sessions = await this.deps.meta.listSessions(includeArchived);
    return {
      sessions: sessions.filter((session) => !session.deletedAt).map((session) => this.summarize(session)),
      revision: 1
    };
  }

  async searchSessions(query: string, limit: number) {
    const result = await this.listSessions(true);
    const lower = query.toLowerCase();
    return {
      sessions: result.sessions
        .filter((session) => `${session.title} ${session.projectPath}`.toLowerCase().includes(lower))
        .slice(0, Math.max(1, Math.min(limit, 200)))
        .map((session) => this.summarize(session))
    };
  }

  async createSessionWithKey(params: Record<string, unknown>, deviceId: string, key: string) {
    const digest = requestDigest(params);
    const id = sha256(JSON.stringify(["session/create", deviceId, key, digest]));
    return this.deps.idempotency.run(
      key,
      "session/create",
      digest,
      async () => ({ session: this.summarize(await this.createSession(params, id)) }),
      deviceId,
      undefined,
      async () => {
        const session = await this.deps.meta.getSession(id);
        return session && !session.deletedAt ? { session: this.summarize(session) } : undefined;
      }
    );
  }

  async createSession(params: Record<string, unknown>, id = uuid()): Promise<SessionMeta> {
    const existing = await this.deps.meta.getSession(id);
    if (existing) {
      if (existing.deletedAt) throw new HostError("CONFLICT", "the created session was deleted");
      return existing;
    }
    const projectId = typeof params.projectId === "string" ? params.projectId : null;
    const project = projectId ? await this.deps.meta.getProject(projectId) : null;
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
    await this.deps.meta.upsertSession(session);
    await this.deps.emit("host", "session.created", { session });
    return session;
  }

  attachSession(sessionId: string) {
    return this.deps.sessionLocks.run(sessionId, () => this.attachSessionSnapshot(sessionId));
  }

  private async attachSessionSnapshot(sessionId: string) {
    let session = await this.requireSession(sessionId);
    let native = session.nativePath ? await this.deps.catalog.historyForAttach(session.nativePath, sessionId) : undefined;
    if (
      session.nativePath &&
      native?.readOnlyReason === "external_write_conflict" &&
      this.deps.turns.activeTurnIdFor(sessionId)
    ) {
      native = await this.deps.catalog.historyForAttach(session.nativePath, sessionId);
      if (native.readOnlyReason === "external_write_conflict") {
        throw new HostError("CONFLICT", "Session changed while reading. Open it again to refresh.");
      }
    }
    if (
      native &&
      (native.readOnlyReason || !this.deps.turns.activeTurnIdFor(sessionId)) &&
      native.readOnlyReason !== (session.readOnlyReason ?? null)
    ) {
      session = await this.updateSessionWriteState(session, native.readOnlyReason);
    }
    const cursor = this.deps.journal.currentCursor();
    const history = native?.entries ?? [];
    const pendingApprovals = this.deps.turns.pendingApprovalSnapshots(sessionId);
    const summary = this.summarize(session);
    const activeTurn = summary.activeTurnId ? this.deps.turns.turns.get(summary.activeTurnId) ?? null : null;
    const activeItems = activeTurn ? this.deps.turns.activeItemPreviews(activeTurn.id) : [];
    const queuedTurns = this.deps.turns.queuedTurnSnapshots(sessionId);
    const result = {
      session: summary,
      snapshot: {
        session: summary,
        revision: session.revision,
        cursor,
        items: [] as Record<string, unknown>[],
        activeItems,
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
        hasMoreHistory: false,
        replayComplete: true
      },
      replayComplete: true
    };
    const page = await historyPage(
      this.deps.blobs,
      session.id,
      history,
      undefined,
      SNAPSHOT_HISTORY_LIMIT,
      Buffer.byteLength(JSON.stringify(result), "utf8")
    );
    result.snapshot.items = page.items;
    result.snapshot.hasMoreHistory = page.hasMore;
    return result;
  }

  async history(sessionId: string, params: Record<string, unknown> = {}) {
    const range = params.textRange === undefined ? undefined : obj(params.textRange);
    if (range) {
      if (params.beforeItemId !== undefined || params.limit !== undefined) {
        throw new HostError("INVALID_ARGUMENT", "textRange cannot be used with history pagination");
      }
      const itemId = str(range.itemId, "textRange.itemId");
      const offset = range.offset;
      if (typeof offset !== "number" || !Number.isSafeInteger(offset) || offset < 0) {
        throw new HostError("INVALID_ARGUMENT", "textRange.offset must be a nonnegative integer");
      }
      return this.deps.sessionLocks.run(sessionId, async () => {
        const session = await this.requireSession(sessionId);
        if (!session.nativePath) throw new HostError("NOT_FOUND", "history item no longer exists");
        const textChunk = await this.deps.catalog.historyTextChunk(
          session.nativePath,
          sessionId,
          itemId,
          offset,
          HISTORY_TEXT_CHUNK_BYTES
        );
        return { items: [], hasMore: false, revision: session.revision, textChunk };
      });
    }
    const limit = params.limit === undefined ? SNAPSHOT_HISTORY_LIMIT : params.limit;
    if (typeof limit !== "number" || !Number.isInteger(limit) || limit < 1 || limit > HISTORY_PAGE_MAX_ITEMS) {
      throw new HostError("INVALID_ARGUMENT", "history limit must be an integer from 1 to 200", { field: "limit" });
    }
    const beforeItemId = params.beforeItemId === undefined ? undefined : str(params.beforeItemId, "beforeItemId");
    return this.deps.sessionLocks.run(sessionId, async () => {
      const session = await this.requireSession(sessionId);
      const history = session.nativePath ? await this.deps.catalog.history(session.nativePath, sessionId) : [];
      const result = { items: [] as Record<string, unknown>[], hasMore: false, revision: session.revision };
      const page = await historyPage(
        this.deps.blobs,
        session.id,
        history,
        beforeItemId,
        limit,
        Buffer.byteLength(JSON.stringify(result), "utf8")
      );
      result.items = page.items;
      result.hasMore = page.hasMore;
      return result;
    });
  }

  async configureSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const changes: Partial<SessionMeta> = {};
    if (params.mode !== undefined) {
      if (params.mode !== "agent" && params.mode !== "plan") {
        throw new HostError("INVALID_ARGUMENT", "mode must be agent or plan", { field: "mode" });
      }
      changes.mode = params.mode;
    }
    if (params.permissionMode === "ask" || params.permissionMode === "auto") changes.permissionMode = params.permissionMode;
    if (typeof params.providerId === "string") changes.providerId = params.providerId;
    if (typeof params.modelId === "string") changes.modelId = params.modelId;
    if (typeof params.thinkingLevel === "string") changes.thinkingLevel = params.thinkingLevel;
    return this.reviseSession(sessionId, changes);
  }

  async suggestSessionTitle(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const rawInstruction = str(params.instruction, "instruction");
    const instruction = rawInstruction.slice(0, 4_000);
    const session = await this.requireSession(sessionId);
    const providerId =
      typeof params.providerId === "string" && params.providerId ? params.providerId : session.providerId;
    const modelId = typeof params.modelId === "string" && params.modelId ? params.modelId : session.modelId;
    if (!providerId) throw new HostError("PROVIDER_NOT_CONFIGURED", "provider is required");
    if (!modelId) throw new HostError("PROVIDER_NOT_CONFIGURED", "model is required");
    const provider = (await this.deps.providers.list()).find((entry) => entry.id === providerId);
    if (!provider) throw new HostError("NOT_FOUND", "provider not found", { field: "providerId" });

    const apiKey = transientApiKey(params);
    this.deps.turns.assertProviderKey(provider, apiKey, params.providerBinding);
    const api = providerApi(provider.protocol);
    const declared = provider.models.find((model) => model.id === modelId);
    const runtime = await createProviderRuntime(
      provider.id,
      {
        name: provider.name,
        baseUrl: provider.baseUrl,
        api,
        models: [
          {
            id: modelId,
            name: declared?.displayName ?? modelId,
            api,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: declared?.contextWindow ?? 32_768,
            maxTokens: declared?.maxTokens ?? 4_096,
            reasoning: declared?.thinkingLevels.length ? true : false
          }
        ]
      },
      provider.authKind === "api_key" ? apiKey! : "none"
    );
    const model = runtime.getModel(provider.id, modelId);
    if (!model) throw new HostError("PROVIDER_NOT_CONFIGURED", "model is not configured");

    const prompt = [
      "You name coding sessions. Write a concise title for the session based on the user's first instruction.",
      "Requirements: at most 12 Chinese characters or 6 English words; no quotes, no trailing punctuation, no explanation.",
      "Reply with the title only.",
      "",
      "First instruction:",
      instruction
    ].join("\n");
    const message = await runtime.completeSimple(
      model,
      { messages: [{ role: "user", content: prompt, timestamp: Date.now() }] },
      { maxTokens: 64 }
    );
    const text = publicAssistantMessage(message).content
      .filter((part): part is { type: "text"; text: string } => part.type === "text")
      .map((part) => part.text)
      .join(" ")
      .trim();
    return { title: sanitizeSessionTitle(text) ?? fallbackSessionTitle(instruction) };
  }

  async renameSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const title = str(params.title, "title");
    return this.reviseSession(sessionId, { title }, async (session) => {
      if (session.nativePath && this.deps.turns.sessionBusy(sessionId)) {
        throw new HostError("SESSION_BUSY", "wait until the session is idle before renaming");
      }
      if (session.readOnlyReason) throw new HostError("SESSION_READ_ONLY", session.readOnlyReason);
      if (!session.nativePath) return;
      try {
        await this.deps.catalog.appendSessionInfo(session.nativePath, title, session.id);
      } catch (error) {
        if (error instanceof HostError && error.code === "SESSION_READ_ONLY") {
          await this.updateSessionWriteState(session, error.message);
        }
        throw error;
      }
    });
  }

  async archiveSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    return this.reviseSession(sessionId, { archived: params.archived === true });
  }

  async reviseSession(
    sessionId: string,
    changes: Partial<Omit<SessionMeta, "id" | "createdAt" | "revision">>,
    beforeSave?: (session: SessionMeta) => Promise<void>
  ): Promise<SessionMeta> {
    return this.deps.sessionLocks.run(sessionId, async () => {
      if (beforeSave) await beforeSave(await this.requireSession(sessionId));
      const updated = await this.deps.meta.updateSession(sessionId, changes, { incrementRevision: true });
      await this.deps.emit("host", "session.changed", { session: updated }, { sessionId });
      return updated;
    });
  }

  async updateSessionWriteState(session: SessionMeta, reason: string | null): Promise<SessionMeta> {
    if ((session.readOnlyReason ?? null) === reason) return session;
    const updated = await this.deps.meta.updateSession(session.id, { readOnlyReason: reason }, { incrementRevision: true });
    await this.deps.emit("host", "session.changed", { session: updated }, { sessionId: session.id });
    return updated;
  }

  async branchSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    const session = await this.requireSession(sessionId);
    if (!session.nativePath) throw new HostError("NOT_FOUND", "session has no native file");
    const childPath = await this.deps.catalog.branch(session.nativePath, str(params.fromItemId, "fromItemId"), sessionId);
    const child = await this.deps.catalog.scan().then((items) => items.find((item) => item.path === childPath));
    if (!child) throw new HostError("INTERNAL", "branch was not discoverable");
    return this.deps.meta.upsertSession({
      ...session,
      id: child.id,
      title: typeof params.title === "string" ? params.title : `${session.title} branch`,
      nativePath: child.path,
      revision: 1,
      createdAt: child.createdAt,
      updatedAt: child.updatedAt,
      archived: false,
      readOnlyReason: child.readOnlyReason
    });
  }

  async deleteSession(params: Record<string, unknown>) {
    const sessionId = str(params.sessionId, "sessionId");
    if (str(params.confirmSessionId, "confirmSessionId") !== sessionId) {
      throw new HostError("INVALID_ARGUMENT", "session confirmation does not match");
    }
    return this.deps.sessionLocks.run(sessionId, async () => {
      const session = await this.requireSession(sessionId);
      if (this.deps.turns.sessionBusy(sessionId)) {
        throw new HostError("SESSION_BUSY", "session is running or has queued turns");
      }
      if (session.nativePath) await this.deps.catalog.deleteFile(session.nativePath, sessionId);
      this.deps.turns.clearSessionQueue(sessionId);
      this.deps.catalog.forgetHistoryText(sessionId);
      await this.deps.extensionSnapshots.delete(sessionId);
      await this.deps.blobs.deleteSession(sessionId);
      await this.deps.meta.deleteSession(sessionId);
      await this.deps.emit("host", "session.deleted", { sessionId }, { sessionId });
      return { deleted: true, sessionId };
    });
  }

  private lockSessions<T>(ids: string[], work: () => Promise<T>): Promise<T> {
    const [first, ...rest] = ids;
    return first === undefined ? work() : this.deps.sessionLocks.run(first, () => this.lockSessions(rest, work));
  }
}
