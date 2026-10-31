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
    const value = await readJsonFile<MetaFile>(this.path, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported catalog version");
    return value;
  }

  private async save(value: MetaFile): Promise<void> {
    await writeJsonFileAtomic(this.path, value, 0o600);
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
    changes: Partial<Omit<SessionMeta, "id" | "createdAt">>,
    now = new Date()
  ): Promise<SessionMeta> {
    return this.serialized(async () => {
      const data = await this.load();
      const session = data.sessions.find((entry) => entry.id === sessionId);
      if (!session) throw new HostError("NOT_FOUND", "session not found");
      Object.assign(session, changes, { updatedAt: now.toISOString() });
      await this.save(data);
      return session;
    });
  }

  async deleteSession(sessionId: string, now = new Date()): Promise<SessionMeta> {
    return this.serialized(async () => {
      const data = await this.load();
      const session = data.sessions.find((entry) => entry.id === sessionId);
      if (!session) throw new HostError("NOT_FOUND", "session not found");
      session.deletedAt = now.toISOString();
      session.updatedAt = now.toISOString();
      await this.save(data);
      return session;
    });
  }
}
