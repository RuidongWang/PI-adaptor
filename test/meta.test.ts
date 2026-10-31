import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { MetaStore } from "../src/meta/store.js";

describe("metadata store", () => {
  it("preserves concurrent registrations and isolates empty stores", async () => {
    const store = new MetaStore(await mkdtemp(join(tmpdir(), "pi-host-meta-race-")));
    await Promise.all(Array.from({ length: 10 }, (_, i) => store.registerProject(`/tmp/p${i}`, `p${i}`)));
    expect(await store.listProjects()).toHaveLength(10);
    const other = new MetaStore(await mkdtemp(join(tmpdir(), "pi-host-meta-empty-")));
    expect(await other.listProjects()).toEqual([]);
  });
  it("registers projects idempotently and preserves tombstones", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-meta-"));
    const store = new MetaStore(root);
    const first = await store.registerProject("/tmp/project", "One");
    const second = await store.registerProject("/tmp/project", "Renamed");
    expect(second.id).toBe(first.id);
    expect(second.label).toBe("Renamed");
    await store.deleteProject(first.id);
    expect(await store.listProjects()).toHaveLength(0);
    const restored = await store.registerProject("/tmp/project", "Restored");
    expect(restored.id).not.toBe(first.id);
  });

  it("archives sessions and keeps deleted sessions hidden", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-meta-"));
    const store = new MetaStore(root);
    const now = "2026-01-01T00:00:00.000Z";
    await store.upsertSession({
      id: "s1",
      title: "Session",
      projectId: null,
      projectPath: "/tmp",
      mode: "agent",
      permissionMode: "ask",
      providerId: null,
      modelId: null,
      thinkingLevel: null,
      revision: 1,
      archived: false,
      createdAt: now,
      updatedAt: now
    });
    expect(await store.listSessions(false)).toHaveLength(1);
    await store.updateSession("s1", { archived: true });
    expect(await store.listSessions(false)).toHaveLength(0);
    await store.deleteSession("s1");
    expect(await store.listSessions(true)).toHaveLength(0);
  });
});
