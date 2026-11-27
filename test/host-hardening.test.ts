import { createHash } from "node:crypto";
import { appendFile, chmod, mkdir, mkdtemp, readFile, readdir, rename, rm, utimes, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, onTestFinished, vi } from "vitest";
import type { AgentDriver, AgentTurnHandle, AgentTurnRequest } from "../src/agent/driver.js";
import { DeterministicAgentDriver } from "../src/agent/driver.js";
import { ensureHostDirectories, parseHostConfig } from "../src/config.js";
import { HostService } from "../src/server/host-service.js";
import type { TurnStore } from "../src/server/turn-store.js";
import { EventJournal, type HostEvent } from "../src/events/journal.js";
import { SkillRegistry } from "../src/skills/registry.js";
import type { AuthContext } from "../src/server/host-service.js";
import { assertPublicHttpsEndpoint, resolveEndpointAddresses } from "../src/security/endpoint.js";

/** A driver whose turns stay running until aborted, so busy/queue paths are testable. */
class ControlledDriver implements AgentDriver {
  readonly appendsPrompt = true;
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
const TEST_PROVIDER_URL = "https://example.com/v1";
const PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAFgQIAqP2mVwAAAABJRU5ErkJggg==";

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
        baseUrl: TEST_PROVIDER_URL,
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
  const bytes = Buffer.from(PNG_BASE64, "base64");
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

async function makeTempDirectory(prefix: string): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), prefix));
  onTestFinished(() => rm(root, { recursive: true, force: true }));
  return root;
}

