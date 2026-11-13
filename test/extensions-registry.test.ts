import { mkdtemp, mkdir, writeFile, symlink, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ExtensionRegistry, parseExtensionsConfig } from "../src/extensions/registry.js";
const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
describe("extensions registry", () => {
  it("never imports during inventory/prepare, filters adaptation and enabled flags, and diagnoses canonical duplicates", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-extensions-registry-")); roots.push(root);
    const entry = join(root, "entry.ts"), link = join(root, "link.ts"), dir = join(root, "directory.ts");
    await writeFile(entry, 'throw new Error("must never import")'); await symlink(entry, link); await mkdir(dir);
    const config = parseExtensionsConfig({ enabled: true, entries: [
      { id: "unknown", entryPath: entry }, { id: "duplicate", entryPath: link, compatibility: "headless-reviewed" },
      { id: "missing", entryPath: join(root, "missing.js"), compatibility: "headless-reviewed" }, { id: "dir", entryPath: dir },
      { id: "disabled", entryPath: join(root, "disabled.ts"), enabled: false }, { id: "ui", entryPath: join(root, "ui.ts"), compatibility: "requires-ui" }
    ] });
    const registry = new ExtensionRegistry(config), inventory = await registry.inventory("host");
    expect(inventory.entries.map(entry => entry.entryState)).toEqual(["valid", "duplicate", "missing", "unreadable", "missing", "missing"]);
    const prepared = await registry.prepare(); expect(prepared.paths.size).toBe(0);
    expect(prepared.entries.map(entry => entry.skipReason)).toEqual(["not-adapted", null, null, "not-adapted", "entry-disabled", "not-adapted"]);
    expect(prepared.entries[1]!.diagnostics[0]!.code).toBe("DUPLICATE_ENTRY");
    expect(new ExtensionRegistry(config).configRevision).toBe(registry.configRevision);
    config.enabled = false; expect(registry.config.enabled).toBe(true);
  });
  it("loads only enabled reviewed valid entries and defaults disabled at host level", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-extensions-reviewed-")); roots.push(root);
    const entry = join(root, "entry.mjs"); await writeFile(entry, 'throw new Error("not imported")');
    const raw = { entries: [{ id: "reviewed", entryPath: entry, compatibility: "headless-reviewed" }] };
    expect((await new ExtensionRegistry(parseExtensionsConfig(raw)).prepare()).entries[0]!.skipReason).toBe("host-disabled");
    expect([...(await new ExtensionRegistry(parseExtensionsConfig({ ...raw, enabled: true })).prepare()).paths.values()]).toEqual([await realpath(entry)]);
  });
  it.each(["https://example.com/x.ts", "npm:pkg", "git:repo", "./entry.ts", "/tmp/*.ts", "/tmp/entry.json"])("rejects non-local-file source %s", entryPath => {
    expect(() => parseExtensionsConfig({ entries: [{ id: "x", entryPath }] })).toThrow();
  });
  it("requires restart after entry replacement or repairing an entry missing at startup", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-extensions-restart-")); roots.push(root);
    const entryPath = join(root, "entry.ts");
    const config = parseExtensionsConfig({ enabled: true, entries: [{ id: "fixture", entryPath, compatibility: "headless-reviewed" }] });
    const missingAtStartup = new ExtensionRegistry(config); await missingAtStartup.initialize();
    await writeFile(entryPath, "export default () => {};");
    expect((await missingAtStartup.prepare()).entries[0]!.diagnostics[0]!.code).toBe("ENTRY_CHANGED_RESTART_REQUIRED");
    const running = new ExtensionRegistry(config); await running.initialize();
    await writeFile(entryPath, "export default () => { throw new Error('new code'); };");
    expect((await running.prepare()).paths.size).toBe(0);
    expect((await running.inventory("host")).entries[0]!.diagnostics[0]!.code).toBe("ENTRY_CHANGED_RESTART_REQUIRED");
    expect((await new ExtensionRegistry(config).prepare()).paths.size).toBe(1);
  });
});
