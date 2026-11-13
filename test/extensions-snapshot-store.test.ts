import { mkdtemp, readFile, writeFile, stat, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { ExtensionSnapshotStore } from "../src/extensions/snapshot-store.js";
import { diagnostic, type ExtensionSnapshot } from "../src/extensions/types.js";
const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
function snapshot(id = "a", revision = 1, phase: ExtensionSnapshot["phase"] = "loading"): ExtensionSnapshot { return { id, hostId: "host", sessionId: "session", turnId: id, configRevision: "config", revision, startedAt: new Date().toISOString(), completedAt: phase === "loading" ? null : new Date().toISOString(), phase, entries: [], diagnostics: [] }; }
async function setup() { const root = await mkdtemp(join(tmpdir(), "pi-extension-snapshots-")); roots.push(root); return new ExtensionSnapshotStore(root); }
describe("extensions snapshot store", () => {
  it("keeps two attempts, ignores stale revisions/old callbacks, and writes atomically with 0600 permissions", async () => {
    const store = await setup(); expect(await store.get("session")).toEqual({ latestAttempt: null, previousCompleted: null });
    await store.put(snapshot()); await store.put(snapshot("a", 2, "ready")); await store.put(snapshot("b"));
    expect(await store.put(snapshot("a", 3, "ready"))).toBeNull();
    await store.put(snapshot("b", 2, "failed")); expect(await store.put(snapshot("b", 1))).toBeNull();
    const pair = await store.get("session"); expect(pair.latestAttempt?.id).toBe("b"); expect(pair.previousCompleted?.id).toBe("a");
    expect((await stat(store.path("session"))).mode & 0o777).toBe(0o600);
    expect(store.path("../../escape")).toMatch(/extensions\/[a-f0-9]{64}\.json$/);
  });
  it("recovers unfinished loading across restart, removes orphans and deletes session results", async () => {
    const store = await setup(); await store.put(snapshot()); await store.put({ ...snapshot("orphan"), sessionId: "deleted" });
    await store.recover(new Set(["session"]));
    const latest = (await store.get("session")).latestAttempt!;
    expect(latest).toMatchObject({ phase: "failed", revision: 2, diagnostics: [expect.objectContaining({ code: "AGENT_RESTARTED" })] });
    expect(latest.completedAt).not.toBeNull(); expect((await store.get("deleted")).latestAttempt).toBeNull();
    await store.delete("session"); expect((await store.get("session")).latestAttempt).toBeNull();
  });
  it("does not silently turn malformed or structurally corrupt files into empty history", async () => {
    const store = await setup(); await store.put(snapshot());
    await writeFile(store.path("session"), "{broken"); await expect(store.get("session")).rejects.toMatchObject({ code: "INTERNAL" });
    await writeFile(store.path("session"), JSON.stringify({ version: 1, sessionId: "session", latestAttempt: { id: "x" }, previousCompleted: null }));
    await expect(store.get("session")).rejects.toMatchObject({ code: "INTERNAL" });
  });
  it("bounds diagnostics, tool names and the whole snapshot with explicit truncation", async () => {
    const store = await setup(), value = snapshot("large", 1, "ready");
    value.entries = Array.from({ length: 100 }, (_, index) => ({ id: String(index), name: "fixture", configuredVersion: null, loadState: "loaded", skipReason: null, registeredTools: Array.from({ length: 201 }, (_, n) => `${n}${"x".repeat(256)}`), activeTools: [], registeredCommands: [], mobileInvocable: false, diagnostics: Array.from({ length: 30 }, () => diagnostic("load", "FIXTURE", "x".repeat(2000))) }));
    await store.put(value); const pair = await store.get("session");
    expect(Buffer.byteLength(JSON.stringify(pair.latestAttempt))).toBeLessThanOrEqual(256 * 1024);
    expect(pair.latestAttempt!.diagnostics.some(item => item.code === "SNAPSHOT_TRUNCATED")).toBe(true);
    for (const entry of pair.latestAttempt!.entries) { expect(entry.diagnostics.length).toBeLessThanOrEqual(20); expect(entry.registeredTools.length).toBeLessThanOrEqual(200); }
    expect((await readFile(store.path("session"), "utf8")).length).toBeGreaterThan(0);
  });
  it("bounds the actual pretty-printed sidecar and rejects unexpected stored fields", async () => {
    const store = await setup(), value = snapshot("short-names", 1, "ready");
    value.entries = Array.from({ length: 100 }, (_, n) => ({ id: String(n), name: "fixture", configuredVersion: null, loadState: "loaded", skipReason: null, registeredTools: Array.from({ length: 200 }, (_, m) => String(m)), activeTools: [], registeredCommands: [], mobileInvocable: false, diagnostics: [] }));
    await store.put(value);
    await store.put({ ...value, id: "second", turnId: "second" });
    expect((await stat(store.path("session"))).size).toBeLessThan(600 * 1024);
    expect((await store.get("session")).previousCompleted?.id).toBe("short-names");
    const raw = JSON.parse(await readFile(store.path("session"), "utf8"));
    raw.latestAttempt.stack = "untrusted secret";
    await writeFile(store.path("session"), JSON.stringify(raw));
    await expect(store.get("session")).rejects.toMatchObject({ code: "INTERNAL" });
  });
});
