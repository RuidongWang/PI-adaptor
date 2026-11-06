import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
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
  private readonly pending = new Map<string, {
    request: AgentTurnRequest;
    resolveWait: () => void;
  }>();

  start(request: AgentTurnRequest): AgentTurnHandle {
    let resolveWait!: () => void;
    const wait = new Promise<void>((resolve) => {
      resolveWait = resolve;
    });
    this.pending.set(request.turnId, { request, resolveWait });
    queueMicrotask(() => request.onEvent({ kind: "turn.started", payload: { turnId: request.turnId } }));
    return {
      turnId: request.turnId,
      abort: async () => resolveWait(),
      wait: () => wait
    };
  }

  finishWithoutTerminalEvent(turnId: string): void {
    const pending = this.pending.get(turnId);
    if (!pending) throw new Error(`turn ${turnId} is not running`);
    this.pending.delete(turnId);
    pending.resolveWait();
  }

  requestFor(turnId: string): AgentTurnRequest | undefined {
    return this.pending.get(turnId)?.request;
  }
}

/** Transient provider key used by the key-handling tests; must never hit disk. */
const TEST_TRANSIENT_KEY = "sk-test-transient-key";

async function createTestProvider(
  service: HostService,
  auth: AuthContext,
  authKind: "api_key" | "none",
  vendorKey: string
): Promise<string> {
  const created = (await service.handle(
    "provider/create",
    {
      provider: {
        name: "Mock",
        vendorKey,
        type: "openai_compatible",
        protocol: "openai_compatible",
        baseUrl: "https://example.com/v1",
        authKind,
        ...(authKind === "api_key" ? { apiKey: TEST_TRANSIENT_KEY } : {}),
        models: [
          {
            id: "mock-model",
            displayName: "Mock Model",
            contextWindow: 128_000,
            maxTokens: 8_192,
            thinkingLevels: [],
            defaultThinkingLevel: null,
            supportsImages: false
          }
        ]
      }
    },
    auth
  )) as { provider: { id: string } };
  return created.provider.id;
}

/** Upload a tiny ready attachment through the real attachment path. */
async function uploadPng(service: HostService, auth: AuthContext, sessionId: string): Promise<string> {
  const bytes = Buffer.from("fake-png-bytes");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const created = (await service.handle(
    "attachment/create",
    { sessionId, fileName: "a.png", mimeType: "image/png", byteLength: bytes.length, sha256 },
    auth
  )) as { attachmentId: string };
  await service.handle(
    "attachment/chunk",
    { attachmentId: created.attachmentId, offset: 0, dataBase64: bytes.toString("base64") },
    auth
  );
  await service.handle("attachment/complete", { attachmentId: created.attachmentId, sha256 }, auth);
  return created.attachmentId;
}

/** Concatenate every regular file under `dir` so a test can prove a value never landed. */
async function persistedText(dir: string): Promise<string> {
  let output = "";
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const child = join(dir, entry.name);
    if (entry.isDirectory()) output += await persistedText(child);
    else if (entry.isFile()) output += await readFile(child, "utf8");
  }
  return output;
}

async function setup(
  driver: AgentDriver,
  options: { provider?: "api_key" | "none" } = {}
) {
  const root = await mkdtemp(join(tmpdir(), "pi-adaptor-hardening-"));
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
  const providerId = options.provider
    ? await createTestProvider(service, auth, options.provider, `mock-${options.provider}`)
    : undefined;
  const session = (await service.handle(
    "session/create",
    {
      projectId: projectRecord.id,
      ...(providerId ? { providerId, modelId: "mock-model" } : {})
    },
    auth
  )) as {
    session: { id: string };
  };
  return { root, config, service, auth, sessionId: session.session.id, providerId };
}

const tick = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

/** Wait for a real terminal state instead of sleeping a guessed number of milliseconds. */
async function waitForTurnStatus(
  service: HostService,
  auth: AuthContext,
  turnId: string,
  status: string
): Promise<void> {
  await vi.waitFor(
    async () => {
      const fetched = (await service.handle("turn/get", { turnId }, auth)) as {
        turn: { status: string };
      };
      expect(fetched.turn.status).toBe(status);
    },
    { timeout: 5_000 }
  );
}

