import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import type { AgentDriver, AgentTurnHandle, AgentTurnRequest } from "../src/agent/driver.js";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
import { HostService } from "../src/server/host-service.js";
import { EventJournal } from "../src/events/journal.js";
import { SkillRegistry } from "../src/skills/registry.js";
import type { AuthContext } from "../src/server/host-service.js";

/** A driver whose turns stay running until aborted, so busy/queue paths are testable. */
class ControlledDriver implements AgentDriver {
  readonly appendsPrompt = true;
  aborted = new Set<string>();
  start(request: AgentTurnRequest): AgentTurnHandle {
    let resolveWait!: () => void;
    const wait = new Promise<void>((resolve) => {
      resolveWait = resolve;
    });
    queueMicrotask(() => request.onEvent({ kind: "turn.started", payload: { turnId: request.turnId } }));
    return {
      turnId: request.turnId,
      async abort() {
        resolveWait();
      },
      wait: () => wait
    };
  }
}

async function setup(driver: AgentDriver) {
  const root = await mkdtemp(join(tmpdir(), "pi-host-hardening-"));
  const project = join(root, "project");
  await mkdir(project, { recursive: true });
  const config = parseHostConfig(
    ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
    {},
    root
  );
  await ensureHostDirectories(config);
  const service = new HostService(config, driver);
  await service.init();
  const pairing = await service.createPairingToken();
  const paired = await service.pair({ deviceLabel: "test" }, pairing.token);
  const auth: AuthContext = {
    device: {
      deviceId: paired.deviceId,
      label: "test",
      role: "owner",
      tokenHash: "test-hash",
      createdAt: new Date().toISOString(),
      lastUsedAt: new Date().toISOString(),
      revokedAt: null
    }
  };
  const projectRecord = await service.meta.registerProject(project, "project");
  const session = (await service.handle("session/create", { projectId: projectRecord.id }, auth)) as {
    session: { id: string };
  };
  return { root, config, service, auth, sessionId: session.session.id };
}

const tick = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

describe("event journal retention", () => {
  it("reports CURSOR_EXPIRED when the cursor is below the retention watermark", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-journal-"));
    const journal = new EventJournal(root, 3);
    await journal.load();
    for (let i = 0; i < 5; i += 1) await journal.append("host", "test", { i });
    // Events 1 and 2 were evicted; a cursor at 1 can no longer be replayed in full.
    expect(() => journal.replay("host", undefined, { epoch: journal.epoch, sequence: 1 })).toThrowError(
      /cursor/i
    );
    expect(
      journal.replay("host", undefined, { epoch: journal.epoch, sequence: 3 }).map((event) => event.sequence)
    ).toEqual([4, 5]);
  });

  it("keeps a session cursor valid when only other sessions were evicted", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-journal-scope-"));
    const journal = new EventJournal(root, 3);
    await journal.load();
    const s1 = await journal.append("session", "turn.started", {}, { sessionId: "s1" });
    await journal.append("session", "item.delta", {}, { sessionId: "s2" });
    await journal.append("session", "item.delta", {}, { sessionId: "s2" });
    await journal.append("session", "item.delta", {}, { sessionId: "s1" });
    await journal.append("session", "item.delta", {}, { sessionId: "s2" });
    // s1's events were never evicted, so its cursor replays cleanly.
    expect(() =>
      journal.replay("session", "s1", { epoch: journal.epoch, sequence: s1.sequence! })
    ).not.toThrow();
  });
});

describe("write idempotency", () => {
  it("returns the first result for a repeated key and rejects a changed request", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver());
    const first = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "hi" }, context: { requestId: "r1", idempotencyKey: "k1" } },
      auth
    )) as { turn: { id: string } };
    const replay = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "hi" }, context: { requestId: "r2", idempotencyKey: "k1" } },
      auth
    )) as { turn: { id: string } };
    expect(replay.turn.id).toBe(first.turn.id);
    await expect(
      service.handle(
        "turn/start",
        { sessionId, input: { text: "different" }, context: { requestId: "r3", idempotencyKey: "k1" } },
        auth
      )
    ).rejects.toMatchObject({ code: "IDEMPOTENCY_CONFLICT" });
  });
});

