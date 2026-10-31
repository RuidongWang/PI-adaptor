import { cp, mkdir, readFile, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { uuid } from "../util/id.js";
import { assertPublicHttpsEndpoint } from "../security/endpoint.js";

export type SkillSource = {
  type: "git" | "directory";
  url?: string;
  path?: string;
  subdir?: string;
  ref?: string;
  refType?: "branch" | "tag" | "commit";
};

export type SkillRecord = {
  id: string;
  name: string;
  description: string;
  source: SkillSource;
  installedAt: string;
  updatedAt: string;
  status: "ready" | "updating" | "failed";
  path: string;
  version: string;
};

type SkillFile = { version: 1; skills: SkillRecord[] };
const EMPTY: SkillFile = { version: 1, skills: [] };

function frontmatter(body: string): { name: string; description: string } {
  const match = /^---\n([\s\S]*?)\n---/.exec(body);
  if (!match) throw new HostError("SKILL_SOURCE_UNAVAILABLE", "SKILL.md frontmatter is required");
  const values: Record<string, string> = {};
  for (const line of match[1]!.split("\n")) {
    const separator = line.indexOf(":");
    if (separator < 0) continue;
    values[line.slice(0, separator).trim()] = line.slice(separator + 1).trim();
  }
  if (!values.name) throw new HostError("SKILL_SOURCE_UNAVAILABLE", "SKILL.md name is required");
  if (values.name === "." || values.name === ".." || values.name.includes("/") || values.name.includes("\\")) {
    throw new HostError("SKILL_SOURCE_UNAVAILABLE", "invalid skill name");
  }
  return { name: values.name, description: values.description ?? "" };
}

/**
 * Content hash over the whole skill directory (relative path + size + bytes of
 * every file), not just `SKILL.md`. A change to a script or reference file must
 * yield a new immutable version directory instead of overwriting the one a
 * running turn may still be reading.
 */
async function hashDirectory(root: string): Promise<string> {
  const hash = createHash("sha256");
  async function visit(dir: string, prefix: string): Promise<void> {
    const entries = (await readdir(dir, { withFileTypes: true })).sort((left, right) =>
      left.name < right.name ? -1 : left.name > right.name ? 1 : 0
    );
    for (const entry of entries) {
      const childRelative = prefix ? `${prefix}/${entry.name}` : entry.name;
      const childPath = join(dir, entry.name);
      if (entry.isDirectory()) {
        hash.update(`d:${childRelative}\n`);
        await visit(childPath, childRelative);
      } else if (entry.isFile()) {
        const bytes = await readFile(childPath);
        hash.update(`f:${childRelative}:${bytes.length}\n`);
        hash.update(bytes);
      }
    }
  }
  await visit(root, "");
  return hash.digest("hex");
}

export class SkillRegistry {
  private readonly index: string;
  private readonly root: string;

  constructor(dataDir: string, private readonly allowedRoot: string, private readonly allowPrivateHosts = false) {
    this.index = join(dataDir, "skills", "index.json");
    this.root = join(dataDir, "skills", "versions");
  }

  private async load(): Promise<SkillFile> {
    const value = await readJsonFile<SkillFile>(this.index, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported skill registry");
    return value;
  }

  private async save(value: SkillFile): Promise<void> {
    await writeJsonFileAtomic(this.index, value, 0o600);
  }

  async list(): Promise<SkillRecord[]> {
    return (await this.load()).skills;
  }

  async get(id: string): Promise<{ skill: SkillRecord; instructions: string }> {
    const skill = (await this.load()).skills.find((entry) => entry.id === id);
    if (!skill) throw new HostError("NOT_FOUND", "skill not found");
    return { skill, instructions: await readFile(join(skill.path, "SKILL.md"), "utf8") };
  }

  private async sourceDir(source: SkillSource): Promise<{ path: string; temp?: string }> {
    if (source.type === "directory") {
      if (!source.path) throw new HostError("INVALID_ARGUMENT", "directory source requires path");
      const path = await realpath(resolve(source.path, source.subdir ?? ""));
      const allowed = await realpath(resolve(this.allowedRoot));
      const rel = relative(allowed, path);
      if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
        throw new HostError("INVALID_ARGUMENT", "skill directory escapes allowed root");
      }
      return { path };
    }
    if (!source.url) throw new HostError("INVALID_ARGUMENT", "git source requires url");
    await assertPublicHttpsEndpoint(source.url, { allowPrivateHosts: this.allowPrivateHosts });
    const temp = join(this.root, `.clone-${uuid()}`);
    await mkdir(temp, { recursive: true, mode: 0o700 });
    try {
      const args = ["clone", "--depth", "1"];
      if (source.ref && source.refType !== "commit") args.push("--branch", source.ref);
      args.push(source.url, temp);
      const { spawn } = await import("node:child_process");
      const code = await new Promise<number>((resolveCode, reject) => {
        const child = spawn("git", args, { stdio: "ignore" });
        child.on("error", reject);
        child.on("exit", (value) => resolveCode(value ?? 1));
      });
      if (code !== 0) {
        throw new HostError("SKILL_SOURCE_UNAVAILABLE", "git clone failed");
      }
      if (source.ref && source.refType === "commit") {
        const checkoutCode = await new Promise<number>((resolveCode, reject) => {
          const child = spawn("git", ["-C", temp, "checkout", source.ref!], { stdio: "ignore" });
          child.on("error", reject);
          child.on("exit", (value) => resolveCode(value ?? 1));
        });
        if (checkoutCode !== 0) {
          throw new HostError("SKILL_SOURCE_UNAVAILABLE", "git checkout failed");
        }
      }
      const path = await realpath(resolve(temp, source.subdir ?? ""));
      const rel = relative(await realpath(temp), path);
      if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
        throw new HostError("INVALID_ARGUMENT", "skill directory escapes source");
      }
      return { path, temp };
    } catch (error) {
      await rm(temp, { recursive: true, force: true });
      throw error;
    }
  }

  async install(
    source: SkillSource,
    replace = false,
    now = new Date(),
    updateSkillId?: string
  ): Promise<SkillRecord> {
    const { path: sourceDir, temp } = await this.sourceDir(source);
    try {
      const body = await readFile(join(sourceDir, "SKILL.md"), "utf8");
      const meta = frontmatter(body);
      const data = await this.load();
      const existing = updateSkillId
        ? data.skills.find((entry) => entry.id === updateSkillId)
        : data.skills.find((entry) => entry.name === meta.name);
      if (existing && !replace && !updateSkillId) {
        throw new HostError("SKILL_CONFLICT", "skill name already installed");
      }
      if (updateSkillId && existing && existing.name !== meta.name) {
        const conflict = data.skills.find((entry) => entry.name === meta.name && entry.id !== updateSkillId);
        if (conflict) throw new HostError("SKILL_CONFLICT", "new skill name already in use");
      }
      const version = (await hashDirectory(sourceDir)).slice(0, 16);
      const versionDir = join(this.root, meta.name, version);
      await mkdir(join(this.root, meta.name), { recursive: true, mode: 0o700 });
      const alreadyPublished = await stat(versionDir)
        .then(() => true)
        .catch(() => false);
      if (!alreadyPublished) {
        // Publish atomically: stage a full copy, then rename into place so a
        // concurrent reader never observes a half-written version directory.
        const staging = join(this.root, meta.name, `.staging-${uuid()}`);
        await cp(sourceDir, staging, { recursive: true });
        try {
          await rename(staging, versionDir);
        } catch (error) {
          // Clean up staging, then verify that versionDir actually exists (confirming a race win)
          await rm(staging, { recursive: true, force: true });
          const exists = await stat(versionDir).then(() => true).catch(() => false);
          if (!exists) throw error;
        }
      }
      const record: SkillRecord = {
        id: existing?.id ?? uuid(),
        name: meta.name,
        description: meta.description,
        source,
        installedAt: existing?.installedAt ?? now.toISOString(),
        updatedAt: now.toISOString(),
        status: "ready",
        path: versionDir,
        version
      };
      data.skills = data.skills.filter((entry) => entry.id !== record.id && entry.name !== meta.name);
      data.skills.push(record);
      await this.save(data);
      return record;
    } finally {
      if (temp) await rm(temp, { recursive: true, force: true });
    }
  }

  async update(id: string, source: SkillSource, now = new Date()): Promise<SkillRecord> {
    const existing = (await this.load()).skills.find((entry) => entry.id === id);
    if (!existing) throw new HostError("NOT_FOUND", "skill not found");
    return this.install(source, true, now, id);
  }

  async delete(id: string): Promise<boolean> {
    const data = await this.load();
    const index = data.skills.findIndex((entry) => entry.id === id);
    if (index < 0) throw new HostError("NOT_FOUND", "skill not found");
    const [skill] = data.skills.splice(index, 1);
    await this.save(data);
    if (skill) await rm(join(this.root, skill.name), { recursive: true, force: true });
    return true;
  }
}
