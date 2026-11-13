import { createServer } from "node:http";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { DefaultResourceLoader, SessionManager, AgentSession } from "@earendil-works/pi-coding-agent";
import { PiAgentDriver, type AgentEvent, type AgentTurnRequest } from "../src/agent/driver.js";
import { ExtensionRegistry, parseExtensionsConfig } from "../src/extensions/registry.js";
import type { ExtensionSnapshot } from "../src/extensions/types.js";

const cleanups: Array<() => Promise<unknown>> = [];
afterEach(async () => { vi.restoreAllMocks(); for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); });
// Local scripted OpenAI transport exercises the actual SDK agent/tool/approval path;
// it is deliberately not a real model acceptance test.
export async function driverFixture(options: { hang?: boolean; source?: string } = {}) {
  const root = await mkdtemp(join(tmpdir(), "pi-extensions-driver-"));
  cleanups.push(() => rm(root, { recursive: true, force: true }));
  const agentDir = join(root, "agent"), sessionDir = join(root, "sessions");
  await mkdir(agentDir); await mkdir(sessionDir);
  const entry = join(root, "entry.ts"), marker = join(root, "marker");
  await writeFile(entry, options.source ?? `import { appendFile } from "node:fs/promises";
export default pi => {
  pi.on("session_start", async (_e,ctx) => { await appendFile(${JSON.stringify(marker)}, "start:"+ctx.hasUI+"\\n"); });
  pi.on("session_shutdown", async () => { await new Promise(r => setTimeout(r,25)); await appendFile(${JSON.stringify(marker)}, "shutdown\\n"); });
  pi.registerTool({name:"fixture_tool",label:"Fixture",description:"Fixture",parameters:{type:"object",properties:{}},execute:async()=>{await appendFile(${JSON.stringify(marker)},"execute\\n");return {content:[{type:"text",text:"done"}],details:{}}}});
  pi.registerCommand("fixture_command",{handler:async()=>{}});
}`);
  let calls = 0;
  const server = createServer(async (req, res) => {
    for await (const _ of req) { /* consume body */ }
    calls += 1;
    res.writeHead(200, { "Content-Type": "text/event-stream" });
    if (options.hang) { res.write(': waiting\n\n'); return; }
    const tool = calls % 2 === 1;
    const chunk = (delta: unknown, finish: string | null = null) => res.write(`data: ${JSON.stringify({ id: "fixture", object: "chat.completion.chunk", created: 1, model: "fixture", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`);
    chunk(tool ? { role: "assistant", tool_calls: [{ index: 0, id: "call_fixture", type: "function", function: { name: "fixture_tool", arguments: "{}" } }] } : { role: "assistant", content: "done" });
    chunk({}, tool ? "tool_calls" : "stop"); res.end("data: [DONE]\n\n");
  });
  await new Promise<void>(resolve => server.listen(0, "127.0.0.1", resolve));
  cleanups.push(() => new Promise<void>((resolve, reject) => { server.closeAllConnections(); server.close(error => error ? reject(error) : resolve()); }));
  const address = server.address() as { port: number };
  const registry = new ExtensionRegistry(parseExtensionsConfig({ enabled: true, entries: [{ id: "fixture", entryPath: entry, compatibility: "headless-reviewed" }] }));
  const snapshots: ExtensionSnapshot[] = [], events: AgentEvent[] = [];
  const request: AgentTurnRequest = { turnId: "turn_fixture", sessionId: "session_fixture", cwd: root, sessionDir, text: "call the fixture", images: [], modelId: "fixture", provider: { id: "fixture", name: "Fixture", baseUrl: `http://127.0.0.1:${address.port}/v1`, apiKey: "fixture-secret", models: [{ id: "fixture", displayName: "Fixture", contextWindow: 32768, maxTokens: 1000, thinkingLevels: [], defaultThinkingLevel: null, supportsImages: false }] }, requestApproval: async () => true, extensions: { registry, hostId: "host_fixture", publish: async snapshot => { snapshots.push(structuredClone(snapshot)); } }, onEvent: event => events.push(event) };
  return { root, agentDir, marker, registry, request, snapshots, events, driver: new PiAgentDriver(agentDir), calls: () => calls };
}