it("applies the endpoint policy in test-named data directories and to resolved connection addresses", async () => {
  const root = await makeTempDirectory("pi-adaptor-test-policy-");
  const config = parseHostConfig(["--home", root], {}, root);
  const service = new HostService(config, new DeterministicAgentDriver());
  await expect(service.providers.create({
    name: "Private network fixture", vendorKey: "fixture", type: "openai_compatible", protocol: "openai_compatible",
    baseUrl: "https://192.168.1.20/v1", authKind: "none", models: []
  })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  const lookup = vi.fn(async () => [{ address: "8.8.8.8" }]);
  await expect(resolveEndpointAddresses("provider.example", { lookup })).resolves.toEqual([{ address: "8.8.8.8", family: 4 }]);
  expect(lookup).toHaveBeenCalledOnce();
  await expect(resolveEndpointAddresses("provider.example", { lookup: async () => [{ address: "192.168.1.20" }] })).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
  await expect(assertPublicHttpsEndpoint("http://127.0.0.1:1234/v1")).resolves.toBeInstanceOf(URL);
});

function makeService(config: ReturnType<typeof parseHostConfig>, driver: AgentDriver): HostService {
  const service = new HostService(config, driver, {
    testOnly: { lookup: async () => [{ address: "93.184.216.34" }] }
  });
  onTestFinished(() => service.shutdown());
  return service;
}

async function setup(
  driver: AgentDriver,
  options: { provider?: "api_key" | "none" } = {}
) {
  const root = await makeTempDirectory("pi-adaptor-hardening-");
  const project = join(root, "project");
  await mkdir(project, { recursive: true });
  const config = parseHostConfig(
    ["--data-dir", join(root, "data"), "--agent-dir", join(root, "agent"), "--port", "0"],
    {},
    root
  );
  await ensureHostDirectories(config);
  const service = makeService(config, driver);
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
  const providerBinding = providerId ? { providerId, baseUrl: TEST_PROVIDER_URL } : undefined;
  return { root, config, service, auth, sessionId: session.session.id, providerId, providerBinding };
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
    const root = await makeTempDirectory("pi-adaptor-journal-");
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
    const root = await makeTempDirectory("pi-adaptor-journal-scope-");
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
  it("recovers the same session when creation commits before an event write fails", async () => {
    const { service, auth, config } = await setup(new ControlledDriver());
    const params = { title: "committed session", context: { idempotencyKey: "create-commit-test" } };
    vi.spyOn(service.journal, "append").mockRejectedValueOnce(new Error("journal unavailable"));

    await expect(service.handle("session/create", params, auth)).rejects.toThrow("journal unavailable");
    const committed = (await service.meta.listSessions()).find(session => session.title === params.title);
    expect(committed).toBeDefined();
    await service.shutdown();
    const restarted = makeService(config, new ControlledDriver());
    await restarted.init();
    await expect(restarted.handle("session/create", params, auth))
      .resolves.toMatchObject({ session: { id: committed!.id } });
    const sessions = await restarted.meta.listSessions();
    expect(sessions.filter((session) => session.title === params.title)).toHaveLength(1);
    expect(restarted.journal.replay("host", undefined, { epoch: restarted.journal.epoch, sequence: 0 })
      .filter(event => event.kind === "session.created" && event.sessionId === committed!.id)).toHaveLength(1);
  });

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
  it.each([false, true])("recovers a committed terminal outbox on restart, event already appended=%s", async appended => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const record = { id: "finished", sessionId, status: "completed", createdAt: new Date(0).toISOString(), settledAt: new Date().toISOString() };
    await service["turnStore"].upsert({ ...record, eventPending: true });
    if (appended) await service.journal.append("session", "turn.completed", { turn: record }, { sessionId, turnId: record.id });
    await service.shutdown();
    const restarted = makeService(config, new ControlledDriver()); await restarted.init();
    await expect(restarted.handle("turn/get", { turnId: record.id }, auth)).resolves.toMatchObject({ turn: record });
    expect(restarted.journal.replay("session", sessionId, { epoch: restarted.journal.epoch, sequence: 0 }).filter(event => event.turnId === record.id)).toHaveLength(1);
    expect((await restarted["turnStore"].all()).find(turn => turn.id === record.id)?.eventPending).toBe(false);
  });
  it("keeps the committed turn visible until failed terminal storage recovers", async () => {
    const driver = new ControlledDriver();
    const { service, config, auth, sessionId } = await setup(driver);
    const after = service.journal.currentCursor();
    const { turn } = await service.handle("turn/start", { sessionId, input: { text: "once" } }, auth) as { turn: { id: string } };
    const store = service["turnStore"];
    const write = store.upsert.bind(store);
    let blocked = true, failures = 0;
    vi.spyOn(store, "upsert").mockImplementation(async record => {
      if (blocked && record.status === "failed") { failures++; throw new Error("fixture terminal write failure"); }
      return write(record);
    });
    driver.requestFor(turn.id)!.onEvent({ kind: "turn.failed", payload: { error: "fixture" } });
    driver.finishWithoutTerminalEvent(turn.id);
    await vi.waitFor(() => expect(failures).toBeGreaterThan(0));
    await expect(service.handle("turn/get", { turnId: turn.id }, auth)).resolves.toMatchObject({ turn: { status: "running" } });
    expect((await store.all()).find(record => record.id === turn.id)?.status).toBe("running");
    expect(service.journal.replay("session", sessionId, after).some(event => event.kind === "turn.failed")).toBe(false);
    await expect(service.handle("turn/start", { sessionId, input: { text: "late" } }, auth)).rejects.toMatchObject({ code: "SESSION_BUSY" });
    blocked = false;
    await waitForTurnStatus(service, auth, turn.id, "failed");
    expect(service.journal.replay("session", sessionId, after).filter(event => event.kind === "turn.failed")).toHaveLength(1);
    await service.shutdown();
    const restarted = makeService(config, new ControlledDriver()); await restarted.init();
    await expect(restarted.handle("turn/get", { turnId: turn.id }, auth)).resolves.toMatchObject({ turn: { status: "failed" } });
  });

  it.each([false, true])("resumes interrupted deletion with the original key, restart=%s", async restart => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const nativePath = await service.catalog.createFile(config.home, join(config.dataDir, "sessions"), sessionId);
    await service.meta.updateSession(sessionId, { nativePath });
    const attachment = await uploadPng(service, auth, sessionId);
    const params = { sessionId, confirmSessionId: sessionId, context: { idempotencyKey: "delete-once" } };
    vi.spyOn(service.blobs, "deleteSession").mockRejectedValueOnce(new Error("fixture media write failure"));
    await expect(service.handle("session/delete", params, auth)).rejects.toThrow("fixture media write failure");
    await expect(readFile(nativePath)).rejects.toMatchObject({ code: "ENOENT" });
    await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [] });
    expect(await service.meta.pendingDeletions()).toHaveLength(1);
    let host = service;
    if (restart) { await host.shutdown(); host = makeService(config, new ControlledDriver()); await host.init(); }
    const result = { deleted: true, sessionId };
    await expect(host.handle("session/delete", params, auth)).resolves.toEqual(result);
    await expect(host.handle("session/delete", params, auth)).resolves.toEqual(result);
    expect(await host.meta.pendingDeletions()).toEqual([]);
    await expect(host.blobs.read(attachment, 0, 1)).rejects.toMatchObject({ code: "NOT_FOUND" });
    expect(host.journal.replay("host", undefined, { epoch: host.journal.epoch, sequence: 0 }).filter(event => event.kind === "session.deleted")).toHaveLength(1);
  });

  it("protects a running native child when deleting its parent", async () => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const nativePath = await service.catalog.createFile(config.home, join(config.dataDir, "sessions"), sessionId);
    await service.meta.updateSession(sessionId, { nativePath });
    const { entryId } = await service.catalog.appendUserMessage(nativePath, "branch point");
    const after = service.journal.currentCursor();
    const paramsBranch = { sessionId, fromItemId: entryId, context: { idempotencyKey: "branch-once" } };
    vi.spyOn(service.journal, "append").mockRejectedValueOnce(new Error("fixture event unavailable"));
    await expect(service.handle("session/branch", paramsBranch, auth)).rejects.toThrow("fixture event unavailable");
    const { session: child } = await service.handle("session/branch", paramsBranch, auth) as { session: { id: string } };
    await expect(service.handle("session/branch", paramsBranch, auth)).resolves.toMatchObject({ session: { id: child.id } });
    expect((await service.catalog.scan()).filter(item => item.parentSession === nativePath)).toHaveLength(1);
    expect(service.journal.replay("host", undefined, after).filter(event => event.kind === "session.created" && event.sessionId === child.id)).toHaveLength(1);
    const { turn } = await service.handle("turn/start", { sessionId: child.id, input: { text: "hold" } }, auth) as { turn: { id: string } };
    const params = { sessionId, confirmSessionId: sessionId };
    await expect(service.handle("session/delete", params, auth)).rejects.toMatchObject({ code: "SESSION_BUSY" });
    expect(await readFile(nativePath, "utf8")).toContain(entryId);
    await service.handle("turn/interrupt", { turnId: turn.id }, auth);
    await expect(service.handle("session/delete", params, auth)).resolves.toMatchObject({ deleted: true });
  });

  it("does not unlink a replacement file when resuming a prepared deletion", async () => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const nativePath = await service.catalog.createFile(config.home, join(config.dataDir, "sessions"), sessionId);
    await service.meta.updateSession(sessionId, { nativePath });
    vi.spyOn(service.catalog, "deleteFile").mockRejectedValueOnce(new Error("fixture before unlink"));
    const params = { sessionId, confirmSessionId: sessionId, context: { idempotencyKey: "delete-prepared" } };
    await expect(service.handle("session/delete", params, auth)).rejects.toThrow("fixture before unlink");
    const replacement = (await readFile(nativePath, "utf8")) + "\n";
    await writeFile(nativePath + ".new", replacement);
    await rename(nativePath + ".new", nativePath);
    await expect(service.handle("session/delete", params, auth)).rejects.toMatchObject({ code: "SESSION_READ_ONLY" });
    expect(await readFile(nativePath, "utf8")).toBe(replacement);
    expect(await service.meta.pendingDeletions()).toHaveLength(1);
    await expect(service.handle("session/get", { sessionId }, auth)).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

  it("rebinds a moved file, refuses duplicate identities and deletes only the verified file", async () => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const original = await service.catalog.createFile(config.home, config.sessionRoots[0]!, sessionId);
    await service.catalog.appendUserMessage(original, "still here", Date.now(), sessionId);
    await service.meta.updateSession(sessionId, { nativePath: original });
    const moved = original + ".moved.jsonl";
    await rename(original, moved);
    await service.handle("session/list", {}, auth);
    await expect(service.handle("session/attach", { sessionId }, auth)).resolves.toMatchObject({ session: { nativePath: moved }, snapshot: { items: [expect.anything()] } });
    await writeFile(original, await readFile(moved));
    const { session: other } = await service.handle("session/create", { title: "unaffected" }, auth) as { session: { id: string } };
    const listed = await service.handle("session/list", {}, auth) as { sessions: { id: string }[] };
    expect(listed.sessions).toEqual(expect.arrayContaining([expect.objectContaining({ id: other.id }), expect.objectContaining({ id: sessionId, readOnlyReason: "external_write_conflict" })]));
    await expect(service.handle("session/attach", { sessionId }, auth)).rejects.toMatchObject({ code: "CONFLICT" });
    const params = { sessionId, confirmSessionId: sessionId };
    await expect(service.handle("session/delete", params, auth)).rejects.toMatchObject({ code: "CONFLICT" });
    await rm(moved);
    await expect(service.handle("session/delete", params, auth)).resolves.toMatchObject({ deleted: true });
    await expect(readFile(original)).rejects.toMatchObject({ code: "ENOENT" });
  });

  it("completes an unannounced branch on restart without a second client request", async () => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const original = await service.catalog.createFile(config.home, config.sessionRoots[0]!, sessionId);
    await service.meta.updateSession(sessionId, { nativePath: original });
    const { entryId } = await service.catalog.appendUserMessage(original, "branch point");
    const params = { sessionId, fromItemId: entryId, context: { idempotencyKey: "recover-branch" } };
    vi.spyOn(service.journal, "append").mockRejectedValueOnce(new Error("fixture failed"));
    await expect(service.handle("session/branch", params, auth)).rejects.toThrow("fixture failed");
    await service.shutdown();
    const restarted = makeService(config, new ControlledDriver());
    await restarted.init();
    const events = () => restarted.journal.replay("host", undefined, { epoch: restarted.journal.epoch, sequence: 0 }).filter(event => event.kind === "session.created" && event.sessionId !== sessionId);
    expect(events()).toHaveLength(1);
    await expect(restarted.handle("session/branch", params, auth)).resolves.toMatchObject({ session: { id: events()[0]!.sessionId } });
    expect(events()).toHaveLength(1);
  });

  it.each([true, false])("reuses an unbound native file after restart with refresh=%s", async refresh => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    vi.spyOn(service.meta, "updateSession").mockRejectedValueOnce(new Error("fixture path commit failed"));
    const input = { sessionId, input: { text: "test" } };
    await expect(service.handle("turn/start", input, auth)).rejects.toThrow("fixture path commit failed");
    const [orphan] = await service.catalog.scan();
    expect(orphan!.id).toBe(sessionId);
    await service.shutdown();
    const restarted = makeService(config, new ControlledDriver());
    await restarted.init();
    if (refresh) {
      await restarted.handle("session/list", {}, auth);
      expect((await restarted.meta.getSession(sessionId))?.nativePath).toBe(orphan!.path);
    }
    await restarted.handle("turn/start", input, auth);
    expect((await restarted.catalog.scan()).map(item => item.path)).toEqual([orphan!.path]);
    expect((await restarted.meta.getSession(sessionId))?.nativePath).toBe(orphan!.path);
  });

  it("uses the configured session directory and can branch legacy sessions", async () => {
    const { service, root, auth, sessionId } = await setup(new ControlledDriver());
    const legacyPath = await service.catalog.createFile(root, service.config.sessionRoots[0]!, sessionId);
    await service.meta.updateSession(sessionId, { nativePath: legacyPath });
    await service.shutdown();
    const directory = join(root, "override");
    const config = parseHostConfig(["--data-dir", service.config.dataDir, "--agent-dir", service.config.agentDir, "--session-dir", directory], {}, root);
    const driver = new ControlledDriver();
    const restarted = makeService(config, driver);
    await restarted.init();
    const { session } = await restarted.handle("session/create", {}, auth) as { session: { id: string } };
    const { turn } = await restarted.handle("turn/start", { sessionId: session.id, input: { text: "note" } }, auth) as { turn: { id: string } };
    expect(driver.requestFor(turn.id)?.sessionDir).toBe(directory);
    await restarted.handle("turn/interrupt", { turnId: turn.id }, auth);
    const path = (await restarted.meta.getSession(session.id))!.nativePath!;
    expect(path.startsWith(directory + "/")).toBe(true);
    for (const [id, file] of [[sessionId, legacyPath], [session.id, path]] as const) {
      const { entryId } = await restarted.catalog.appendUserMessage(file, "branch point", Date.now(), id);
      const result = await restarted.handle("session/branch", { sessionId: id, fromItemId: entryId }, auth) as { session: { id: string } };
      await expect(restarted.handle("session/attach", { sessionId: result.session.id }, auth)).resolves.toMatchObject({ session: { parentSession: file } });
    }
  });

  it("serializes project deletion with creation after the busy snapshot", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    const projectId = (await service.meta.getSession(sessionId))!.projectId!;
    const list = service.meta.listSessions.bind(service.meta);
    let captured!: () => void, resume!: () => void;
    const entered = new Promise<void>(resolve => { captured = resolve; });
    const gate = new Promise<void>(resolve => { resume = resolve; });
    vi.spyOn(service.meta, "listSessions").mockImplementationOnce(async archived => {
      const result = await list(archived);
      captured(); await gate; return result;
    });
    const deletion = service.handle("project/delete", { projectId, confirmProjectId: projectId }, auth);
    await entered;
    const creation = service.handle("session/create", { projectId }, auth);
    const failed = expect(creation).rejects.toMatchObject({ code: "NOT_FOUND" });
    resume();
    await expect(deletion).resolves.toMatchObject({ deleted: true });
    await failed;
  });

  it.skipIf(process.getuid?.() === 0)("defers external deletion when a moved session may be inside an unreadable directory", async () => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const directory = config.sessionRoots[0]!;
    const original = await service.catalog.createFile(config.home, directory, sessionId);
    await service.meta.updateSession(sessionId, { nativePath: original });
    const media = await uploadPng(service, auth, sessionId);
    const archive = join(directory, "archive");
    await mkdir(archive);
    const moved = join(archive, "moved.jsonl");
    await rename(original, moved);
    const after = service.journal.currentCursor();
    await chmod(archive, 0);
    try {
      await expect(readdir(archive)).rejects.toMatchObject({ code: "EACCES" });
      await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [{ id: sessionId }] });
      expect((await service.meta.getSession(sessionId))?.deletedAt).toBeUndefined();
      expect(service.journal.replay("host", undefined, after).some(event => event.kind === "session.deleted")).toBe(false);
      await expect(service.blobs.read(media, 0, 1)).resolves.toBeTruthy();
    } finally { await chmod(archive, 0o700); }
    await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [{ id: sessionId, nativePath: moved }] });
  });

  it("retires only placeholder metadata after a repaired header is discovered across restart", async () => {
    const { service, config, auth } = await setup(new ControlledDriver());
    const file = await service.catalog.createFile(config.home, config.sessionRoots[0]!, "restored");
    const bytes = await readFile(file);
    await writeFile(file, "");
    await service.handle("session/list", {}, auth);
    expect((await service.meta.getSession(file))?.nativePath).toBe(file);
    await writeFile(file, bytes);
    await service.shutdown();
    const restarted = makeService(config, new ControlledDriver());
    await restarted.init();
    const after = restarted.journal.currentCursor();
    for (let pass = 0; pass < 2; pass++) {
      const result = await restarted.handle("session/list", {}, auth) as { sessions: { id: string; nativePath: string }[] };
      expect(result.sessions.filter(session => session.nativePath === file).map(session => session.id)).toEqual(["restored"]);
    }
    expect(await restarted.meta.getSession(file)).toBeNull();
    expect(await readFile(file)).toEqual(bytes);
    expect(restarted.journal.replay("host", undefined, after).some(event => event.kind === "session.deleted")).toBe(false);
    await restarted.shutdown();
    const reopened = makeService(config, new ControlledDriver());
    await reopened.init();
    expect(await reopened.meta.getSession(file)).toBeNull();
    await expect(reopened.handle("session/attach", { sessionId: "restored" }, auth)).resolves.toMatchObject({ session: { nativePath: file, readOnlyReason: null } });
  });

  it("only tombstones confirmed external disappearance and does not rediscover a deleted id", async () => {
    const { service, config, auth, sessionId } = await setup(new ControlledDriver());
    const nativePath = await service.catalog.createFile(config.home, join(config.dataDir, "sessions"), sessionId);
    const bytes = await readFile(nativePath);
    await service.meta.updateSession(sessionId, { nativePath });
    const after = service.journal.currentCursor();
    vi.spyOn(service.catalog, "scanWithCoverage").mockResolvedValueOnce({ sessions: [], uninspected: new Set() });
    await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [{ id: sessionId }] });
    const directory = join(config.dataDir, "sessions");
    await rename(directory, directory + ".offline");
    await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [{ id: sessionId }] });
    await rename(directory + ".offline", directory);
    await rm(nativePath);
    await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [] });
    await writeFile(nativePath, bytes);
    await expect(service.handle("session/list", {}, auth)).resolves.toMatchObject({ sessions: [] });
    expect(service.journal.replay("host", undefined, after).filter(event => event.kind === "session.deleted")).toHaveLength(1);
    expect(await readFile(nativePath)).toEqual(bytes);
  });
  it("normalizes thinking levels on model changes and passes the cleared value to the driver", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const base = { displayName: "test", contextWindow: 4096, maxTokens: 512, supportsImages: false };
    const provider = await service.providers.create({ name: "test", vendorKey: "levels", type: "openai_compatible", protocol: "openai_compatible", baseUrl: TEST_PROVIDER_URL, authKind: "none", models: [
      { ...base, id: "reason", thinkingLevels: ["high"], defaultThinkingLevel: null },
      { ...base, id: "limited", thinkingLevels: ["off", "low"], defaultThinkingLevel: "low" },
      { ...base, id: "plain", thinkingLevels: [], defaultThinkingLevel: null }
    ] });
    const configure = (params: Record<string, unknown>) => service.handle("session/configure", { sessionId, ...params }, auth);
    await expect(configure({ providerId: provider.id, modelId: "reason", thinkingLevel: "high" })).resolves.toMatchObject({ session: { thinkingLevel: "high" } });
    await expect(configure({ permissionMode: "ask" })).resolves.toMatchObject({ session: { thinkingLevel: "high" } });
    await expect(configure({ modelId: "limited" })).resolves.toMatchObject({ session: { thinkingLevel: "low" } });
    await expect(configure({ modelId: "plain" })).resolves.toMatchObject({ session: { thinkingLevel: null } });
    const { turn } = await service.handle("turn/start", { sessionId, input: { text: "check" } }, auth) as { turn: { id: string } };
    expect(driver.requestFor(turn.id)).toMatchObject({ modelId: "plain", thinkingLevel: undefined });
  });
  it("evicts the same terminal turn from memory and disk", async () => {
    const { config, service, auth, sessionId } = await setup(new ControlledDriver());
    await service.shutdown();
    const path = join(config.dataDir, "meta", "turns.json");
    const turns = Array.from({ length: 1000 }, (_, index) => ({ id: String(index), sessionId, status: "completed", createdAt: new Date(index).toISOString(), settledAt: new Date(index).toISOString() }));
    await writeFile(path, JSON.stringify({ version: 1, turns }));
    const driver = new ControlledDriver();
    const restarted = makeService(config, driver);
    await restarted.init();
    const { turn } = await restarted.handle("turn/start", { sessionId, input: { text: "next" } }, auth) as { turn: { id: string } };
    driver.finishWithoutTerminalEvent(turn.id);
    await vi.waitFor(async () => {
      await expect(restarted.handle("turn/get", { turnId: "0" }, auth)).rejects.toMatchObject({ code: "NOT_FOUND" });
    });
    const disk = JSON.parse(await readFile(path, "utf8")).turns as Array<{ id: string }>;
    expect(disk).toHaveLength(1000);
    expect(disk.map(record => record.id)).not.toContain("0");
  });
  it("rejects unsupported modes without mutating permissions or executing a legacy plan", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const start = vi.spyOn(driver, "start");
    await service.handle("session/configure", { sessionId, permissionMode: "auto" }, auth);
    const before = await service.handle("session/get", { sessionId }, auth);
    await expect(service.handle("session/configure", { sessionId, permissionMode: "accept-edits" }, auth)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    await expect(service.handle("session/create", { mode: "plan" }, auth)).rejects.toMatchObject({ code: "CAPABILITY_UNAVAILABLE" });
    expect(await service.handle("session/get", { sessionId }, auth)).toEqual(before);
    await service.meta.updateSession(sessionId, { mode: "plan" });
    await expect(service.handle("turn/start", { sessionId, input: { text: "legacy" } }, auth)).rejects.toMatchObject({ code: "CAPABILITY_UNAVAILABLE" });
    expect(start).not.toHaveBeenCalled();
  });
  it("registers only directories that still exist and are accessible", async () => {
    const { root, service, auth } = await setup(new ControlledDriver());
    const missing = join(root, "missing");
    const file = join(root, "file");
    await writeFile(file, "test");
    await expect(service.handle("project/register", { path: missing }, auth))
      .rejects.toMatchObject({ code: "NOT_FOUND" });
    await expect(service.handle("project/register", { path: file }, auth))
      .rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    await expect(service.handle("project/register", { path: join(root, "project") + "/." }, auth))
      .resolves.toMatchObject({ project: { path: join(root, "project") } });
    expect(await service.meta.listProjects()).toHaveLength(1);
  });

  it("starts a turn with the complete uploaded image after checksum verification", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const attachmentId = await uploadPng(service, auth, sessionId);
    const { turn } = await service.handle("turn/start", {
      sessionId, input: { text: "", attachments: [attachmentId] }
    }, auth) as { turn: { id: string } };
    expect(driver.requestFor(turn.id)?.images).toEqual([
      { type: "image", data: PNG_BASE64, mimeType: "image/png" }
    ]);
  });

  it("releases the turn slot and accepts the same request after a failed reservation write", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const start = vi.spyOn(driver, "start");
    const store = Reflect.get(service, "turnStore") as TurnStore;
    vi.spyOn(store, "upsert").mockRejectedValueOnce(new Error("disk full"));
    const params = {
      sessionId,
      input: { text: "retry this message" },
      context: { idempotencyKey: "turn-write-retry-test" }
    };

    await expect(service.handle("turn/start", params, auth)).rejects.toMatchObject({ code: "CAPABILITY_UNAVAILABLE" });
    expect(start).not.toHaveBeenCalled();
    await expect(service.handle("session/get", { sessionId }, auth))
      .resolves.toMatchObject({ session: { activeTurnId: null, nativePath: null } });
    await expect(service.handle("turn/start", params, auth)).resolves.toMatchObject({ turn: { status: "running" } });
    expect(start).toHaveBeenCalledTimes(1);
  });

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
  it("publishes a terminal event once when different idempotency keys stop the same turn", async () => {
    const driver = new ControlledDriver();
    const start = vi.spyOn(driver, "start");
    const { service, auth, sessionId } = await setup(driver);
    const started = await service.handle("turn/start", { sessionId, input: { text: "one" } }, auth) as { turn: { id: string } };
    const abort = vi.spyOn(start.mock.results[0]!.value, "abort");
    const after = service.journal.currentCursor();
    const responses = await Promise.all(["first-stop", "second-stop"].map(idempotencyKey =>
      service.handle("turn/cancel", { turnId: started.turn.id, context: { idempotencyKey } }, auth)
    ));
    for (const response of responses) expect(response).toMatchObject({ turn: { status: "canceled" } });
    expect(abort).toHaveBeenCalledTimes(1);
    const completed = service.journal.replay("session", sessionId, after)
      .filter(event => event.kind === "turn.completed" && event.turnId === started.turn.id);
    expect(completed).toHaveLength(1);
  });

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
    const restarted = makeService(config, new ControlledDriver());
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
  it("shows only the active branch but retains attachments from inactive branches", async () => {
    const { service, auth, config, sessionId } = await setup(new ControlledDriver());
    const file = await service.catalog.createFile(config.home, join(config.dataDir, "sessions"), sessionId);
    await service.meta.updateSession(sessionId, { nativePath: file });
    const attachment = await service.blobs.importImageBase64({ sessionId, dataBase64: PNG_BASE64, mimeType: "image/png", fileName: "sibling.png", kind: "input", now: new Date(0) });
    for (const [id, parentId] of [["root", null], ["old", "root"], ["current", "root"]]) {
      const content = id === "old" ? [{ type: "image", mimeType: "image/png", data: PNG_BASE64 }] : id;
      await appendFile(file, JSON.stringify({ type: "message", id, parentId, timestamp: new Date().toISOString(), message: { role: "user", content, timestamp: Date.now() } }) + "\n");
    }
    const expected = [{ id: "root" }, { id: "current" }];
    await expect(service.handle("session/attach", { sessionId }, auth)).resolves.toMatchObject({ snapshot: { items: expected } });
    await expect(service.handle("session/history", { sessionId }, auth)).resolves.toMatchObject({ items: expected });
    await expect(service.handle("session/history", { sessionId, textRange: { itemId: "old", offset: 0 } }, auth)).rejects.toMatchObject({ code: "NOT_FOUND" });
    await service.runMaintenance();
    expect((await service.blobs.read(attachment.id, 0, 1024)).dataBase64).toBe(PNG_BASE64);
  });

  it("isolates missing history while reclaiming expired uploads and unrelated orphan media", async () => {
    const { service, config, sessionId } = await setup(new ControlledDriver());
    await service.meta.updateSession(sessionId, { nativePath: join(config.home, "missing.jsonl") });
    const image = { sessionId, dataBase64: PNG_BASE64, mimeType: "image/png", fileName: "keep.png", kind: "input" as const, now: new Date(0) };
    const keep = await service.blobs.importImageBase64(image);
    const orphan = await service.blobs.importImageBase64({ ...image, sessionId: "unrelated", dataBase64: Buffer.from("fixture").toString("base64") });
    const pending = await service.blobs.create({ sessionId, fileName: "part.png", mimeType: "image/png", byteLength: 1, sha256: "0".repeat(64) }, new Date(0));
    expect(await service.runMaintenance()).toBe(2);
    await expect(readFile(join(config.dataDir, "staging", `${pending.id}.part`))).rejects.toMatchObject({ code: "ENOENT" });
    await expect(service.blobs.read(orphan.id, 0, 1024)).rejects.toMatchObject({ code: "NOT_FOUND" });
    expect((await service.blobs.read(keep.id, 0, 1024)).dataBase64).toBe(PNG_BASE64);
  });
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
    const root = await makeTempDirectory("pi-adaptor-skill-hash-");
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
    } catch (error) {
      // Only a genuinely absent file is acceptable; permission/I/O errors must
      // fail the test instead of silently passing the "no token" assertion.
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
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
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    expect(fileContent).not.toContain(first.token);
    expect(fileContent).not.toContain("ppt2.");
  });
});