describe("session single-writer admission", () => {
  it("rejects a second turn while busy and accepts it when queued", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    await service.handle("turn/start", { sessionId, input: { text: "one" } }, auth);
    await tick();
    await expect(
      service.handle("turn/start", { sessionId, input: { text: "two" } }, auth)
    ).rejects.toMatchObject({ code: "SESSION_BUSY" });
    const queued = (await service.handle(
      "turn/start",
      { sessionId, admission: "queue", input: { text: "two" } },
      auth
    )) as { turn: { status: string } };
    expect(queued.turn.status).toBe("queued");
  });
});

describe("turn terminal idempotency", () => {
  it("keeps the first terminal state when interrupting twice", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    const started = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "one" } },
      auth
    )) as { turn: { id: string } };
    await tick();
    const first = (await service.handle("turn/interrupt", { turnId: started.turn.id }, auth)) as {
      turn: { status: string };
    };
    expect(first.turn.status).toBe("interrupted");
    const second = (await service.handle("turn/interrupt", { turnId: started.turn.id }, auth)) as {
      turn: { status: string };
    };
    expect(second.turn.status).toBe("interrupted");
  });

  it("cancels turns queued behind a stopped turn instead of leaving them parked", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    const running = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "one" } },
      auth
    )) as { turn: { id: string } };
    await tick();
    const queued = (await service.handle(
      "turn/start",
      { sessionId, admission: "queue", input: { text: "two" } },
      auth
    )) as { turn: { id: string; status: string } };
    expect(queued.turn.status).toBe("queued");
    await service.handle("turn/interrupt", { turnId: running.turn.id }, auth);
    const fetched = (await service.handle("turn/get", { turnId: queued.turn.id }, auth)) as {
      turn: { status: string };
    };
    expect(fetched.turn.status).toBe("canceled");
  });

  it("returns the completed state when interrupting an already-finished turn", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver());
    const started = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "one" } },
      auth
    )) as { turn: { id: string } };
    await tick(50);
    const result = (await service.handle("turn/interrupt", { turnId: started.turn.id }, auth)) as {
      turn: { status: string };
    };
    expect(result.turn.status).toBe("completed");
  });
});

describe("restart reconciliation", () => {
  it("marks a turn that was running at exit as uncertain", async () => {
    const { config, service, auth, sessionId } = await setup(new ControlledDriver());
    const started = (await service.handle(
      "turn/start",
      { sessionId, input: { text: "one" } },
      auth
    )) as { turn: { id: string } };
    await tick();
    // A fresh service over the same data simulates a process restart.
    const restarted = new HostService(config, new ControlledDriver());
    await restarted.init();
    const fetched = (await restarted.handle("turn/get", { turnId: started.turn.id }, auth)) as {
      turn: { status: string; settledReason?: string };
    };
    expect(fetched.turn.status).toBe("uncertain");
    expect(fetched.turn.settledReason).toBe("agent_restarted_unconfirmed");
    void service;
  });
});

describe("media gc wiring", () => {
  it("reclaims an old unreferenced blob and keeps a fresh one", async () => {
    const { service } = await setup(new DeterministicAgentDriver());
    const now = new Date("2026-05-01T00:00:00Z");
    const old = await service.blobs.importImageBase64({
      sessionId: "s-old",
      dataBase64: Buffer.from("old-image").toString("base64"),
      mimeType: "image/png",
      fileName: "old.png",
      kind: "input",
      now: new Date(now.getTime() - 48 * 60 * 60 * 1000)
    });
    const fresh = await service.blobs.importImageBase64({
      sessionId: "s-new",
      dataBase64: Buffer.from("new-image").toString("base64"),
      mimeType: "image/png",
      fileName: "new.png",
      kind: "input",
      now
    });
    const removed = await service.runMaintenance(now);
    expect(removed).toBeGreaterThanOrEqual(1);
    await expect(service.blobs.read(old.id, 0, 100)).rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(service.blobs.read(fresh.id, 0, 100)).resolves.toBeTruthy();
  });
});

describe("skill versioning", () => {
  it("changes the version when only an auxiliary file changes", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-skill-hash-"));
    const source = join(root, "source");
    await mkdir(source, { recursive: true });
    await writeFile(join(source, "SKILL.md"), "---\nname: demo\ndescription: one\n---\n");
    await writeFile(join(source, "run.sh"), "echo v1\n");
    const registry = new SkillRegistry(join(root, "data"), root, true);
    const first = await registry.install({ type: "directory", path: source });
    // SKILL.md is unchanged; only the aux file differs.
    await writeFile(join(source, "run.sh"), "echo v2\n");
    const second = await registry.update(first.id, { type: "directory", path: source });
    expect(second.version).not.toBe(first.version);
  });
});