describe("event journal retention", () => {
  it("reports CURSOR_EXPIRED when the cursor is below the retention watermark", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-journal-"));
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
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-journal-scope-"));
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

describe("turn terminal notifications", () => {
  it("emits completion and clears the snapshot when a driver exits without a terminal event", async () => {
    class WaitOnlyDriver implements AgentDriver {
      readonly appendsPrompt = true;
      start(request: AgentTurnRequest): AgentTurnHandle {
        let resolveWait!: () => void;
        const wait = new Promise<void>((resolve) => { resolveWait = resolve; });
        queueMicrotask(() => {
          request.onEvent({ kind: "turn.started", payload: { turnId: request.turnId } });
          resolveWait();
        });
        return { turnId: request.turnId, abort: async () => resolveWait(), wait: () => wait };
      }
    }
    const { service, auth, sessionId } = await setup(new WaitOnlyDriver());
    const subscription = (await service.handle("events/subscribe", {
      scope: "session",
      sessionId
    }, auth)) as { subscriptionId: string };
    const events: { kind: string; payload: { turn?: { id: string; status: string } } }[] = [];
    service.setSubscriptionSink(subscription.subscriptionId, (event) => events.push(event as never));

    const started = (await service.handle("turn/start", {
      sessionId,
      input: { text: "finish without a terminal event" }
    }, auth)) as { turn: { id: string; status: string } };
    expect(started.turn.status, "启动响应必须反映已经完成的轮次").toBe("completed");
    await vi.waitFor(() => {
      expect(events.some((event) => event.kind === "turn.completed")).toBe(true);
    });

    const completed = events.filter((event) => event.kind === "turn.completed");
    expect(completed).toHaveLength(1);
    expect(completed[0]?.payload.turn).toMatchObject({ id: started.turn.id, status: "completed" });
    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { activeTurn: unknown; activeItems: unknown[] };
    };
    expect(attached.snapshot.activeTurn).toBeNull();
    expect(attached.snapshot.activeItems).toEqual([]);
  });

  it("notifies completion once and starts the queued turn when wait resolves without a terminal event", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const subscription = (await service.handle("events/subscribe", {
      scope: "session",
      sessionId
    }, auth)) as { subscriptionId: string };
    const events: { kind: string; turnId?: string; payload: { turn?: { status: string } } }[] = [];
    service.setSubscriptionSink(subscription.subscriptionId, (event) => events.push(event as never));

    const running = (await service.handle("turn/start", {
      sessionId,
      input: { text: "first" }
    }, auth)) as { turn: { id: string; status: string } };
    expect(running.turn.status).toBe("running");
    const queued = (await service.handle("turn/start", {
      sessionId,
      admission: "queue",
      input: { text: "second" }
    }, auth)) as { turn: { id: string; status: string } };
    expect(queued.turn.status).toBe("queued");

    driver.finishWithoutTerminalEvent(running.turn.id);
    await vi.waitFor(() => {
      expect(events.some((event) => event.kind === "turn.started" && event.turnId === queued.turn.id)).toBe(true);
    });

    const firstCompleted = events.filter((event) =>
      event.kind === "turn.completed" && event.turnId === running.turn.id
    );
    expect(firstCompleted).toHaveLength(1);
    expect(firstCompleted[0]?.payload.turn?.status).toBe("completed");
    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { activeTurn: { id: string } | null; queuedTurns: unknown[] };
    };
    expect(attached.snapshot.activeTurn?.id).toBe(queued.turn.id);
    expect(attached.snapshot.queuedTurns).toEqual([]);
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
    await waitForTurnStatus(service, auth, started.turn.id, "completed");
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
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-skill-hash-"));
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
  it("returns exactly the items before the cursor instead of any shorter page", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver());
    for (let i = 1; i <= 5; i++) {
      const started = (await service.handle(
        "turn/start",
        { sessionId, input: { text: `msg-${i}` } },
        auth
      )) as { turn: { id: string } };
      // Sleep-free: wait for the turn to settle so the next one is not queued.
      await waitForTurnStatus(service, auth, started.turn.id, "completed");
    }
    const full = (await service.handle("session/history", { sessionId }, auth)) as {
      items: Array<{ id: string; text?: string }>;
      hasMore: boolean;
    };
    expect(full.items.length).toBeGreaterThanOrEqual(4);

    const targetItem = full.items[3];
    expect(targetItem).toBeDefined();
    if (!targetItem) throw new Error("targetItem missing");
    const paginated = (await service.handle(
      "session/history",
      { sessionId, beforeItemId: targetItem.id, limit: 2 },
      auth
    )) as { items: Array<{ id: string }>; hasMore: boolean };

    // An empty page or any two items after the cursor used to pass; the exact slice must not.
    const expectedPage = full.items.slice(1, 3).map((item) => item.id);
    expect(expectedPage).toHaveLength(2);
    expect(paginated.items.map((item) => item.id)).toEqual(expectedPage);
    expect(paginated.hasMore).toBe(true);

    // The first page is the newest slice, not the oldest one.
    const firstPage = (await service.handle(
      "session/history",
      { sessionId, limit: 2 },
      auth
    )) as { items: Array<{ id: string }>; hasMore: boolean };
    expect(firstPage.items.map((item) => item.id)).toEqual(
      full.items.slice(-2).map((item) => item.id)
    );
    expect(firstPage.hasMore).toBe(true);

    // Before the oldest item there is no earlier history and nothing more to fetch.
    const firstItem = full.items[0];
    expect(firstItem).toBeDefined();
    if (!firstItem) throw new Error("first item missing");
    const atStart = (await service.handle(
      "session/history",
      { sessionId, beforeItemId: firstItem.id, limit: 2 },
      auth
    )) as { items: Array<{ id: string }>; hasMore: boolean };
    expect(atStart.items).toEqual([]);
    expect(atStart.hasMore).toBe(false);
  });
});