describe("queued turn independent cancellation", () => {
  it("cancels a promoted turn before driver start and runs the next queued turn", async () => {
    const driver = new ControlledDriver();
    const start = vi.spyOn(driver, "start");
    const { service, auth, sessionId } = await setup(driver);
    const submit = async (text: string, admission?: string) => (await service.handle("turn/start", {
      sessionId, input: { text }, admission
    }, auth) as { turn: { id: string; status: string } }).turn;
    const first = await submit("first");
    const promoted = await submit("second", "queue");
    const next = await submit("third", "queue");

    let releaseSkills!: () => void;
    const skillsReady = new Promise<void>(resolve => { releaseSkills = resolve; });
    const readSkills = vi.spyOn(service.skills, "activeSkills").mockImplementationOnce(async () => {
      await skillsReady;
      return [];
    });
    try {
      driver.finishWithoutTerminalEvent(first.id);
      await vi.waitFor(() => expect(readSkills).toHaveBeenCalledTimes(1));
      await waitForTurnStatus(service, auth, promoted.id, "running");
      expect(start).toHaveBeenCalledTimes(1);
      await expect(service.handle("turn/cancel", { turnId: promoted.id }, auth))
        .resolves.toMatchObject({ turn: { status: "canceled" } });
    } finally {
      releaseSkills();
    }
    await vi.waitFor(() => expect(driver.requestFor(next.id)).toBeDefined());
    await waitForTurnStatus(service, auth, next.id, "running");
    expect(start.mock.calls.map(([request]) => request.turnId)).toEqual([first.id, next.id]);
  });

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
  it("reattaches to a bounded approval and requires the reviewed input for allowance", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const { turn } = await service.handle("turn/start", { sessionId, input: { text: "review fixture" } }, auth) as { turn: { id: string } };
    const input = { description: "示例参数".repeat(60_000) };
    const expected = Buffer.from(JSON.stringify(input));
    const approvalDecision = driver.requestFor(turn.id)!.requestApproval!("fixture_tool", input);
    const getApproval = async () => {
      const attach = await service.handle("session/attach", { sessionId }, auth) as {
        snapshot: { pendingApprovals: Array<{ id: string; revision: number; inputByteLength: number; input: unknown }> }
      };
      return attach.snapshot.pendingApprovals[0];
    };
    const approval = await vi.waitFor(async () => {
      const pending = await getApproval();
      expect(pending).toBeDefined();
      return pending!;
    });
    expect(approval.inputByteLength).toBe(expected.length);
    expect(Buffer.byteLength(JSON.stringify(approval))).toBeLessThan(4_096);
    const events = service.journal.replay("session", sessionId, { epoch: service.journal.epoch, sequence: 0 });
    expect(events.find(event => event.kind === "approval.requested")?.payload.approval).toEqual(approval);
    const decision = { approvalId: approval.id, decision: "allow-once", expectedRevision: approval.revision };
    await expect(service.handle("approval/respond", decision, auth)).rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    const read = { sessionId, approvalId: approval.id, revision: approval.revision, offset: 0 };
    await expect(service.handle("approval/read", { ...read, revision: approval.revision + 1 }, auth)).rejects.toMatchObject({ code: "APPROVAL_STALE" });
    const parts: Buffer[] = [];
    for (let offset = 0; offset < expected.length;) {
      const chunk = await service.handle("approval/read", { ...read, offset }, auth) as { dataBase64: string; totalBytes: number };
      expect(chunk.totalBytes).toBe(expected.length);
      const bytes = Buffer.from(chunk.dataBase64, "base64");
      expect(bytes.length).toBe(Math.min(expected.length - offset, 64 * 1024));
      parts.push(bytes);
      offset += bytes.length;
    }
    const full = Buffer.concat(parts);
    expect(full.equals(expected)).toBe(true);
    await service.handle("approval/respond", { ...decision, inputDigest: createHash("sha256").update(full).digest("hex") }, auth);
    await expect(approvalDecision).resolves.toBe(true);
    await expect(service.handle("approval/read", read, auth)).rejects.toMatchObject({ code: "NOT_FOUND" });
  });

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
  it("restores a bounded snapshot while keeping the full queued instruction for execution", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const first = await service.handle("turn/start", { sessionId, input: { text: "first" } }, auth) as {
      turn: { id: string }
    };
    const queuedText = "q".repeat(1023) + "会话".repeat(100_000);
    const queued = await service.handle("turn/start", {
      sessionId, admission: "queue", input: { text: queuedText }
    }, auth) as { turn: { id: string; status: string } };
    expect(queued.turn.status).toBe("queued");
    driver.requestFor(first.turn.id)!.onEvent({
      kind: "item.delta", payload: { itemId: "streaming-fixture", delta: "s".repeat(600 * 1024) }
    });

    await vi.waitFor(async () => {
      const result = await service.handle("session/attach", { sessionId }, auth) as {
        snapshot: { activeItems: Array<{ text: string }>; queuedTurns: Array<{ id: string; text: string }> }
      };
      expect(result.snapshot.activeItems[0]?.text).toMatch(/^s+\n…$/);
      expect(result.snapshot.queuedTurns).toMatchObject([{ id: queued.turn.id, text: "q".repeat(1023) + "\n…" }]);
      expect(Buffer.byteLength(JSON.stringify(result), "utf8")).toBeLessThan(512 * 1024);
    });
    driver.finishWithoutTerminalEvent(first.turn.id);
    await vi.waitFor(() => expect(driver.requestFor(queued.turn.id)?.text).toBe(queuedText));
  });

  it("assigns distinct revisions to concurrent session changes", async () => {
    const { service, auth, sessionId } = await setup(new ControlledDriver());
    const changes = await Promise.all([
      service.handle("session/rename", { sessionId, title: "renamed" }, auth),
      service.handle("session/configure", { sessionId, permissionMode: "auto" }, auth),
      service.handle("session/archive", { sessionId, archived: true }, auth)
    ]) as Array<{ session: { revision: number } }>;
    expect(changes.map(result => result.session.revision).sort()).toEqual([2, 3, 4]);
    await expect(service.meta.getSession(sessionId))
      .resolves.toMatchObject({ revision: 4, title: "renamed", permissionMode: "auto", archived: true });
  });

  it("returns the renamed native title and timestamp from session/list without replacing Host settings", async () => {
    const { service, config, auth } = await setup(new ControlledDriver());
    const sessionId = "native-listed";
    const path = await service.catalog.createFile(config.home, join(config.dataDir, "sessions"), sessionId);
    const list = async () => ((await service.handle("session/list", {}, auth)) as { sessions: Array<{ id: string; revision: number }> }).sessions.find(session => session.id === sessionId)!;
    await list();
    await service.handle("session/configure", { sessionId, permissionMode: "auto", modelId: "selected" }, auth);
    await service.handle("session/archive", { sessionId, archived: true }, auth);
    await appendFile(path, JSON.stringify({ type: "session_info", id: "name", parentId: null, name: "Native rename", timestamp: new Date().toISOString() }) + "\n");
    const changed = new Date(Math.ceil(Date.now() / 1000) * 1000 + 5000);
    await utimes(path, changed, changed);
    const summary = await list();
    expect(summary).toMatchObject({ title: "Native rename", updatedAt: changed.toISOString(), permissionMode: "auto", modelId: "selected", archived: true });
    expect((await list()).revision).toBe(summary.revision);
  });

  it("keeps a concurrently saved config during a native session list refresh", async () => {
    const { service, auth, config, sessionId } = await setup(new ControlledDriver());
    const session = (await service.meta.getSession(sessionId))!;
    const nativePath = await service.catalog.createFile(session.projectPath, join(config.dataDir, "sessions"), sessionId);
    await service.meta.updateSession(sessionId, { nativePath });

    const listSessions = service.meta.listSessions.bind(service.meta);
    vi.spyOn(service.meta, "listSessions").mockImplementationOnce(async (...args) => {
      const snapshot = await listSessions(...args);
      await service.handle("session/configure", { sessionId, permissionMode: "auto" }, auth);
      return snapshot;
    });
    await service.handle("session/list", {}, auth);

    await expect(service.handle("session/get", { sessionId }, auth))
      .resolves.toMatchObject({ session: { permissionMode: "auto", revision: 2 } });
  });

  it("preserves session files and sidecars when native history no longer matches the catalog", async () => {
    const { service, auth, sessionId, config } = await setup(new ControlledDriver());
    const session = (await service.meta.getSession(sessionId))!;
    const file = await service.catalog.createFile(session.projectPath, join(config.dataDir, "sessions"), sessionId);
    const original = await readFile(file, "utf8");
    await service.meta.updateSession(sessionId, { nativePath: file });
    const attachmentId = await uploadPng(service, auth, sessionId);
    const createdAt = new Date().toISOString();
    await service.extensionSnapshots.put({
      id: "snapshot", hostId: service.hostId, sessionId, turnId: "ended", configRevision: "fixture",
      revision: 1, startedAt: createdAt, completedAt: createdAt, phase: "ready", entries: [], diagnostics: []
    });
    const replacement = JSON.stringify({ ...JSON.parse(original), id: "replacement-session" }) + "\n";
    await writeFile(file, replacement);

    const deleteParams = { sessionId, confirmSessionId: sessionId };
    await expect(service.handle("session/delete", deleteParams, auth))
      .rejects.toMatchObject({ code: "SESSION_READ_ONLY", message: "external_write_conflict" });
    expect(await readFile(file, "utf8")).toBe(replacement);
    await expect(service.blobs.readForTurn(attachmentId, sessionId)).resolves.toMatchObject({ dataBase64: PNG_BASE64 });
    await expect(service.extensionSnapshots.get(sessionId)).resolves.toMatchObject({ latestAttempt: { id: "snapshot" } });
    await expect(service.handle("session/get", { sessionId }, auth)).resolves.toMatchObject({ session: { id: sessionId } });

    await writeFile(file, original);
    await expect(service.handle("session/delete", deleteParams, auth)).resolves.toEqual({ deleted: true, sessionId });
    await expect(readFile(file, "utf8")).rejects.toMatchObject({ code: "ENOENT" });
    await expect(service.extensionSnapshots.get(sessionId)).resolves.toMatchObject({ latestAttempt: null });
  });

  it("keeps damaged native sessions readable and rechecks writability on reopen", async () => {
    const { service, auth, sessionId, config } = await setup(new ControlledDriver());
    const session = (await service.meta.getSession(sessionId))!;
    const file = await service.catalog.createFile(session.projectPath, join(config.dataDir, "sessions"), sessionId);
    await service.catalog.appendUserMessage(file, "retained");
    await service.meta.updateSession(sessionId, { nativePath: file });
    const valid = await readFile(file, "utf8");
    const truncated = valid + '{"type":"message"';
    await writeFile(file, truncated);

    await expect(service.handle("session/attach", { sessionId }, auth)).resolves.toMatchObject({
      session: { readOnlyReason: "append_unverified" }, snapshot: { items: [{ text: "retained" }] }
    });
    await expect(service.handle("turn/start", { sessionId, input: { text: "new" } }, auth))
      .rejects.toMatchObject({ code: "SESSION_READ_ONLY" });
    expect(await readFile(file, "utf8")).toBe(truncated);

    const [header, ...entries] = valid.split("\n");
    await writeFile(file, [JSON.stringify({ ...JSON.parse(header!), id: "other-session" }), ...entries].join("\n"));
    await expect(service.handle("session/history", { sessionId }, auth))
      .rejects.toMatchObject({ code: "SESSION_READ_ONLY" });
    await expect(service.handle("session/attach", { sessionId }, auth)).resolves.toMatchObject({
      session: { readOnlyReason: "external_write_conflict" }, snapshot: { items: [] }
    });

    await writeFile(file, valid);
    await expect(service.handle("session/attach", { sessionId }, auth)).resolves.toMatchObject({ session: { readOnlyReason: null } });
    await expect(service.handle("turn/start", { sessionId, input: { text: "after restore" } }, auth))
      .resolves.toMatchObject({ turn: { status: "running" } });
    const read = vi.spyOn(service.catalog, "historyForAttach")
      .mockResolvedValueOnce({ entries: [], readOnlyReason: "external_write_conflict" });
    await expect(service.handle("session/attach", { sessionId }, auth)).resolves.toMatchObject({
      session: { readOnlyReason: null }, snapshot: { items: [{ text: "retained" }] }
    });
    expect(read).toHaveBeenCalledTimes(2);
    read.mockRestore();
  });

  it("bounds large live and replayed tool results while preserving their full history text", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const { subscriptionId, starting } = await service.handle("events/subscribe", { scope: "session", sessionId }, auth) as {
      subscriptionId: string; starting: { epoch: string; sequence: number };
    };
    const events: HostEvent[] = [];
    service.setSubscriptionSink(subscriptionId, event => events.push(event));
    const { turn } = await service.handle("turn/start", { sessionId, input: { text: "fixture" } }, auth) as { turn: { id: string } };
    const request = driver.requestFor(turn.id)!;
    const text = "🧪工具\n".repeat(40_000);
    const content = [{ type: "text", text }];
    const itemId = "tool-call-fixture";
    const message = { role: "toolResult", content, toolCallId: itemId, toolName: "fixture", isError: false, timestamp: Date.now() };
    await appendFile(request.sessionFile!, JSON.stringify({
      type: "message", id: "native-tool-entry", parentId: null, timestamp: new Date().toISOString(), message
    }) + "\n");

    request.onEvent({ kind: "tool.started", payload: { itemId, toolName: message.toolName, input: {} } });
    const historyItemId = "native-tool-entry";
    request.onEvent({ kind: "tool.completed", payload: { itemId, historyItemId, status: "completed", result: { content } } });
    request.onEvent({ kind: "item.completed", payload: { item: { id: itemId, historyItemId, itemType: "tool", role: message.role, text, content: message } } });
    driver.finishWithoutTerminalEvent(turn.id);
    await vi.waitFor(() => expect(events.some(event => event.kind === "turn.completed")).toBe(true));
    const results = events.filter(event => event.kind === "tool.completed" || event.kind === "item.completed");
    expect(results).toHaveLength(2);
    for (const event of results) expect(Buffer.byteLength(JSON.stringify(event))).toBeLessThan(32 * 1024);
    expect(results[0]?.payload).toMatchObject({ itemId, result: { historyItemId, textByteLength: Buffer.byteLength(text) } });
    expect(results[1]?.payload).toMatchObject({ item: { id: itemId, historyItemId, textByteLength: Buffer.byteLength(text) } });
    expect(service.journal.replay("session", sessionId, starting)).toEqual(events);

    for (const id of [itemId, historyItemId]) {
      const chunks: Buffer[] = [];
      for (let offset = 0; offset < Buffer.byteLength(text);) {
        const { textChunk } = await service.handle("session/history", { sessionId, textRange: { itemId: id, offset } }, auth) as {
          textChunk: { dataBase64: string; totalBytes: number };
        };
        const chunk = Buffer.from(textChunk.dataBase64, "base64");
        expect(textChunk.totalBytes).toBe(Buffer.byteLength(text));
        expect(chunk.length).toBeGreaterThan(0);
        chunks.push(chunk);
        offset += chunk.length;
      }
      expect(Buffer.concat(chunks).toString("utf8")).toBe(text);
    }
  });

  it("keeps the native lookup after a long assistant completion replaces its live text", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId } = await setup(driver);
    const { subscriptionId, starting } = await service.handle("events/subscribe", { scope: "session", sessionId }, auth) as {
      subscriptionId: string; starting: { epoch: string; sequence: number };
    };
    const events: HostEvent[] = [];
    service.setSubscriptionSink(subscriptionId, event => events.push(event));
    const { turn } = await service.handle("turn/start", { sessionId, input: { text: "fixture" } }, auth) as { turn: { id: string } };
    const request = driver.requestFor(turn.id)!;
    const id = "live-assistant";
    const historyItemId = "native-assistant";
    const text = "甲乙🧪\n".repeat(30_000);
    const message = { role: "assistant", content: [{ type: "text", text }], timestamp: Date.now(), stopReason: "stop" };
    await appendFile(request.sessionFile!, JSON.stringify({
      type: "message", id: historyItemId, parentId: null, timestamp: new Date().toISOString(), message
    }) + "\n");
    request.onEvent({ kind: "item.delta", payload: { itemId: id, itemType: "message", delta: "甲" } });
    request.onEvent({ kind: "item.completed", payload: { item: { id, historyItemId, itemType: "message", role: message.role, text, content: message } } });
    driver.finishWithoutTerminalEvent(turn.id);
    await vi.waitFor(() => expect(events.some(event => event.kind === "turn.completed")).toBe(true));

    const completion = events.find(event => event.kind === "item.completed");
    expect(completion?.payload).toMatchObject({ item: { id, historyItemId, textByteLength: Buffer.byteLength(text) } });
    expect(Buffer.byteLength(JSON.stringify(completion))).toBeLessThan(32 * 1024);
    expect(service.journal.replay("session", sessionId, starting)).toContainEqual(completion);
    const { textChunk } = await service.handle("session/history", { sessionId, textRange: { itemId: historyItemId, offset: 0 } }, auth) as {
      textChunk: { dataBase64: string; totalBytes: number };
    };
    expect(textChunk.totalBytes).toBe(Buffer.byteLength(text));
    expect(Buffer.from(textChunk.dataBase64, "base64")).toEqual(Buffer.from(text).subarray(0, 64 * 1024));
  });

  it("keeps a large history item readable and returns its full UTF-8 text in chunks", async () => {
    const { service, auth, config, sessionId } = await setup(new ControlledDriver());
    const session = (await service.meta.getSession(sessionId))!;
    const nativePath = await service.catalog.createFile(session.projectPath, join(config.dataDir, "sessions"), sessionId);
    const text = "a".repeat(65_535) + "🧪" + "你好".repeat(40_000);
    const timestamp = new Date().toISOString();
    const entries = [
      { type: "message", id: "older", parentId: null, timestamp, message: { role: "user", content: "earlier", timestamp: Date.now() } },
      { type: "message", id: "large", parentId: "older", timestamp, message: { role: "user", content: text, timestamp: Date.now() } }
    ];
    await appendFile(nativePath, entries.map((entry) => JSON.stringify(entry)).join("\n") + "\n");
    await service.meta.updateSession(sessionId, { nativePath });

    const attached = await service.handle("session/attach", { sessionId }, auth) as {
      snapshot: { items: { id: string; text: string; textByteLength?: number }[] }
    };
    const item = attached.snapshot.items.at(-1)!;
    const fullBytes = Buffer.byteLength(text);
    expect(item).toMatchObject({ id: "large", textByteLength: fullBytes });
    expect(Buffer.byteLength(item.text)).toBeLessThan(10 * 1024);
    await expect(service.handle("session/history", { sessionId, beforeItemId: "large" }, auth))
      .resolves.toMatchObject({ items: [{ id: "older", text: "earlier" }] });

    const historySnapshot = vi.spyOn(service.catalog as unknown as {
      historySnapshot: (...args: string[]) => Promise<unknown>;
    }, "historySnapshot");
    const chunks: Buffer[] = [];
    for (let offset = 0; offset < fullBytes;) {
      const result = await service.handle("session/history", { sessionId, textRange: { itemId: item.id, offset } }, auth) as {
        textChunk: { dataBase64: string; totalBytes: number }
      };
      const chunk = Buffer.from(result.textChunk.dataBase64, "base64");
      expect(result.textChunk.totalBytes).toBe(fullBytes);
      expect(chunk.length).toBeGreaterThan(0);
      expect(chunk.length).toBeLessThanOrEqual(64 * 1024);
      chunks.push(chunk);
      offset += chunk.length;
    }
    expect(Buffer.concat(chunks).toString("utf8")).toBe(text);
    expect(historySnapshot).toHaveBeenCalledTimes(1);
    await expect(service.handle("session/history", {
      sessionId, textRange: { itemId: item.id, offset: fullBytes }
    }, auth)).resolves.toMatchObject({ textChunk: { dataBase64: "", totalBytes: fullBytes } });
    expect(historySnapshot).toHaveBeenCalledTimes(1);

    const fullHistory = await readFile(nativePath, "utf8");
    const revised = "b" + text.slice(1);
    await writeFile(nativePath, fullHistory.replace(JSON.stringify(text), JSON.stringify(revised)));
    await expect(service.handle("session/history", {
      sessionId, textRange: { itemId: item.id, offset: 0 }
    }, auth)).resolves.toMatchObject({ textChunk: {
      dataBase64: Buffer.from(revised, "utf8").subarray(0, 64 * 1024).toString("base64"), totalBytes: fullBytes
    } });
    expect(historySnapshot).toHaveBeenCalledTimes(2);
  });

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
  it("rejects stale or missing credential bindings before starting a turn", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId, providerBinding } = await setup(driver, { provider: "api_key" });
    const providerId = await createTestProvider(service, auth, "api_key", "destination");
    await service.handle("session/configure", { sessionId, providerId }, auth);
    const start = vi.spyOn(driver, "start");
    const params = { sessionId, apiKey: TEST_TRANSIENT_KEY, input: { text: "fixture" } };
    await expect(service.handle("turn/start", { ...params, providerBinding }, auth))
      .rejects.toMatchObject({ code: "CONFLICT" });
    await expect(service.handle("turn/start", {
      ...params, providerBinding: { providerId, baseUrl: TEST_PROVIDER_URL + "/old" }
    }, auth)).rejects.toMatchObject({ code: "CONFLICT" });
    await expect(service.handle("turn/start", params, auth))
      .rejects.toMatchObject({ code: "INVALID_ARGUMENT" });
    expect(start).not.toHaveBeenCalled();
    await service.handle("turn/start", {
      ...params, providerBinding: { providerId, baseUrl: TEST_PROVIDER_URL }
    }, auth);
    expect(start).toHaveBeenCalledTimes(1);
  });

  it("never launches a queued turn with the previous provider's key after a provider change", async () => {
    const driver = new ControlledDriver();
    const { service, auth, sessionId, providerId, providerBinding } = await setup(driver, { provider: "api_key" });
    const nextProviderId = await createTestProvider(service, auth, "api_key", "mock-second");
    expect(nextProviderId).not.toBe(providerId);
    const first = await service.handle("turn/start", {
      sessionId, input: { text: "first" }, apiKey: TEST_TRANSIENT_KEY, providerBinding
    }, auth) as { turn: { id: string } };
    const queued = await service.handle("turn/start", {
      sessionId, input: { text: "queued" }, apiKey: TEST_TRANSIENT_KEY, providerBinding, admission: "queue"
    }, auth) as { turn: { id: string; status: string } };
    expect(queued.turn.status).toBe("queued");
    const subscription = await service.handle("events/subscribe", { scope: "session", sessionId }, auth) as {
      subscriptionId: string
    };
    const sink = vi.fn();
    service.setSubscriptionSink(subscription.subscriptionId, sink);

    await service.handle("session/configure", { sessionId, providerId: nextProviderId, modelId: "mock-model" }, auth);
    driver.finishWithoutTerminalEvent(first.turn.id);
    await waitForTurnStatus(service, auth, queued.turn.id, "failed");
    expect(driver.requestFor(queued.turn.id)).toBeUndefined();
    await vi.waitFor(() => expect(sink).toHaveBeenCalledWith(expect.objectContaining({
      turnId: queued.turn.id, kind: "turn.failed",
      payload: expect.objectContaining({ turn: expect.objectContaining({ settledReason: "queue_start_failed" }) })
    })));
  });

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
    const { service, auth, sessionId, config, providerBinding } = await setup(driver, { provider: "api_key" });
    const started = (await service.handle(
      "turn/start",
      { sessionId, apiKey: TEST_TRANSIENT_KEY, providerBinding, input: { text: "hello" } },
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
    const { service, auth, sessionId, config, providerBinding } = await setup(new ControlledDriver(), { provider: "api_key" });
    const firstKey = "sk-first-transient-key";
    const secondKey = "sk-second-transient-key";
    const first = (await service.handle(
      "turn/start",
      {
        sessionId,
        apiKey: firstKey,
        providerBinding,
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
        providerBinding,
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
    const { service, auth, sessionId, config, providerBinding } = await setup(driver, { provider: "api_key" });
    await service.handle(
      "turn/start",
      { sessionId, apiKey: TEST_TRANSIENT_KEY, providerBinding, input: { text: "first" } },
      auth
    );
    const attachmentId = await uploadPng(service, auth, sessionId);
    const queued = (await service.handle(
      "turn/start",
      {
        sessionId,
        admission: "queue",
        apiKey: TEST_TRANSIENT_KEY,
        providerBinding,
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

    const restarted = makeService(config, new DeterministicAgentDriver());
    expect(await restarted.init()).toEqual({ removedLegacySecrets: 2 });
    await expect(readdir(secretsDir)).rejects.toMatchObject({ code: "ENOENT" });

    const second = makeService(config, new DeterministicAgentDriver());
    expect(await second.init()).toEqual({ removedLegacySecrets: 0 });
  });
});
