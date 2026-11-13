import { rm, writeFile } from "node:fs/promises";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import { HostService } from "../src/server/host-service.js";
import type { SnapshotPair } from "../src/extensions/types.js";
import { hostFixture, SnapshotDriver, snapshotFor } from "./fixtures/extensions/host-fixture.js";
const roots: string[] = [];
afterEach(async () => { for (const root of roots.splice(0)) await rm(root, { recursive: true, force: true }); });
async function setup(driver = new SnapshotDriver()) { const fixture = await hostFixture(driver); roots.push(fixture.root); return { ...fixture, driver }; }
describe("extensions API", () => {
  it("advertises both protocol versions, requires authentication, and returns authoritative null without mutating revision/journal", async () => {
    const { service, auth, sessionId } = await setup();
    for (const protocolVersion of ["1.0", "2.0.0"]) expect((await service.initialize({ protocolVersion })).capabilities).toMatchObject({ extensionInventory: true, sessionExtensions: true, extensionManagement: false, extensionUI: false });
    await expect(service.handle("extension/list", {}, null)).rejects.toMatchObject({ code: "UNAUTHORIZED" });
    const before = await service.meta.getSession(sessionId), cursor = service.journal.currentCursor();
    expect(await service.handle("extension/list", {}, auth)).toMatchObject({ userLoadingEnabled: false, entries: [] });
    expect(await service.handle("session/extensions", { sessionId }, auth)).toMatchObject({ runningTurnId: null, latestAttempt: null, previousCompleted: null });
    expect(await service.meta.getSession(sessionId)).toEqual(before); expect(service.journal.currentCursor()).toEqual(cursor);
  });
  it.each([["extension/list", { cwd: "/tmp" }], ["session/extensions", {}], ["session/extensions", { sessionId: 1 }], ["session/extensions", { sessionId: "s", context: {} }]])("rejects malformed read-only request %s %#", async (method, params) => {
    const { service, auth } = await setup(); await expect(service.handle(method as string, params, auth)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  });
  it("returns NOT_FOUND for missing sessions and sanitized INTERNAL for corrupt history", async () => {
    const { service, auth, sessionId } = await setup();
    await expect(service.handle("session/extensions", { sessionId: "absent" }, auth)).rejects.toMatchObject({ code: "NOT_FOUND" });
    await writeFile(service.extensionSnapshots.path(sessionId), "{apiKey=supersecret");
    await expect(service.handle("session/extensions", { sessionId }, auth)).rejects.toMatchObject({ code: "INTERNAL", message: "Extension snapshot is unreadable or corrupt." });
  });
  it("orders direct Snapshot events with original turn events, retains history, and rejects late old callbacks", async () => {
    const { service, auth, sessionId, driver } = await setup();
    for (let n = 0; n < 2; n += 1) {
      await service.handle("turn/start", { sessionId, input: { text: "fixture" } }, auth);
      await vi.waitFor(() => expect(service["executingDrivers"].size).toBe(0));
    }
    const result = await service.handle("session/extensions", { sessionId }, auth) as SnapshotPair;
    expect(result.latestAttempt?.turnId).toBe(driver.requests[1]!.turnId); expect(result.previousCompleted?.turnId).toBe(driver.requests[0]!.turnId);
    await driver.requests[0]!.extensions!.publish(snapshotFor(driver.requests[0]!, "failed", 99));
    expect(await service.extensionSnapshots.get(sessionId)).toEqual(result.latestAttempt ? { latestAttempt: result.latestAttempt, previousCompleted: result.previousCompleted } : null);
    const events = service.journal.replay("session", sessionId, { epoch: service.journal.epoch, sequence: 0 });
    const extensionEvents = events.filter(event => event.kind === "session.extensions.updated"); expect(extensionEvents).toHaveLength(4);
    expect(extensionEvents[0]!.payload).toMatchObject({ phase: "loading", revision: 1 }); expect(extensionEvents[0]!.payload).not.toHaveProperty("snapshot");
    expect(events.map(event => event.sequence)).toEqual(events.map(event => event.sequence).sort((a, b) => a! - b!));
    expect(events.findIndex(event => event.kind === "session.extensions.updated")).toBeLessThan(events.findIndex(event => event.kind === "turn.completed"));
  });
  it("does not start the next queued round until the previous handle finishes cleanup", async () => {
    const driver = new SnapshotDriver(true), { service, auth, sessionId } = await setup(driver);
    await service.handle("turn/start", { sessionId, input: { text: "one" } }, auth);
    await vi.waitFor(() => expect(service["turns"].get(driver.requests[0]!.turnId)?.status).toBe("completed"));
    await service.handle("turn/start", { sessionId, admission: "queue", input: { text: "two" } }, auth);
    expect(driver.requests).toHaveLength(1);
    driver.release[0]!(); await vi.waitFor(() => expect(driver.requests).toHaveLength(2));
    driver.release[1]!(); await vi.waitFor(() => expect(service["executingDrivers"].size).toBe(0));
  });
  it("recovers loading after process restart and deletes results with session and project", async () => {
    const { service, auth, sessionId, projectId, config } = await setup();
    const now = new Date().toISOString();
    await service.extensionSnapshots.put({ id: "incomplete", hostId: service.hostId, sessionId, turnId: "old", configRevision: "old-config", revision: 1, startedAt: now, completedAt: null, phase: "loading", entries: [], diagnostics: [] });
    const restarted = new HostService(config, new DeterministicAgentDriver()); await restarted.init();
    expect((await restarted.extensionSnapshots.get(sessionId)).latestAttempt).toMatchObject({ phase: "failed", configRevision: "old-config" });
    await restarted.handle("session/delete", { sessionId, confirmSessionId: sessionId }, auth);
    expect((await restarted.extensionSnapshots.get(sessionId)).latestAttempt).toBeNull();
    const next = await restarted.handle("session/create", { projectId }, auth) as { session: { id: string } };
    await restarted.extensionSnapshots.put({ id: "done", hostId: restarted.hostId, sessionId: next.session.id, turnId: "t", configRevision: "old-config", revision: 1, startedAt: now, completedAt: now, phase: "ready", entries: [], diagnostics: [] });
    await restarted.handle("project/delete", { projectId, confirmProjectId: projectId }, auth);
    expect((await restarted.extensionSnapshots.get(next.session.id)).latestAttempt).toBeNull();
  });
  it("does not copy extension snapshots when branching native session history", async () => {
    const { service, auth, sessionId } = await setup();
    await service.handle("turn/start", { sessionId, input: { text: "branch fixture" } }, auth);
    await vi.waitFor(() => expect(service["executingDrivers"].size).toBe(0));
    const session = (await service.meta.getSession(sessionId))!;
    const item = (await service.catalog.history(session.nativePath!)).find(entry => entry.type === "message")!;
    const branched = await service.handle("session/branch", { sessionId, fromItemId: item.id }, auth) as { session: { id: string } };
    expect(branched.session.id).not.toBe(sessionId);
    expect(await service.handle("session/extensions", { sessionId: branched.session.id }, auth)).toMatchObject({ latestAttempt: null, previousCompleted: null });
  });
  it("serializes snapshot deletion against concurrent turn admission", async () => {
    const { service, auth, sessionId, driver } = await setup();
    let release!: () => void, entered = false;
    const gate = new Promise<void>(resolve => { release = resolve; });
    const original = service.extensionSnapshots.delete.bind(service.extensionSnapshots);
    vi.spyOn(service.extensionSnapshots, "delete").mockImplementation(async id => { entered = true; await gate; await original(id); });
    const deletion = service.handle("session/delete", { sessionId, confirmSessionId: sessionId }, auth);
    await vi.waitFor(() => expect(entered).toBe(true));
    const start = expect(service.handle("turn/start", { sessionId, input: { text: "late" } }, auth)).rejects.toMatchObject({ code: "NOT_FOUND" });
    release(); await deletion; await start;
    expect(driver.requests).toHaveLength(0);
    expect((await service.extensionSnapshots.get(sessionId)).latestAttempt).toBeNull();
  });
  it("blocks new work and waits for outstanding cleanup on host shutdown", async () => {
    const driver = new SnapshotDriver(true), { service, auth, sessionId } = await setup(driver);
    await service.handle("turn/start", { sessionId, input: { text: "cleanup" } }, auth);
    await vi.waitFor(() => expect(service["turns"].get(driver.requests[0]!.turnId)?.status).toBe("completed"));
    await service.shutdown();
    expect(service["executingDrivers"].size).toBe(0);
    await expect(service.handle("turn/start", { sessionId, input: { text: "after shutdown" } }, auth)).rejects.toMatchObject({ code: "CAPABILITY_UNAVAILABLE" });
  });
  it("releases the execution slot if driver construction throws synchronously", async () => {
    class FailingStartDriver extends SnapshotDriver {
      failed = false;
      override start(request: Parameters<SnapshotDriver["start"]>[0]) {
        if (!this.failed) { this.failed = true; throw new Error("injected driver start failure"); }
        return super.start(request);
      }
    }
    const { service, auth, sessionId } = await setup(new FailingStartDriver());
    await expect(service.handle("turn/start", { sessionId, input: { text: "fail" } }, auth)).rejects.toThrow("injected driver start failure");
    expect(service["executingDrivers"].size).toBe(0);
    await service.handle("turn/start", { sessionId, input: { text: "retry" } }, auth);
    await vi.waitFor(() => expect(service["executingDrivers"].size).toBe(0));
    expect((await service.extensionSnapshots.get(sessionId)).latestAttempt?.phase).toBe("ready");
  });
});
