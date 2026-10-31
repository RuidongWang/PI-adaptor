import { chmod, mkdir, mkdtemp, readdir, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
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
      const registry = new SkillRegistry(join(root, "data"), root, true);
      await registry.install({ type: "git", url: "https://example.com/repo" });
      await expect(registry.install({ type: "git", url: "https://example.com/repo", subdir: "missing" })).rejects.toThrow();
      expect((await readdir(join(root, "data", "skills", "versions"))).filter((name) => name.startsWith(".clone-"))).toEqual([]);
    } finally {
      process.env.PATH = originalPath;
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
    expect(await registry.delete(first.id)).toBe(true);
    expect(await registry.list()).toHaveLength(0);
  });
});
