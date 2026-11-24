import { cp, lstat, mkdir, readFile, readdir, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { isAbsolute, join, relative, resolve, sep } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";
import { uuid } from "../util/id.js";
import { endpointHostname, parseEndpoint, resolveEndpointAddresses } from "../security/endpoint.js";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { KeyedMutex } from "../util/keyed-mutex.js";

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
 * Reject any symbolic link inside a skill source tree. A symlink is followed by
 * readFile/cp, so a link inside an allowed directory could otherwise read files
 * outside that directory under the Host's privileges.
 */
async function assertNoSymlinks(root: string, prefix = ""): Promise<void> {
  const entries = await readdir(root, { withFileTypes: true });
  for (const entry of entries) {
    const childRelative = prefix ? `${prefix}/${entry.name}` : entry.name;
    const childPath = join(root, entry.name);
    const info = await lstat(childPath);
    if (info.isSymbolicLink()) {
      throw new HostError("SKILL_SOURCE_UNAVAILABLE", `skill source contains a symbolic link: ${childRelative}`);
    }
    if (info.isDirectory()) {
      await assertNoSymlinks(childPath, childRelative);
    }
  }
}

const MAX_SKILL_FILES = 5_000;
const MAX_SKILL_BYTES = 200 * 1024 * 1024;
const MAX_SKILL_DEPTH = 20;
const MAX_SKILL_FILE_BYTES = 50 * 1024 * 1024;
const GIT_TIMEOUT_MS = 120_000;

/** Bound the resources a skill source may consume before hashing/copying it. */
async function assertWithinResourceLimits(root: string): Promise<void> {
  let files = 0;
  let bytes = 0;
  async function visit(dir: string, depth: number): Promise<void> {
    if (depth > MAX_SKILL_DEPTH) {
      throw new HostError("SKILL_SOURCE_UNAVAILABLE", "skill source directory is too deep");
    }
    for (const entry of await readdir(dir, { withFileTypes: true })) {
      const childPath = join(dir, entry.name);
      const info = await lstat(childPath);
      if (info.isSymbolicLink()) continue; // already rejected by assertNoSymlinks
      if (info.isDirectory()) {
        await visit(childPath, depth + 1);
      } else if (info.isFile()) {
        files += 1;
        if (files > MAX_SKILL_FILES) throw new HostError("SKILL_SOURCE_UNAVAILABLE", "skill source has too many files");
        if (info.size > MAX_SKILL_FILE_BYTES) throw new HostError("SKILL_SOURCE_UNAVAILABLE", "skill source file is too large");
        bytes += info.size;
        if (bytes > MAX_SKILL_BYTES) throw new HostError("SKILL_SOURCE_UNAVAILABLE", "skill source is too large");
      }
    }
  }
  await visit(root, 0);
}

const execFileAsync = promisify(execFile);

async function runGit(args: string[], failure: string, networkDir?: string): Promise<string> {
  try {
    const { stdout } = await execFileAsync("git", args, {
      timeout: GIT_TIMEOUT_MS,
      killSignal: "SIGKILL",
      ...(networkDir ? {
        cwd: networkDir,
        env: {
          ...process.env,
          GIT_CONFIG_NOSYSTEM: "1",
          GIT_CONFIG_GLOBAL: "/dev/null",
          GIT_TERMINAL_PROMPT: "0",
          NO_PROXY: "*",
          no_proxy: "*"
        }
      } : {})
    });
    return stdout.trim();
  } catch (error) {
    if ((error as { killed?: boolean }).killed) {
      throw new HostError("SKILL_SOURCE_UNAVAILABLE", "git operation timed out");
    }
    throw new HostError("SKILL_SOURCE_UNAVAILABLE", failure);
  }
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
  /// Serialises the read-modify-write of the whole index (install/update/
  /// delete). Atomic rename alone does not make concurrent read-modify-write
  /// transactions safe.
  private readonly indexMutex = new KeyedMutex();

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

  async activeSkills(): Promise<Array<{ name: string; filePath: string }>> {
    return (await this.list()).map((skill) => ({ name: skill.name, filePath: join(skill.path, "SKILL.md") }));
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
      await assertNoSymlinks(path);
      return { path };
    }
    if (!source.url) throw new HostError("INVALID_ARGUMENT", "git source requires url");
    const policy = { allowPrivateHosts: this.allowPrivateHosts, allowLoopback: false };
    const url = parseEndpoint(source.url, policy);
    const hostname = endpointHostname(url);
    const addresses = await resolveEndpointAddresses(hostname, policy);
    const temp = join(this.root, `.clone-${uuid()}`);
    await mkdir(temp, { recursive: true, mode: 0o700 });
    try {
      // Refuse HTTP redirects: the initial URL passed the SSRF policy, but a
      // redirect could point at a private destination the policy never saw.
      const pinnedAddresses = addresses.map(({ address, family }) => family === 6 ? `[${address}]` : address).join(",");
      const remoteOptions = ["-c", "http.followRedirects=false", "-c", "http.proxy="];
      if (!addresses.some(({ address }) => address === hostname)) {
        if (!this.allowPrivateHosts) {
          const settings = await runGit(["help", "--config"], "git configuration inspection failed", temp);
          if (!settings.split("\n").includes("http.curloptResolve")) {
            throw new HostError("SKILL_SOURCE_UNAVAILABLE", "git must support pinned HTTPS address resolution");
          }
        }
        remoteOptions.push("-c", `http.curloptResolve=${hostname}:${url.port || "443"}:${pinnedAddresses}`);
      }
      if (source.refType === "commit") {
        const commit = typeof source.ref === "string" ? source.ref.toLowerCase() : "";
        if (!/^(?:[0-9a-f]{40}|[0-9a-f]{64})$/.test(commit)) {
          throw new HostError("INVALID_ARGUMENT", "git commit source requires a full commit hash");
        }
        const objectFormat = commit.length === 40 ? "sha1" : "sha256";
        await runGit(["-C", temp, "init", `--object-format=${objectFormat}`], "git init failed");
        await runGit([...remoteOptions, "-C", temp, "fetch", "--depth", "1", "--", url.href, commit], "git fetch failed", temp);
        await runGit(["-C", temp, "checkout", "--detach", "FETCH_HEAD"], "git checkout failed");
        const actual = await runGit(["-C", temp, "rev-parse", "--verify", "HEAD"], "git commit verification failed");
        if (actual !== commit) {
          throw new HostError("SKILL_SOURCE_UNAVAILABLE", "git checkout did not match the requested commit");
        }
      } else {
        const args = [...remoteOptions, "clone", "--depth", "1"];
        if (source.ref) args.push("--branch", source.ref);
        await runGit([...args, "--", url.href, temp], "git clone failed", temp);
      }
      await rm(join(temp, ".git"), { recursive: true, force: true });
      const path = await realpath(resolve(temp, source.subdir ?? ""));
      const rel = relative(await realpath(temp), path);
      if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
        throw new HostError("INVALID_ARGUMENT", "skill directory escapes source");
      }
      await assertNoSymlinks(path);
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
    return this.indexMutex.run("index", () => this.installLocked(source, replace, now, updateSkillId));
  }

  private async installLocked(
    source: SkillSource,
    replace: boolean,
    now: Date,
    updateSkillId?: string
  ): Promise<SkillRecord> {
    const { path: sourceDir, temp } = await this.sourceDir(source);
    try {
      await assertWithinResourceLimits(sourceDir);
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
    return this.indexMutex.run("index", async () => {
      const existing = (await this.load()).skills.find((entry) => entry.id === id);
      if (!existing) throw new HostError("NOT_FOUND", "skill not found");
      return this.installLocked(source, true, now, id);
    });
  }

  async delete(id: string): Promise<boolean> {
    return this.indexMutex.run("index", async () => {
      const data = await this.load();
      const index = data.skills.findIndex((entry) => entry.id === id);
      if (index < 0) throw new HostError("NOT_FOUND", "skill not found");
      data.skills.splice(index, 1);
      await this.save(data);
      // An active turn may still read auxiliary files from this immutable version.
      return true;
    });
  }
}
