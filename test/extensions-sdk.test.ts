import { mkdtemp, mkdir, writeFile, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { DefaultResourceLoader, SettingsManager, ModelRuntime, SessionManager, createAgentSession } from "@earendil-works/pi-coding-agent";

const roots: string[] = [];
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))); });
export async function sdkFixture() {
  const root = await mkdtemp(join(tmpdir(), "pi-extensions-sdk-")); roots.push(root);
  const agentDir = join(root, "agent"); await mkdir(agentDir);
  const settings = SettingsManager.inMemory({ packages: [] });
  return { root, agentDir, settings };
}
describe("extensions SDK 1.3.0", () => {
  it.each(["ts", "js", "mjs"])("loads explicit .%s once with noExtensions, without discovery", async suffix => {
    const { root, agentDir, settings } = await sdkFixture();
    await mkdir(join(root, ".pi", "extensions"), { recursive: true });
    await writeFile(join(root, ".pi", "extensions", "rogue.ts"), 'throw new Error("must not discover")');
    const entry = join(root, `entry.${suffix}`);
    const marker = join(root, "imports");
    await writeFile(entry, `import { appendFileSync } from "node:fs"; appendFileSync(${JSON.stringify(marker)}, "import\\n"); export default pi => { appendFileSync(${JSON.stringify(marker)}, "factory\\n"); pi.registerCommand("fixture", {handler: async () => {}}); }`);
    const loader = new DefaultResourceLoader({ cwd: root, agentDir, settingsManager: settings, noExtensions: true, additionalExtensionPaths: [entry, entry] });
    await loader.reload();
    expect(loader.getExtensions().errors).toEqual([]);
    expect(loader.getExtensions().extensions).toHaveLength(1);
    expect([...loader.getExtensions().extensions[0]!.commands.keys()]).toEqual(["fixture"]);
    expect(await readFile(marker, "utf8")).toBe("import\nfactory\n");
  });
  it("binds startup errors and no UI, exposes tool inventory and requires explicit shutdown before dispose", async () => {
    const { root, agentDir, settings } = await sdkFixture();
    const calls: string[] = [], errors: string[] = [];
    const loader = new DefaultResourceLoader({ cwd: root, agentDir, settingsManager: settings, noExtensions: true, extensionFactories: [{ name: "host-approval", hidden: true, factory(pi) {
      pi.on("session_start", async (_event, ctx) => { calls.push(`start:${ctx.hasUI}:${await ctx.ui.confirm("x", "y")}`); throw new Error("startup fixture"); });
      pi.on("session_shutdown", () => { calls.push("shutdown"); });
      pi.registerTool({ name: "fixture_tool", label: "Fixture", description: "Fixture", parameters: { type: "object", properties: {} }, async execute() { return { content: [{ type: "text", text: "ok" }], details: {} }; } });
    } }] });
    await loader.reload();
    const result = loader.getExtensions();
    expect(result.extensions[0]).toMatchObject({ path: "<inline:host-approval>", hidden: true });
    const runtime = await ModelRuntime.create({ authPath: join(root, "auth.json"), modelsPath: null });
    const { session } = await createAgentSession({ cwd: root, agentDir, modelRuntime: runtime, sessionManager: SessionManager.inMemory(root), settingsManager: settings, resourceLoader: loader });
    await session.bindExtensions({ mode: "rpc", onError: error => errors.push(error.error) });
    expect(calls).toEqual(["start:false:false"]);
    expect(errors).toEqual(["startup fixture"]);
    expect(session.getAllTools().map(tool => tool.name)).toContain("fixture_tool");
    session.setActiveToolsByName([]);
    expect(session.getActiveToolNames()).not.toContain("fixture_tool");
    await session.extensionRunner.emit({ type: "session_shutdown", reason: "quit" });
    session.dispose();
    expect(calls).toEqual(["start:false:false", "shutdown"]);
  });
  it("reports conflicts while retaining both initialized extension instances", async () => {
    const { root, agentDir, settings } = await sdkFixture();
    const paths = [join(root, "a.ts"), join(root, "b.ts")];
    for (const path of paths) await writeFile(path, 'export default pi => pi.registerTool({name:"same",label:"Same",description:"Same",parameters:{type:"object"},execute:async()=>({content:[],details:{}})})');
    const loader = new DefaultResourceLoader({ cwd: root, agentDir, settingsManager: settings, noExtensions: true, additionalExtensionPaths: paths });
    await loader.reload();
    const result = loader.getExtensions();
    expect(result.errors.some(error => /same/.test(error.error))).toBe(true);
    expect(result.extensions).toHaveLength(2);
    expect(result.errors.every(error => paths.includes(error.path))).toBe(true);
  });
});
