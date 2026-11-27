import { join } from "node:path";
import { AgentDriver } from "../agent/driver.js";
import { HostConfig } from "../config.js";
import { HostError } from "../errors.js";
import { EventJournal, type Cursor, type HostEvent } from "../events/journal.js";
import { ExtensionRegistry } from "../extensions/registry.js";
import { ExtensionSnapshotStore } from "../extensions/snapshot-store.js";
import { BlobStore } from "../media/blob-store.js";
import { MetaStore, type SessionMeta } from "../meta/store.js";
import { NativeSessionCatalog } from "../pi/session-catalog.js";
import { discoverProviderModels, ProviderDiscoveryError, type ProviderDiscoveryInput, type ProviderDiscoveryOptions } from "../providers/discovery.js";
import { isSupportedProviderProtocol } from "../providers/protocol.js";
import { ProviderStore } from "../providers/store.js";
import { TokenStore, type DeviceRecord } from "../security/tokens.js";
import { SkillRegistry } from "../skills/registry.js";
import { sha256, uuid } from "../util/id.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { KeyedMutex } from "../util/keyed-mutex.js";
import { HISTORY_TEXT_CHUNK_BYTES } from "./history-projector.js";
import { IdempotencyStore, requestDigest } from "./idempotency.js";
import { fallbackSessionTitle, sanitizeSessionTitle, SessionService } from "./session-service.js";
import { TurnCoordinator } from "./turn-coordinator.js";
import { TurnStore } from "./turn-store.js";

export { HISTORY_TEXT_CHUNK_BYTES, fallbackSessionTitle, sanitizeSessionTitle };

