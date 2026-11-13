import { appendFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

// Reviewed, per-turn headless fixture. All side effects stay in the isolated test cwd.
const fixture: ExtensionFactory = pi => {
  pi.on("session_start", async (_event, ctx) => {
    await appendFile(join(ctx.cwd, "extension-lifecycle.log"), `start:${ctx.hasUI}\n`);
    pi.setActiveTools(["fixture_tool"]);
  });
  pi.on("session_shutdown", async (_event, ctx) => {
    await new Promise(resolve => setTimeout(resolve, 25));
    await appendFile(join(ctx.cwd, "extension-lifecycle.log"), "shutdown\n");
  });
  for (const name of ["fixture_tool", "inactive_tool"]) pi.registerTool({
    name, label: name, description: "Write an isolated fixture marker", parameters: { type: "object", properties: {} },
    async execute(_id, _params, _signal, _update, ctx) {
      await writeFile(join(ctx.cwd, "extension-executed.marker"), "executed");
      return { content: [{ type: "text", text: "fixture complete" }], details: {} };
    }
  });
  pi.registerCommand("fixture_command", { handler: async () => {} });
};
export default fixture;
