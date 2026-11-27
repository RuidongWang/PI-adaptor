import { join } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { uuid } from "../util/id.js";

export type ProjectRecord = {
  id: string;
  label: string;
  path: string;
  archived: boolean;
  createdAt: string;
  updatedAt: string;
  deletedAt?: string;
};

export type SessionMeta = {
  id: string;
  title: string;
  projectId: string | null;
  projectPath: string;
  mode: "agent" | "plan";
  permissionMode: "ask" | "auto";
  providerId: string | null;
  modelId: string | null;
  thinkingLevel: string | null;
  revision: number;
  archived: boolean;
  createdAt: string;
  updatedAt: string;
  nativePath?: string | null;
  previousNativePaths?: string[];
  nativePathConflict?: boolean;
  creationEventPending?: boolean;
  branchEventPending?: boolean;
  parentSession?: string;
  deletion?: { version: string | null };
  deletedAt?: string;
  readOnlyReason?: string | null;
};

type MetaFile = {
  version: 1;
  projects: ProjectRecord[];
  sessions: SessionMeta[];
};

const EMPTY: MetaFile = { version: 1, projects: [], sessions: [] };

export class MetaStore {
  private pending: Promise<void> = Promise.resolve();
  private cache: MetaFile | null = null;

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  private readonly path: string;

  constructor(dataDir: string) {
    this.path = join(dataDir, "meta", "catalog.json");
  }