describe("idempotency scoping and expiration", () => {
  it("scopes idempotency keys to the authenticated device", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver());
    const pairing2 = await service.createPairingToken();
    const paired2 = await service.pair({ deviceLabel: "device-2" }, pairing2.token);
    const auth2: AuthContext = {
      device: {
        deviceId: paired2.deviceId,
        label: "device-2",
        role: "owner",
        tokenHash: "hash-2",
        createdAt: new Date().toISOString(),
        lastUsedAt: new Date().toISOString(),
        revokedAt: null
      }
    };
    // Device 1 uses key "shared-k1"
    const r1 = (await service.handle(
      "session/rename",
      { sessionId, title: "Title from 1", context: { requestId: "r1", idempotencyKey: "shared-k1" } },
      auth
    )) as { session: { title: string } };
    expect(r1.session.title).toBe("Title from 1");

    // Device 2 uses SAME key "shared-k1" with different params - should NOT raise conflict across devices
    const r2 = (await service.handle(
      "session/rename",
      { sessionId, title: "Title from 2", context: { requestId: "r2", idempotencyKey: "shared-k1" } },
      auth2
    )) as { session: { title: string } };
    expect(r2.session.title).toBe("Title from 2");
  });

  it("raises CONFLICT when retrying with an expired idempotency key", async () => {
    const { service, auth, sessionId, config } = await setup(new DeterministicAgentDriver());
    const oldTime = new Date(Date.now() - 48 * 60 * 60 * 1000);
    await service.handle(
      "session/rename",
      { sessionId, title: "Past", context: { requestId: "r1", idempotencyKey: "expired-k1" } },
      auth
    );

    // Overwrite the record's createdAt to 48 hours in the past
    const idempotencyPath = join(config.dataDir, "meta", "idempotency.json");
    const json = JSON.parse(await readFile(idempotencyPath, "utf8"));
    for (const rec of json.records) {
      if (rec.key === "expired-k1") rec.createdAt = oldTime.toISOString();
    }
    await writeFile(idempotencyPath, JSON.stringify(json));

    // Retrying with the expired key must raise CONFLICT per contract §3.1
    await expect(
      service.handle(
        "session/rename",
        { sessionId, title: "Past", context: { requestId: "r2", idempotencyKey: "expired-k1" } },
        auth
      )
    ).rejects.toMatchObject({ code: "CONFLICT" });
  });

  it("does not persist plaintext device tokens in idempotency.json", async () => {
    const { service, auth, config } = await setup(new DeterministicAgentDriver());
    const res = (await service.handle(
      "connection/rotate-token",
      { context: { requestId: "rot-1", idempotencyKey: "rot-k1" } },
      auth
    )) as { rotationId: string; deviceToken: string };
    expect(res.deviceToken).toMatch(/^pdt2\./);

    // Idempotent retry returns identical rotation
    const replay = (await service.handle(
      "connection/rotate-token",
      { context: { requestId: "rot-2", idempotencyKey: "rot-k1" } },
      auth
    )) as { rotationId: string; deviceToken: string };
    expect(replay.rotationId).toBe(res.rotationId);
    expect(replay.deviceToken).toBe(res.deviceToken);

    // Verify idempotency.json does NOT contain the plaintext deviceToken
    const idempotencyPath = join(config.dataDir, "meta", "idempotency.json");
    let fileContent = "";
    try {
      fileContent = await readFile(idempotencyPath, "utf8");
    } catch {
      // file might not even be written if rotate-token is memory-only
    }
    expect(fileContent).not.toContain(res.deviceToken);
  });

  it("does not persist plaintext pairing tokens in idempotency.json", async () => {
    const { service, auth, config } = await setup(new DeterministicAgentDriver());
    const first = (await service.handle(
      "device/pairing-token",
      { ttlSeconds: 600, context: { requestId: "pair-1", idempotencyKey: "pair-k1" } },
      auth
    )) as { token: string; expiresAt: string };
    expect(first.token).toMatch(/^ppt2\./);

    // `device/pairing-token` is one-shot: reusing the key must mint a NEW token
    // instead of reproducing the persisted (plaintext) one.
    const second = (await service.handle(
      "device/pairing-token",
      { ttlSeconds: 600, context: { requestId: "pair-2", idempotencyKey: "pair-k1" } },
      auth
    )) as { token: string; expiresAt: string };
    expect(second.token).not.toBe(first.token);

    const idempotencyPath = join(config.dataDir, "meta", "idempotency.json");
    let fileContent = "";
    try {
      fileContent = await readFile(idempotencyPath, "utf8");
    } catch {
      // store may not have been written — nothing to leak
    }
    expect(fileContent).not.toContain(first.token);
    expect(fileContent).not.toContain("ppt2.");
  });
});