describe("transient provider keys", () => {
  it("rejects a turn for an api_key provider without a key and leaves no turn behind", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver(), { provider: "api_key" });
    const subscription = (await service.handle(
      "events/subscribe",
      { scope: "session", sessionId },
      auth
    )) as { subscriptionId: string };
    const events: { kind: string }[] = [];
    service.setSubscriptionSink(subscription.subscriptionId, (event) => events.push(event as never));

    await expect(
      service.handle("turn/start", { sessionId, input: { text: "hi" } }, auth)
    ).rejects.toMatchObject({
      code: "PROVIDER_SECRET_MISSING",
      data: expect.objectContaining({ field: "apiKey" })
    });

    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { activeTurn: unknown; queuedTurns: unknown[] };
    };
    expect(attached.snapshot.activeTurn).toBeNull();
    expect(attached.snapshot.queuedTurns).toEqual([]);
    expect(events.filter((event) => event.kind === "turn.started")).toHaveLength(0);
  });

  it("passes the transient key to the driver and never writes it to disk", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId, config } = await setup(driver, { provider: "api_key" });
    const started = (await service.handle(
      "turn/start",
      { sessionId, apiKey: TEST_TRANSIENT_KEY, input: { text: "hello" } },
      auth
    )) as { turn: { id: string; status: string } };
    expect(started.turn.status).toBe("running");
    expect(driver.requestFor(started.turn.id)?.provider?.apiKey).toBe(TEST_TRANSIENT_KEY);
    expect(await persistedText(config.dataDir)).not.toContain(TEST_TRANSIENT_KEY);
  });

  it("rejects malformed transient keys", async () => {
    const { service, auth, sessionId } = await setup(new DeterministicAgentDriver(), { provider: "api_key" });
    for (const apiKey of ["", "line\nbreak", "x".repeat(16_385)]) {
      await expect(
        service.handle("turn/start", { sessionId, apiKey, input: { text: "hi" } }, auth)
      ).rejects.toMatchObject({
        code: "INVALID_ARGUMENT",
        data: expect.objectContaining({ field: "apiKey" })
      });
    }
  });

  it("ignores a transient key for a provider that needs none", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver, { provider: "none" });
    const started = (await service.handle(
      "turn/start",
      { sessionId, apiKey: "unused-key", input: { text: "hi" } },
      auth
    )) as { turn: { id: string } };
    expect(driver.requestFor(started.turn.id)?.provider?.apiKey).toBeNull();
  });

  it("does not persist a key-derived digest for an idempotent turn", async () => {
    const { service, auth, sessionId, config } = await setup(new ControlledDriver(), { provider: "api_key" });
    const firstKey = "sk-first-transient-key";
    const secondKey = "sk-second-transient-key";
    const first = (await service.handle(
      "turn/start",
      {
        sessionId,
        apiKey: firstKey,
        input: { text: "hi" },
        context: { requestId: "r1", idempotencyKey: "redacted-k1" }
      },
      auth
    )) as { turn: { id: string } };
    // A different key is not a different request: the redacted digest replays
    // the first result instead of raising IDEMPOTENCY_CONFLICT.
    const replay = (await service.handle(
      "turn/start",
      {
        sessionId,
        apiKey: secondKey,
        input: { text: "hi" },
        context: { requestId: "r2", idempotencyKey: "redacted-k1" }
      },
      auth
    )) as { turn: { id: string } };
    expect(replay.turn.id).toBe(first.turn.id);

    const idempotencyText = await readFile(join(config.dataDir, "meta", "idempotency.json"), "utf8");
    for (const key of [firstKey, secondKey]) {
      expect(idempotencyText).not.toContain(key);
      expect(idempotencyText).not.toContain(createHash("sha256").update(key).digest("hex"));
    }
    expect(await persistedText(config.dataDir)).not.toContain(firstKey);
  });
});