  private async load(): Promise<MetaFile> {
    if (this.cache) return this.cache;
    const value = await readJsonFile<MetaFile>(this.path, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported catalog version");
    this.cache = value;
    return value;
  }

  private async save(value: MetaFile): Promise<void> {
    try {
      await writeJsonFileAtomic(this.path, value, 0o600);
      this.cache = value;
    } catch (error) {
      this.cache = null;
      throw error;
    }
  }

  async listProjects(includeArchived = true): Promise<ProjectRecord[]> {
    return (await this.load()).projects.filter((project) => !project.deletedAt && (includeArchived || !project.archived));
  }

  async registerProject(path: string, label: string, now = new Date()): Promise<ProjectRecord> {
    return this.serialized(async () => {
      const data = await this.load();
      const existing = data.projects.find((project) => project.path === path && !project.deletedAt);
      if (existing) {
        existing.label = label;
        existing.updatedAt = now.toISOString();
        await this.save(data);
        return existing;
      }
      const project: ProjectRecord = {
        id: uuid(),
        label,
        path,
        archived: false,
        createdAt: now.toISOString(),
        updatedAt: now.toISOString()
      };
      data.projects.push(project);
      await this.save(data);
      return project;
    });
  }

  async updateProject(
    projectId: string,
    changes: { label?: string; archived?: boolean },
    now = new Date()
  ): Promise<ProjectRecord> {
    return this.serialized(async () => {
      const data = await this.load();
      const project = data.projects.find((entry) => entry.id === projectId && !entry.deletedAt);
      if (!project) throw new HostError("NOT_FOUND", "project not found");
      if (changes.label !== undefined) project.label = changes.label;
      if (changes.archived !== undefined) project.archived = changes.archived;
      project.updatedAt = now.toISOString();
      await this.save(data);
      return project;
    });
  }

  async deleteProject(projectId: string, now = new Date()): Promise<ProjectRecord> {
    return this.serialized(async () => {
      const data = await this.load();
      const project = data.projects.find((entry) => entry.id === projectId && !entry.deletedAt);
      if (!project) throw new HostError("NOT_FOUND", "project not found");
      project.deletedAt = now.toISOString();
      project.updatedAt = now.toISOString();
      await this.save(data);
      return project;
    });
  }

  async getProject(projectId: string): Promise<ProjectRecord> {
    const project = (await this.load()).projects.find((entry) => entry.id === projectId && !entry.deletedAt);
    if (!project) throw new HostError("NOT_FOUND", "project not found");
    return project;
  }

  async listSessions(includeArchived = true): Promise<SessionMeta[]> {
    return (await this.load()).sessions.filter((session) => !session.deletedAt && (includeArchived || !session.archived));
  }

  async importDiscoveredSessions(sessions: SessionMeta[], namedSessions: Set<string>, titlesBeforeScan: Map<string, string>): Promise<void> {
    if (sessions.length === 0) return;
    await this.serialized(async () => {
      const data = await this.load();
      const known = new Map(data.sessions.map((session) => [session.id, session]));
      const observedIds = new Set(sessions.map(session => session.id));
      const superseded = new Set<string>();
      for (const session of sessions) {
        if (!session.nativePath || session.readOnlyReason || observedIds.has(session.nativePath)) continue;
        const placeholder = known.get(session.nativePath);
        if (placeholder && !placeholder.deletedAt && placeholder.nativePath === placeholder.id &&
            placeholder.projectPath === "" && placeholder.readOnlyReason) superseded.add(placeholder.id);
      }
      if (superseded.size) data.sessions = data.sessions.filter(session => !superseded.has(session.id));
      let changed = superseded.size > 0;
      for (const session of sessions) {
        const existing = known.get(session.id);
        if (existing) {
          if (existing.deletedAt || existing.nativePath !== session.nativePath) continue;
          const title = !session.readOnlyReason && namedSessions.has(session.id) && titlesBeforeScan.get(session.id) === existing.title
            ? session.title : existing.title;
          const updatedAt = session.updatedAt > existing.updatedAt ? session.updatedAt : existing.updatedAt;
          const readOnlyReason = existing.readOnlyReason ?? session.readOnlyReason;
          const parentChanged = session.parentSession !== undefined && session.parentSession !== existing.parentSession;
          if (title !== existing.title || updatedAt !== existing.updatedAt || readOnlyReason !== (existing.readOnlyReason ?? null) || parentChanged) {
            Object.assign(existing, { title, updatedAt, readOnlyReason });
            if (session.parentSession !== undefined) existing.parentSession = session.parentSession;
            existing.revision += 1;
            changed = true;
          }
        } else {
          known.set(session.id, session);
          data.sessions.push(session);
          changed = true;
        }
      }
      if (changed) await this.save(data);
    });
  }

  async upsertSession(session: SessionMeta): Promise<SessionMeta> {
    return this.serialized(async () => {
      const data = await this.load();
      const index = data.sessions.findIndex((entry) => entry.id === session.id);
      if (index >= 0) data.sessions[index] = { ...data.sessions[index], ...session };
      else data.sessions.push(session);
      await this.save(data);
      return session;
    });
  }

  async getSession(sessionId: string): Promise<SessionMeta | null> {
    return (await this.load()).sessions.find((entry) => entry.id === sessionId) ?? null;
  }

  async updateSession(
    sessionId: string,
    changes: Partial<Omit<SessionMeta, "id" | "createdAt" | "revision">>,
    { incrementRevision = false, now = new Date() } = {}
  ): Promise<SessionMeta> {
    return this.serialized(async () => {
      const data = await this.load();
      const session = data.sessions.find((entry) => entry.id === sessionId && !entry.deletedAt);
      if (!session) throw new HostError("NOT_FOUND", "session not found");
      Object.assign(session, changes, { updatedAt: now.toISOString() });
      if (incrementRevision) session.revision += 1;
      await this.save(data);
      return session;
    });
  }

  async pendingDeletions(): Promise<SessionMeta[]> {
    return (await this.load()).sessions.filter(session => session.deletion);
  }

  async finishDeletion(sessionId: string): Promise<void> {
    await this.serialized(async () => {
      const data = await this.load();
      const next = data.sessions.map(session => {
        if (session.id !== sessionId) return session;
        const { deletion: _deletion, ...tombstone } = session;
        return tombstone;
      });
      await this.save({ ...data, sessions: next });
    });
  }

  async deleteSession(sessionId: string, now = new Date(), deletion?: { version: string | null }): Promise<SessionMeta> {
    return this.serialized(async () => {
      const data = await this.load();
      const session = data.sessions.find((entry) => entry.id === sessionId);
      if (!session) throw new HostError("NOT_FOUND", "session not found");
      const deleted = { ...session, deletedAt: now.toISOString(), updatedAt: now.toISOString(), ...(deletion ? { deletion } : {}) };
      await this.save({ ...data, sessions: data.sessions.map(entry => entry.id === sessionId ? deleted : entry) });
      return deleted;
    });
  }
}
