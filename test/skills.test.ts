import { chmod, mkdir, mkdtemp, readdir, rm, symlink, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { DefaultResourceLoader, SettingsManager } from "@earendil-works/pi-coding-agent";
import { SkillRegistry } from "../src/skills/registry.js";

describe("skill registry", () => {
  it("cleans cloned directories after success and failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-skill-clone-"));
    const bin = join(root, "bin");
    await mkdir(bin);
    await writeFile(join(bin, "git"), "#!/bin/bash\ntarget=\"${@: -1}\"\nprintf '%s\\n' '---' 'name: demo' '---' > \"$target/SKILL.md\"\n");
    await chmod(join(bin, "git"), 0o755);
    const originalPath = process.env.PATH;
    process.env.PATH = `${bin}:${originalPath}`;
    try {
      const registry = new SkillRegistry(join(root, "data"), root);
      const source = { type: "git", url: "https://93.184.216.34/skills" } as const;
      await registry.install(source);
      await expect(registry.install({ ...source, subdir: "missing" })).rejects.toThrow();
      expect((await readdir(join(root, "data", "skills", "versions"))).filter((name) => name.startsWith(".clone-"))).toEqual([]);
    } finally {
      if (originalPath === undefined) delete process.env.PATH;
      else process.env.PATH = originalPath;
      await rm(root, { recursive: true, force: true });
    }
  });
  it("installs an older pinned commit without fetching the default branch", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-skill-pin-"));
    const originalPath = process.env.PATH;
    const originalRepo = process.env.PI_TEST_SKILL_GIT_REPO;
    const git = process.platform === "darwin" ? "/usr/bin/arch" : "/usr/bin/git";
    const gitArgs = process.platform === "darwin" ? ["-arm64", "/usr/bin/git"] : [];
    const repo = join(root, "repo");
    const remote = "https://93.184.216.34/skills";
    const run = (...args: string[]) => execFileSync(git, [...gitArgs, "-C", repo, ...args], { encoding: "utf8" }).trim();
    try {
      await mkdir(repo);
      run("init", "-q", "--object-format=sha1");
      await writeFile(join(repo, "SKILL.md"), "---\nname: pinned\n---\n# Older\n");
      run("add", "SKILL.md");
      run("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "-qm", "older");
      const commit = run("rev-parse", "HEAD");
      await writeFile(join(repo, "SKILL.md"), "---\nname: pinned\n---\n# Latest\n");
      run("-c", "user.name=Fixture", "-c", "user.email=fixture@example.org", "commit", "-qam", "latest");
      run("config", "uploadpack.allowReachableSHA1InWant", "true");

      const bin = join(root, "bin");
      await mkdir(bin);
      // Redirect only this fixture's fetch to a local repository. file:// keeps
      // the shallow-fetch semantics instead of copying the local object store.
      await writeFile(join(bin, "git"), `#!/bin/bash
case " $* " in *" clone "*) exit 1 ;; esac
args=()
for arg in "$@"; do
  if [ "$arg" = '${remote}' ]; then arg="file://$PI_TEST_SKILL_GIT_REPO"; fi
  args+=("$arg")
done
exec ${git} ${gitArgs.join(" ")} "\${args[@]}"
`);
      await chmod(join(bin, "git"), 0o755);
      process.env.PATH = `${bin}:${originalPath}`;
      process.env.PI_TEST_SKILL_GIT_REPO = repo;

      const registry = new SkillRegistry(join(root, "data"), root);
      const source = { type: "git", url: remote, ref: commit, refType: "commit" } as const;
      const installed = await registry.install(source);
      expect((await registry.get(installed.id)).instructions).toContain("# Older");
      expect(await readdir(installed.path)).toEqual(["SKILL.md"]);
      await expect(registry.install({ ...source, ref: "main" })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    } finally {
      if (originalPath === undefined) delete process.env.PATH;
      else process.env.PATH = originalPath;
      if (originalRepo === undefined) delete process.env.PI_TEST_SKILL_GIT_REPO;
      else process.env.PI_TEST_SKILL_GIT_REPO = originalRepo;
      await rm(root, { recursive: true, force: true });
    }
  });
  it("rejects traversal names and source directories outside the allowed root", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-skill-safe-"));
    const source = join(root, "source");
    const outside = await mkdtemp(join(tmpdir(), "pi-adaptor-outside-"));
    await mkdir(source);
    await writeFile(join(source, "SKILL.md"), "---\nname: ../../escape\n---\n");
    const registry = new SkillRegistry(join(root, "data"), root, true);
    await expect(registry.install({ type: "directory", path: source })).rejects.toMatchObject({ code: "SKILL_SOURCE_UNAVAILABLE" });
    await symlink(outside, join(source, "link"));
    await expect(registry.install({ type: "directory", path: source, subdir: "link" })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  });
  it("installs immutable directory versions, updates, and deletes", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-skill-"));
    const source = join(root, "source");
    await mkdir(source, { recursive: true });
    await writeFile(join(source, "SKILL.md"), "---\nname: demo\ndescription: one\n---\n# One\n");
    const registry = new SkillRegistry(join(root, "data"), root, true);
    const first = await registry.install({ type: "directory", path: source });
    expect(first.name).toBe("demo");
    expect((await registry.get(first.id)).instructions).toContain("# One");
    await writeFile(join(source, "SKILL.md"), "---\nname: demo\ndescription: two\n---\n# Two\n");
    const second = await registry.update(first.id, { type: "directory", path: source });
    expect(second.version).not.toBe(first.version);
    expect((await registry.get(first.id)).instructions).toContain("# Two");
    const active = (await registry.activeSkills()).map((skill) => skill.filePath);
    const loader = new DefaultResourceLoader({ cwd: root, agentDir: join(root, "agent"), settingsManager: SettingsManager.inMemory({}), noExtensions: true, noSkills: true, additionalSkillPaths: active });
    await loader.reload();
    expect(loader.getSkills().skills.map((skill) => skill.filePath)).toEqual(active);
    expect(active[0]).toContain(second.version);
    expect(await registry.delete(first.id)).toBe(true);
    expect(await registry.list()).toHaveLength(0);
    expect(await registry.activeSkills()).toEqual([]);
    expect((await readdir(first.path)).includes("SKILL.md")).toBe(true);
  });
});