describe("queued turn snapshot", () => {
  it("returns queued text and attachment count in the snapshot only, and drops them on cancel", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId, config } = await setup(driver, { provider: "api_key" });
    await service.handle(
      "turn/start",
      { sessionId, apiKey: TEST_TRANSIENT_KEY, input: { text: "first" } },
      auth
    );
    const attachmentId = await uploadPng(service, auth, sessionId);
    const queued = (await service.handle(
      "turn/start",
      {
        sessionId,
        admission: "queue",
        apiKey: TEST_TRANSIENT_KEY,
        input: { text: "queue-one", attachments: [attachmentId] }
      },
      auth
    )) as { turn: { id: string; status: string; text?: string; attachmentCount?: number } };
    expect(queued.turn.status).toBe("queued");
    // D2: the prompt text never rides on the turn/start response.
    expect(queued.turn.text).toBeUndefined();
    expect(queued.turn.attachmentCount).toBeUndefined();

    const attached = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { queuedTurns: Array<Record<string, unknown>> };
    };
    expect(attached.snapshot.queuedTurns).toHaveLength(1);
    expect(attached.snapshot.queuedTurns[0]).toMatchObject({
      id: queued.turn.id,
      status: "queued",
      text: "queue-one",
      attachmentCount: 1
    });
    // The transient key lives in memory only.
    expect(await persistedText(config.dataDir)).not.toContain(TEST_TRANSIENT_KEY);
    expect(await persistedText(config.dataDir)).not.toContain("queue-one");

    await service.handle("turn/cancel", { turnId: queued.turn.id }, auth);
    const after = (await service.handle("session/attach", { sessionId }, auth)) as {
      snapshot: { queuedTurns: unknown[] };
    };
    expect(after.snapshot.queuedTurns).toEqual([]);
    expect(await persistedText(config.dataDir)).not.toContain(TEST_TRANSIENT_KEY);
  });
});

describe("provider secret migration", () => {
  it("removes legacy secret files on init, reports only a count, and is idempotent", async () => {
    const { config } = await setup(new DeterministicAgentDriver());
    const secretsDir = join(config.dataDir, "providers", "secrets");
    await mkdir(secretsDir, { recursive: true });
    await writeFile(join(secretsDir, "legacy-1"), "sk-legacy-one");
    await writeFile(join(secretsDir, "legacy-2"), "sk-legacy-two");

    const restarted = new HostService(config, new DeterministicAgentDriver());
    expect(await restarted.init()).toEqual({ removedLegacySecrets: 2 });
    await expect(readdir(secretsDir)).rejects.toMatchObject({ code: "ENOENT" });

    const second = new HostService(config, new DeterministicAgentDriver());
    expect(await second.init()).toEqual({ removedLegacySecrets: 0 });
  });
});