const IDEMPOTENT_METHODS = new Set([
  "connection/revoke",
  "connection/confirm-rotation",
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

export type AuthContext = { device: DeviceRecord };
export type EventSink = (event: HostEvent) => void;
export const SUBSCRIPTION_BYTE_LIMIT = 2 * 1024 * 1024;
export const SUBSCRIPTION_EVENT_LIMIT = 512;
export type ConnectionEffects = {
  acknowledge?(id: string, sequence: unknown): void;
  rotationConfirmed?(deviceId: string, previousCredentialHash: string): void;
};

class HostProviderDiscoveryError extends HostError {
  constructor(
    private readonly discoveryError: ProviderDiscoveryError,
    private readonly requestId: string | undefined
  ) {
    super("INTERNAL", discoveryError.message, discoveryError.data);
    this.name = "ProviderDiscoveryError";
  }

  override toJSONRPC(id: string | number | null): ReturnType<ProviderDiscoveryError["toJSONRPC"]> {
    const envelope = this.discoveryError.toJSONRPC(id);
    if (this.requestId && !envelope.error.data.requestId) {
      envelope.error.data = { requestId: this.requestId, ...envelope.error.data };
    }
    return envelope;
  }
}

type Subscription = {
  id: string;
  scope: "host" | "session";
  sessionId: string | undefined;
  sink?: EventSink;
  buffer: HostEvent[];
  bufferedBytes: number;
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

function idempotencyKeyFrom(params: Record<string, unknown>): string | undefined {
  const raw = params.context;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return undefined;
  const key = (raw as { idempotencyKey?: unknown }).idempotencyKey;
  return typeof key === "string" && key.length > 0 ? key : undefined;
}

export class HostService {
  readonly tokens: TokenStore;
  readonly meta: MetaStore;
  readonly catalog: NativeSessionCatalog;
  readonly journal: EventJournal;
  readonly blobs: BlobStore;
  readonly providers: ProviderStore;
  readonly skills: SkillRegistry;
  readonly extensions: ExtensionRegistry;
  readonly extensionSnapshots: ExtensionSnapshotStore;
  hostId: string;

  private shuttingDown = false;
  private shutdownPromise: Promise<void> | undefined;
  private readonly inFlight = new Set<Promise<unknown>>();
  private readonly subscriptions = new Map<string, Subscription>();
  private readonly idempotency: IdempotencyStore;
  private readonly turnStore: TurnStore;
  private readonly sessionLocks = new KeyedMutex();
  private readonly turnCoordinator: TurnCoordinator;
  private readonly sessionService: SessionService;
  private maintenanceTimer: NodeJS.Timeout | undefined;

  // Test-inspection forwarders preserved for existing unit suites.
  private get executingDrivers() { return this.turnCoordinator.executingDrivers; }
  private get turns() { return this.turnCoordinator.turns; }
  private get turnEventChains() { return this.turnCoordinator.turnEventChains; }
  private get pendingApprovals() { return this.turnCoordinator.pendingApprovals; }
  private get approvalRevision() { return this.turnCoordinator.approvalRevision; }
  private requestApproval(session: SessionMeta, turnId: string, toolName: string, input: unknown) {
    return this.turnCoordinator.requestApproval(session, turnId, toolName, input);
  }

  constructor(
    readonly config: HostConfig,
    private readonly driver: AgentDriver,
    private readonly discoveryOptions: ProviderDiscoveryOptions = {}
  ) {
    this.tokens = new TokenStore(config.dataDir);
    this.meta = new MetaStore(config.dataDir);
    this.catalog = new NativeSessionCatalog(config.sessionRoots);
    this.journal = new EventJournal(config.dataDir);
    this.blobs = new BlobStore(config.dataDir);
    this.providers = new ProviderStore(config.dataDir, { lookup: discoveryOptions.testOnly?.lookup });
    this.skills = new SkillRegistry(config.dataDir, join(config.agentDir, ".."));
    this.idempotency = new IdempotencyStore(config.dataDir);
    this.turnStore = new TurnStore(config.dataDir);
    this.extensions = new ExtensionRegistry(config.extensions);
    this.extensionSnapshots = new ExtensionSnapshotStore(config.dataDir);
    this.hostId = config.hostId || uuid();

    this.turnCoordinator = new TurnCoordinator({
      config: this.config,
      meta: this.meta,
      catalog: this.catalog,
      blobs: this.blobs,
      providers: this.providers,
      skills: this.skills,
      extensions: this.extensions,
      extensionSnapshots: this.extensionSnapshots,
      turnStore: this.turnStore,
      driver: this.driver,
      hasTransition: (kind, sessionId, turnId) => this.journal.hasTransition(kind, sessionId, turnId),
      confirmTerminal: turnId => this.journal.confirmTransition(turnId),
      sessionLocks: this.sessionLocks,
      getHostId: () => this.hostId,
      isShuttingDown: () => this.shuttingDown,
      trackWork: (work) => this.trackWork(work),
      emit: (scope, kind, payload, extra) => this.emit(scope, kind, payload, extra),
      requireSession: (sessionId) => this.sessionService.requireSession(sessionId),
      updateSessionWriteState: (session, reason) => this.sessionService.updateSessionWriteState(session, reason)
    });

    this.sessionService = new SessionService({
      meta: this.meta,
      catalog: this.catalog,
      journal: this.journal,
      blobs: this.blobs,
      providers: this.providers,
      idempotency: this.idempotency,
      extensionSnapshots: this.extensionSnapshots,
      sessionLocks: this.sessionLocks,
      turns: this.turnCoordinator,
      emit: (scope, kind, payload, extra) => this.emit(scope, kind, payload, extra)
    });
  }

  async init(): Promise<{ removedLegacySecrets: number }> {
    await this.extensions.initialize();
    await this.blobs.init();
    const recovered = await this.turnStore.reconcileAfterRestart();
    const creations = (await this.meta.listSessions(true)).filter(session => session.creationEventPending ?? session.branchEventPending);
    const deletions = await this.meta.pendingDeletions();
    await this.journal.load(new Set([...recovered.filter(turn => turn.eventPending).map(turn => turn.id),
      ...creations.map(session => `branch:${session.id}`), ...deletions.map(session => `deleted:${session.id}`)]));
    const hostPath = join(this.config.dataDir, "meta", "host.json");
    const stored = await readJsonFile<{ version: 1; hostId: string } | null>(hostPath, null);
    if (stored?.version === 1 && stored.hostId) this.hostId = stored.hostId;
    else await writeJsonFileAtomic(hostPath, { version: 1, hostId: this.hostId }, 0o600);
    await this.tokens.recoverUnconfirmedRotations();
    this.turnCoordinator.seedRecoveredTurns(recovered);
    for (const record of recovered) if (record.eventPending) await this.turnCoordinator.publishPendingTerminal(record);
    for (const session of creations) await this.sessionService.notifyCreation(session);
    await this.sessionService.recoverDeletions();
    await this.extensionSnapshots.recover(new Set((await this.meta.listSessions(true)).map((session) => session.id)));
    const removedLegacySecrets = await this.providers.purgeLegacySecrets();
    return { removedLegacySecrets };
  }

  startMaintenance(intervalMs = 60 * 60 * 1000): void {
    if (this.shuttingDown || this.maintenanceTimer) return;
    void this.runMaintenance().catch(() => undefined);
    this.maintenanceTimer = setInterval(() => {
      void this.runMaintenance().catch(() => undefined);
    }, intervalMs);
    this.maintenanceTimer.unref?.();
  }

  shutdown(): Promise<void> {
    this.shuttingDown = true;
    this.stopMaintenance();
    this.shutdownPromise ??= (async () => {
      await this.turnCoordinator.shutdown();
      while (this.inFlight.size) await Promise.allSettled([...this.inFlight]);
      await this.tokens.waitForWrites();
      this.idempotency.close();
    })();
    return this.shutdownPromise;
  }

  private trackWork<T>(work: Promise<T>): Promise<T> {
    this.inFlight.add(work);
    void work.then(() => this.inFlight.delete(work), () => this.inFlight.delete(work));
    return work;
  }

  stopMaintenance(): void {
    if (this.maintenanceTimer) clearInterval(this.maintenanceTimer);
    this.maintenanceTimer = undefined;
  }

  runMaintenance(now = new Date()): Promise<number> {
    if (this.shuttingDown) return Promise.resolve(0);
    return this.trackWork(this.performMaintenance(now));
  }

  private async performMaintenance(now: Date): Promise<number> {
    let expired = 0;
    try {
      await this.sessionService.recoverDeletions();
      expired = await this.blobs.expireUploads(now);
      const { ids, hashes, protectedSessions } = await this.collectReferencedAttachments();
      return expired + await this.blobs.gc(ids, hashes, now, protectedSessions);
    } catch (error) {
      console.warn("attachment maintenance did not finish:", error);
      return expired;
    }
  }

  private async collectReferencedAttachments() {
    const ids = new Set<string>();
    const hashes = new Set<string>();
    const protectedSessions = new Set<string>();
    for (const session of await this.meta.listSessions(true)) {
      if (session.nativePathConflict) { protectedSessions.add(session.id); continue; }
      if (!session.nativePath) continue;
      let entries;
      try {
        entries = await this.catalog.allEntriesForMaintenance(session.nativePath, session.id);
      } catch {
        protectedSessions.add(session.id);
        console.warn("attachment GC retained media for unreadable session:", session.id);
        continue;
      }
      for (const entry of entries) {
        if (entry.type !== "message") continue;
        const content = (entry.message as { content?: unknown }).content;
        if (!Array.isArray(content)) continue;
        for (const part of content) {
          if (!part || typeof part !== "object") continue;
          const block = part as { attachmentId?: unknown; type?: unknown; data?: unknown };
          if (typeof block.attachmentId === "string") ids.add(block.attachmentId);
          if (block.type === "image" && typeof block.data === "string") {
            hashes.add(sha256(Buffer.from(block.data, "base64")));
          }
        }
      }
    }
    return { ids, hashes, protectedSessions };
  }

  async initialize(params: Record<string, unknown>) {
    if (params.protocolVersion !== "2.0.0") {
      throw new HostError("PROTOCOL_MISMATCH", "unsupported initialize protocolVersion");
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
        allowedSessionModes: ["agent"],
        maxImageBytes: 20 * 1024 * 1024,
        maxImagesPerMessage: 10,
        approvalDisconnectSeconds: 86400
      },
      capabilities: {
        extensionInventory: true,
        sessionExtensions: true,
        extensionManagement: false,
        extensionUI: false,
        attachments: true,
        imageOutput: true,
        skills: true,
        providers: true,
        sessionBranches: true,
        sessionDelete: true,
        nativePiSessions: true,
        directTransport: true,
        providerDiscovery: true,
        providerClientKeys: true
      }
    };
  }

  async pair(params: Record<string, unknown>, token: string) {
    const label = typeof params.deviceLabel === "string" ? params.deviceLabel : "device";
    const paired = await this.tokens.pair(token, label);
    return { ...paired, hostId: this.hostId, roles: ["owner"] };
  }

  async createPairingToken(ttlSeconds = 600) {
    if (this.shuttingDown) throw new HostError("CAPABILITY_UNAVAILABLE", "host is shutting down");
    return this.trackWork(this.tokens.createPairingToken(ttlSeconds));
  }

  async authenticateDevice(token: string): Promise<DeviceRecord> {
    if (this.shuttingDown) throw new HostError("CAPABILITY_UNAVAILABLE", "host is shutting down");
    return this.trackWork(this.tokens.authenticate(token));
  }

  async handle(
    method: string,
    rawParams: unknown,
    auth: AuthContext | null,
    pairingToken?: string,
    effects?: ConnectionEffects
  ): Promise<unknown> {
    if (this.shuttingDown) throw new HostError("CAPABILITY_UNAVAILABLE", "host is shutting down");
    return this.trackWork(this.handleAdmitted(method, rawParams, auth, pairingToken, effects));
  }

  private async handleAdmitted(
    method: string,
    rawParams: unknown,
    auth: AuthContext | null,
    pairingToken?: string,
    effects?: ConnectionEffects
  ): Promise<unknown> {
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
        if (method === "session/create") return this.sessionService.createSessionWithKey(params, auth.device.deviceId, key);
        if (method === "session/branch") {
          const digest = requestDigest(params);
          const id = sha256(JSON.stringify([method, auth.device.deviceId, key, digest]));
          const branch = async (recoverOnly = false) => ({ session: this.sessionService.summarize(await this.sessionService.branchSession(params, id, recoverOnly)) });
          return this.idempotency.run(key, method, digest, branch, auth.device.deviceId, undefined, () => branch(true));
        }
        return this.idempotency.run(
          key,
          method,
          requestDigest(params),
          () => this.dispatch(method, params, auth, effects),
          auth.device.deviceId,
          undefined,
          method === "session/delete" ? () => this.sessionService.deleteSession(params) : undefined
        );
      }
    }
    return this.dispatch(method, params, auth, effects);
  }

  private async dispatch(
    method: string,
    params: Record<string, unknown>,
    auth: AuthContext,
    effects?: ConnectionEffects
  ): Promise<unknown> {
    switch (method) {
      case "connection/ping":
        return { ok: true, serverTime: new Date().toISOString(), pong: true, hostId: this.hostId };
      case "device/list":
        return { devices: await this.tokens.listDevices() };
      case "device/pairing-token":
        return this.createPairingToken(typeof params.ttlSeconds === "number" ? params.ttlSeconds : 600);
      case "connection/rotate-token":
        return this.tokens.rotate(auth.device.deviceId, idempotencyKeyFrom(params));
      case "connection/confirm-rotation": {
        let previousCredentialHash: string | undefined;
        const confirmed = await this.tokens.confirmRotation(
          auth.device.deviceId,
          str(params.rotationId, "rotationId"),
          (hash) => {
            previousCredentialHash = hash;
          }
        );
        if (confirmed && previousCredentialHash) {
          effects?.rotationConfirmed?.(auth.device.deviceId, previousCredentialHash);
        }
        return { confirmed };
      }
      case "connection/revoke":
        return { revoked: await this.tokens.revoke(str(params.deviceId, "deviceId")) };
      case "project/list":
        return { projects: await this.meta.listProjects(true) };
      case "project/browse":
        return this.sessionService.browseProject(typeof params.path === "string" ? params.path : undefined);
      case "project/register": {
        const path = await this.sessionService.projectDirectory(str(params.path, "path"));
        const label = typeof params.label === "string" ? params.label : path.split("/").pop() ?? path;
        return { project: await this.meta.registerProject(path, label) };
      }
      case "project/update": {
        const changes: { label?: string; archived?: boolean } = {};
        if (typeof params.label === "string") changes.label = params.label;
        if (typeof params.archived === "boolean") changes.archived = params.archived;
        return { project: await this.meta.updateProject(str(params.projectId, "projectId"), changes) };
      }
      case "project/delete":
        return this.sessionService.deleteProject(
          str(params.projectId, "projectId"),
          str(params.confirmProjectId, "confirmProjectId")
        );
      case "session/list":
        return this.sessionService.listSessions(typeof params.includeArchived === "boolean" ? params.includeArchived : true);
      case "session/search":
        return this.sessionService.searchSessions(
          str(params.query, "query"),
          typeof params.limit === "number" ? params.limit : 50
        );
      case "session/get":
        return { session: this.sessionService.summarize(await this.sessionService.requireSession(str(params.sessionId, "sessionId"))) };
      case "session/create":
        return { session: this.sessionService.summarize(await this.sessionService.createSession(params)) };
      case "session/attach":
        return this.sessionService.attachSession(str(params.sessionId, "sessionId"));
      case "session/history":
        return this.sessionService.history(str(params.sessionId, "sessionId"), params);
      case "session/configure":
        return { session: this.sessionService.summarize(await this.sessionService.configureSession(params)) };
      case "session/rename":
        return { session: this.sessionService.summarize(await this.sessionService.renameSession(params)) };
      case "session/suggest-title":
        return this.sessionService.suggestSessionTitle(params);
      case "session/archive":
        return { session: this.sessionService.summarize(await this.sessionService.archiveSession(params)) };
      case "session/branch":
        return { session: this.sessionService.summarize(await this.sessionService.branchSession(params)) };
      case "session/delete":
        return this.sessionService.deleteSession(params);
      case "events/subscribe":
        return this.subscribe(params);
      case "events/unsubscribe":
        str(params.subscriptionId, "subscriptionId");
        return { unsubscribed: true };
      case "events/ack":
        effects?.acknowledge?.(str(params.subscriptionId, "subscriptionId"), params.sequence);
        return { acknowledged: true };
      case "turn/start":
        return this.turnCoordinator.startTurn(params);
      case "turn/get":
        return { turn: this.turnCoordinator.publicTurn(this.turnCoordinator.getTurn(str(params.turnId, "turnId"))) };
      case "turn/interrupt":
        return this.turnCoordinator.stopTurn(str(params.turnId, "turnId"), "interrupted");
      case "turn/cancel":
        return this.turnCoordinator.stopTurn(str(params.turnId, "turnId"), "canceled");
      case "approval/respond":
        return this.turnCoordinator.respondApproval(params, auth.device.role);
      case "approval/read":
        return this.turnCoordinator.readApproval(params, auth.device.role);
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
      case "provider/test": {
        const providerId = str(params.providerId, "providerId");
        const provider = (await this.providers.list()).find((entry) => entry.id === providerId);
        if (!provider) throw new HostError("NOT_FOUND", "provider not found", { field: "providerId" });
        return { ok: provider.authKind === "none", checkedAt: new Date().toISOString() };
      }
      case "provider/discover":
        return this.discoverProvider(params, auth);
      case "extension/list":
        if (Object.keys(params).length !== 0) throw new HostError("INVALID_ARGUMENT", "extension/list accepts no parameters");
        return this.extensions.inventory(this.hostId);
      case "session/extensions": {
        if (Object.keys(params).some((key) => key !== "sessionId")) {
          throw new HostError("INVALID_ARGUMENT", "session/extensions only accepts sessionId");
        }
        const sessionId = str(params.sessionId, "sessionId");
        return this.sessionLocks.run(sessionId, async () => {
          await this.sessionService.requireSession(sessionId);
          return {
            hostId: this.hostId,
            sessionId,
            configRevision: this.extensions.configRevision,
            userLoadingEnabled: this.extensions.config.enabled,
            runningTurnId: this.turnCoordinator.activeTurnIdFor(sessionId),
            ...(await this.extensionSnapshots.get(sessionId))
          };
        });
      }
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
          attachment: await this.blobs.complete(str(params.attachmentId, "attachmentId"), str(params.sha256, "sha256"))
        };
      case "attachment/read": {
        const offset = params.offset === undefined ? 0 : params.offset;
        const length = params.length === undefined ? 262_144 : params.length;
        if (typeof offset !== "number" || typeof length !== "number") {
          throw new HostError("INVALID_ARGUMENT", "offset and length must be numbers");
        }
        return this.blobs.read(str(params.attachmentId, "attachmentId"), offset, length);
      }
      default:
        throw new HostError("INVALID_ARGUMENT", `unknown method: ${method}`);
    }
  }

  private invalidDiscovery(field: string, reason: string, requestId?: string): HostError {
    return new HostError("INVALID_ARGUMENT", "invalid provider discovery request", {
      field,
      reason,
      ...(requestId ? { requestId } : {})
    });
  }

  private parseProviderDiscoveryRequest(params: Record<string, unknown>): {
    providerId?: string;
    input?: ProviderDiscoveryInput;
    requestId?: string;
  } {
    const rawContext = params.context;
    const requestId =
      rawContext &&
      typeof rawContext === "object" &&
      !Array.isArray(rawContext) &&
      typeof (rawContext as { requestId?: unknown }).requestId === "string" &&
      (rawContext as { requestId: string }).requestId.length > 0
        ? (rawContext as { requestId: string }).requestId
        : undefined;
    for (const key of Object.keys(params)) {
      if (!["providerId", "baseUrl", "apiKey", "protocol", "context"].includes(key)) {
        throw this.invalidDiscovery(
          key,
          key === "idempotencyKey" ? "idempotency_forbidden" : "unknown_field",
          requestId
        );
      }
    }
    if (rawContext !== undefined) {
      if (!rawContext || typeof rawContext !== "object" || Array.isArray(rawContext)) {
        throw this.invalidDiscovery("context", "invalid_type", requestId);
      }
      const context = rawContext as Record<string, unknown>;
      for (const key of Object.keys(context)) {
        if (key !== "requestId") throw this.invalidDiscovery(`context.${key}`, "unknown_field", requestId);
      }
      if (!requestId) throw this.invalidDiscovery("context.requestId", "required", requestId);
    }
    const saved = params.providerId !== undefined;
    const adHoc = params.baseUrl !== undefined || params.apiKey !== undefined;
    if (saved && adHoc) throw this.invalidDiscovery("providerId", "mutually_exclusive", requestId);
    if (!saved && !adHoc) throw this.invalidDiscovery("providerId", "required", requestId);
    if (saved) {
      if (typeof params.providerId !== "string" || params.providerId.length === 0) {
        throw this.invalidDiscovery("providerId", "required", requestId);
      }
      if (params.protocol !== undefined) {
        throw this.invalidDiscovery("protocol", "mutually_exclusive", requestId);
      }
      return { providerId: params.providerId, ...(requestId ? { requestId } : {}) };
    }
    if (params.protocol !== undefined) {
      if (typeof params.protocol !== "string" || !isSupportedProviderProtocol(params.protocol)) {
        throw this.invalidDiscovery("protocol", "unsupported", requestId);
      }
    }
    if (typeof params.baseUrl !== "string" || params.baseUrl.length === 0) {
      throw this.invalidDiscovery("baseUrl", "required", requestId);
    }
    if (typeof params.apiKey !== "string" || params.apiKey.length === 0) {
      throw this.invalidDiscovery("apiKey", "required", requestId);
    }
    if (params.apiKey.length > 16_384 || /[\r\n]/.test(params.apiKey)) {
      throw this.invalidDiscovery("apiKey", "api_key", requestId);
    }
    return {
      input: {
        baseUrl: params.baseUrl,
        apiKey: params.apiKey,
        ...(typeof params.protocol === "string" ? { protocol: params.protocol } : {})
      },
      ...(requestId ? { requestId } : {})
    };
  }

  private async discoverProvider(params: Record<string, unknown>, auth: AuthContext) {
    if (auth.device.role !== "owner") {
      throw new HostError("FORBIDDEN", "provider discovery requires owner");
    }
    const request = this.parseProviderDiscoveryRequest(params);
    const deadlineAt = Date.now() + 7_000;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const deadline = new Promise<never>((_resolve, reject) => {
      timer = setTimeout(() => {
        reject(new ProviderDiscoveryError("UPSTREAM_TIMEOUT", "provider discovery deadline exceeded"));
      }, Math.max(0, deadlineAt - Date.now()));
    });
    const work = (async () => {
      let input: ProviderDiscoveryInput;
      if (request.providerId !== undefined) {
        input = await this.providers.discoveryInput(request.providerId);
      } else if (request.input) {
        input = request.input;
      } else {
        throw new HostError("INTERNAL", "provider discovery request could not be resolved");
      }
      if (Date.now() >= deadlineAt) {
        throw new ProviderDiscoveryError("UPSTREAM_TIMEOUT", "provider discovery deadline exceeded");
      }
      return discoverProviderModels(input, { ...this.discoveryOptions, deadlineAt });
    })();
    try {
      return await Promise.race([work, deadline]);
    } catch (error) {
      if (error instanceof ProviderDiscoveryError) {
        throw new HostProviderDiscoveryError(error, request.requestId);
      }
      throw error;
    } finally {
      if (timer !== undefined) clearTimeout(timer);
    }
  }

  private subscribe(params: Record<string, unknown>) {
    const scope = params.scope === "host" ? "host" : "session";
    const sessionId = typeof params.sessionId === "string" ? params.sessionId : undefined;
    const after = params.after as Cursor | undefined;
    const starting = this.journal.currentCursor();
    const replay = after ? this.journal.replay(scope, sessionId, after) : [];
    const id = uuid();
    this.subscriptions.set(id, { id, scope, sessionId, buffer: [], bufferedBytes: 0 });
    return { subscriptionId: id, starting, replayComplete: true, replay };
  }

  setSubscriptionSink(id: string, sink: EventSink): void {
    const subscription = this.subscriptions.get(id);
    if (!subscription) throw new HostError("CLIENT_TOO_SLOW", "subscription is no longer active");
    subscription.sink = sink;
    const pending = subscription.buffer.splice(0);
    subscription.bufferedBytes = 0;
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
        try { subscription.sink(event); } catch { this.removeSubscription(subscription.id); }
      } else {
        subscription.bufferedBytes += Buffer.byteLength(JSON.stringify(event));
        if (subscription.buffer.length >= SUBSCRIPTION_EVENT_LIMIT || subscription.bufferedBytes > SUBSCRIPTION_BYTE_LIMIT) {
          this.removeSubscription(subscription.id);
        } else subscription.buffer.push(event);
      }
    }
    return event;
  }

  private async createAttachment(params: Record<string, unknown>) {
    const session = await this.sessionService.requireSession(str(params.sessionId, "sessionId"));
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