describe("extensions driver", () => {
  it.each([true, false])("executes a real SDK extension tool only when approval=%s and cleans two consecutive rounds", async allowed => {
    const fixture = await driverFixture();
    const approve = vi.fn(async () => allowed); fixture.request.requestApproval = approve;
    for (let round = 0; round < 2; round += 1) {
      const handle = fixture.driver.start({ ...fixture.request, turnId: `round_${round}` }); await handle.wait();
      expect(fixture.events.filter(event => event.kind.startsWith("turn.")).map(event => event.kind)).toEqual(Array(round + 1).fill(["turn.started", "turn.completed"]).flat());
      expect((await readFile(fixture.marker, "utf8")).match(/shutdown/g)).toHaveLength(round + 1);
    }
    expect(approve).toHaveBeenCalledTimes(2);
    expect((await readFile(fixture.marker, "utf8")).includes("execute")).toBe(allowed);
    const ready = fixture.snapshots.find(snapshot => snapshot.phase === "ready")!;
    expect(ready.entries).toHaveLength(1);
    expect(ready.entries[0]).toMatchObject({ loadState: "loaded", registeredTools: ["fixture_tool"], activeTools: ["fixture_tool"], registeredCommands: ["fixture_command"], mobileInvocable: false });
    expect(fixture.snapshots[0]).toMatchObject({ phase: "loading", revision: 1, completedAt: null });
    expect(fixture.calls()).toBe(4);
  });
  it("blocks tools if the approval service throws", async () => {
    const fixture = await driverFixture(); fixture.request.requestApproval = async () => { throw new Error("api_key=secret"); };
    await fixture.driver.start(fixture.request).wait();
    expect(await readFile(fixture.marker, "utf8")).not.toContain("execute");
    expect(JSON.stringify(fixture.snapshots)).not.toContain("secret");
  });
  it("waits for shutdown on cancel and does not send a duplicate terminal", async () => {
    const fixture = await driverFixture({ hang: true });
    const handle = fixture.driver.start(fixture.request);
    await vi.waitFor(() => expect(fixture.calls()).toBe(1));
    await handle.abort(); await handle.abort(); await handle.wait();
    expect(await readFile(fixture.marker, "utf8")).toBe("start:false\nshutdown\n");
    expect(fixture.events.filter(event => ["turn.completed", "turn.failed"].includes(event.kind))).toEqual([]);
  });
  it("fails closed before prompt if the internal approval extension is missing", async () => {
    const fixture = await driverFixture();
    const original = DefaultResourceLoader.prototype.getExtensions;
    vi.spyOn(DefaultResourceLoader.prototype, "getExtensions").mockImplementation(function(this: DefaultResourceLoader) { const result = original.call(this); return { ...result, extensions: result.extensions.filter(extension => extension.path !== "<inline:host-approval>") }; });
    await fixture.driver.start(fixture.request).wait();
    expect(fixture.calls()).toBe(0);
    expect(fixture.events.filter(event => event.kind === "turn.failed")).toHaveLength(1);
    expect(fixture.snapshots.at(-1)?.phase).toBe("failed");
  });
  it("reports partial load/startup/cleanup failures without leaking extension errors", async () => {
    const fixture = await driverFixture({ source: 'export default pi => { pi.on("session_start",()=>{throw new Error("token=supersecret\\n at stack")}); pi.on("session_shutdown",()=>{throw new Error("token=supersecret")}); }' });
    const bad = join(fixture.root, "bad.ts"); await writeFile(bad, 'throw new Error("api_key=supersecret")');
    fixture.request.extensions!.registry = new ExtensionRegistry(parseExtensionsConfig({ enabled: true, entries: [{ id: "good", entryPath: join(fixture.root, "entry.ts"), compatibility: "headless-reviewed" }, { id: "bad", entryPath: bad, compatibility: "headless-reviewed" }] }));
    await fixture.driver.start(fixture.request).wait();
    const snapshot = fixture.snapshots.at(-1)!;
    expect(snapshot.phase).toBe("ready");
    expect(snapshot.entries.map(entry => entry.loadState)).toEqual(["loaded", "failed"]);
    expect(snapshot.entries[0]!.diagnostics.map(item => item.stage)).toEqual(["startup", "cleanup"]);
    expect(JSON.stringify(fixture.snapshots)).not.toContain("supersecret");
  });
  it("cleans initialized instances if session creation fails before binding", async () => {
    const fixture = await driverFixture();
    fixture.request.sessionFile = join(fixture.root, "missing-session.jsonl");
    vi.spyOn(SessionManager, "open").mockImplementation(() => { throw new Error("injected session construction failure"); });
    await fixture.driver.start(fixture.request).wait();
    expect(fixture.calls()).toBe(0);
    expect(await readFile(fixture.marker, "utf8")).toBe("shutdown\n");
    expect(fixture.events.filter(event => event.kind === "turn.failed")).toHaveLength(1);
    expect(fixture.snapshots.at(-1)?.phase).toBe("failed");
  });
  it("attributes conflicting registration to its entry and active tools to the actual SDK owner", async () => {
    const fixture = await driverFixture();
    const duplicate = join(fixture.root, "duplicate.ts");
    await writeFile(duplicate, 'export default pi => pi.registerTool({name:"fixture_tool",label:"Duplicate",description:"Duplicate",parameters:{type:"object"},execute:async()=>({content:[],details:{}})})');
    fixture.request.extensions!.registry = new ExtensionRegistry(parseExtensionsConfig({ enabled: true, entries: [{ id: "first", entryPath: join(fixture.root, "entry.ts"), compatibility: "headless-reviewed" }, { id: "second", entryPath: duplicate, compatibility: "headless-reviewed" }] }));
    await fixture.driver.start(fixture.request).wait();
    const entries = fixture.snapshots.at(-1)!.entries;
    expect(entries.map(entry => entry.loadState)).toEqual(["loaded", "loaded"]);
    expect(entries.map(entry => entry.activeTools)).toEqual([["fixture_tool"], []]);
    expect(entries[1]!.diagnostics.some(item => item.code === "REGISTRATION_CONFLICT")).toBe(true);
  });
  it("does not import entries when canceled while the initial loading snapshot is being persisted", async () => {
    const fixture = await driverFixture();
    let release!: () => void;
    const gate = new Promise<void>(resolve => { release = resolve; });
    fixture.request.extensions!.publish = async snapshot => { fixture.snapshots.push(snapshot); if (snapshot.revision === 1) await gate; };
    const handle = fixture.driver.start(fixture.request);
    await vi.waitFor(() => expect(fixture.snapshots).toHaveLength(1));
    const aborted = handle.abort(); release(); await aborted;
    expect(fixture.calls()).toBe(0);
    await expect(readFile(fixture.marker)).rejects.toMatchObject({ code: "ENOENT" });
    expect(fixture.snapshots.at(-1)).toMatchObject({ phase: "failed", diagnostics: [expect.objectContaining({ code: "TURN_CANCELED" })] });
  });
  it("blocks prompt if internal approval startup reports an error", async () => {
    const fixture = await driverFixture();
    const bind = AgentSession.prototype.bindExtensions;
    vi.spyOn(AgentSession.prototype, "bindExtensions").mockImplementation(async function(this: AgentSession, bindings) {
      await bind.call(this, bindings);
      bindings.onError?.({ extensionPath: "<inline:host-approval>", event: "session_start", error: "sensitive fixture detail" });
    });
    await fixture.driver.start(fixture.request).wait();
    expect(fixture.calls()).toBe(0);
    expect(await readFile(fixture.marker, "utf8")).toBe("start:false\nshutdown\n");
    expect(fixture.snapshots.at(-1)?.phase).toBe("failed");
    expect(JSON.stringify(fixture.snapshots)).not.toContain("sensitive fixture detail");
  });
  it("records and aggregates optional runtime hook errors while preserving ready phase", async () => {
    const fixture = await driverFixture({ source: 'export default pi => { pi.on("before_agent_start",()=>{throw new Error("token=hidden")}); pi.on("agent_start",()=>{throw new Error("token=hidden")}); }' });
    await fixture.driver.start(fixture.request).wait();
    const snapshot = fixture.snapshots.at(-1)!;
    expect(snapshot.phase).toBe("ready");
    expect(snapshot.entries[0]!.diagnostics.filter(item => item.stage === "runtime")).toHaveLength(1);
    expect(fixture.snapshots.filter(item => item.revision > 2).length).toBeLessThanOrEqual(21);
    expect(JSON.stringify(fixture.snapshots)).not.toContain("hidden");
  });
});