describe("queued turn independent cancellation", () => {
  it("canceling an individual queued turn leaves other queued turns in queue", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    // Start running turn
    await service.handle("turn/start", { sessionId, input: { text: "running" } }, auth);
    await tick();

    // Queue Q1 and Q2
    const q1 = (await service.handle(
      "turn/start",
      { sessionId, admission: "queue", input: { text: "queue-1" } },
      auth
    )) as { turn: { id: string; status: string } };
    const q2 = (await service.handle(
      "turn/start",
      { sessionId, admission: "queue", input: { text: "queue-2" } },
      auth
    )) as { turn: { id: string; status: string } };

    expect(q1.turn.status).toBe("queued");
    expect(q2.turn.status).toBe("queued");

    // Cancel Q1
    const canceledQ1 = (await service.handle(
      "turn/cancel",
      { turnId: q1.turn.id, context: { requestId: "c1" } },
      auth
    )) as { turn: { status: string } };
    expect(canceledQ1.turn.status).toBe("canceled");

    // Q2 must still be queued!
    const fetchedQ2 = (await service.handle("turn/get", { turnId: q2.turn.id }, auth)) as {
      turn: { status: string };
    };
    expect(fetchedQ2.turn.status).toBe("queued");
  });
});

describe("approval revision enforcement", () => {
  it("rejects approval response with stale revision", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    const turn = (await service.handle("turn/start", { sessionId, input: { text: "run" } }, auth)) as {
      turn: { id: string };
    };
    // Emit an approval request manually
    let capturedRevision = 0;
    const reqPromise = (service as unknown as {
      requestApproval: (s: unknown, t: string, tool: string, i: unknown) => Promise<boolean>;
      approvalRevision: number;
    }).requestApproval({ id: sessionId }, turn.turn.id, "bash", { command: "ls" });

    capturedRevision = (service as unknown as { approvalRevision: number }).approvalRevision;
    const pendingApprovals = (service as unknown as {
      pendingApprovals: Map<string, { revision: number }>;
    }).pendingApprovals;
    const [approvalId] = pendingApprovals.keys();

    // Respond with mismatched revision
    await expect(
      service.handle(
        "approval/respond",
        { approvalId, decision: "allow-once", expectedRevision: capturedRevision + 99 },
        auth
      )
    ).rejects.toMatchObject({ code: "APPROVAL_STALE" });

    // Respond with correct revision
    const ok = (await service.handle(
      "approval/respond",
      { approvalId, decision: "allow-once", expectedRevision: capturedRevision },
      auth
    )) as { resolved: boolean };
    expect(ok.resolved).toBe(true);
    await expect(reqPromise).resolves.toBe(true);
  });
});

describe("session history pagination", () => {
  it("respects beforeItemId and limit pagination parameters", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver());
    for (let i = 1; i <= 5; i++) {
      await service.handle("turn/start", { sessionId, input: { text: `msg-${i}` } }, auth);
      await tick(30);
    }
    const full = (await service.handle("session/history", { sessionId }, auth)) as {
      items: Array<{ id: string; text?: string }>;
      hasMore: boolean;
    };
    expect(full.items.length).toBeGreaterThanOrEqual(5);

    const targetItem = full.items[3];
    expect(targetItem).toBeDefined();
    if (!targetItem) throw new Error("targetItem missing");
    const paginated = (await service.handle(
      "session/history",
      { sessionId, beforeItemId: targetItem.id, limit: 2 },
      auth
    )) as { items: Array<{ id: string }>; hasMore: boolean };

    expect(paginated.items.length).toBeLessThanOrEqual(2);
    // None of the returned items can be targetItem or after targetItem
    for (const itm of paginated.items) {
      expect(itm.id).not.toBe(targetItem.id);
    }
  });
});
