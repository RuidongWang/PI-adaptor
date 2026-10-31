import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { NativeSessionCatalog } from "../src/pi/session-catalog.js";

describe("native session catalog", () => {
  it("scans, appends, renames, and branches real Pi v3 sessions", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-session-"));
    const cwd = join(root, "project");
    const sessions = join(root, "sessions");
    await import("node:fs/promises").then(({ mkdir }) => mkdir(cwd, { recursive: true }));
    const manager = SessionManager.create(cwd, sessions);
    const first = manager.appendMessage({ role: "user", content: "hello", timestamp: 1 });
    manager.appendMessage({
      role: "assistant",
      content: [{ type: "text", text: "world" }],
      timestamp: 2
    } as never);
    const file = manager.getSessionFile();
    expect(file).toBeTruthy();
    const catalog = new NativeSessionCatalog([sessions]);
    const scanned = await catalog.scan();
    expect(scanned).toHaveLength(1);
    expect(scanned[0]?.cwd).toBe(cwd);
    expect(scanned[0]?.title).toBe("hello");

    const before = await readFile(file!, "utf8");
    const result = await catalog.appendUserMessage(file!, "next", 3);
    const after = await readFile(file!, "utf8");
    expect(after.startsWith(before)).toBe(true);
    expect(result.fingerprintBefore).not.toBe(result.fingerprintAfter);

    await catalog.appendSessionInfo(file!, "Renamed");
    expect((await catalog.scan())[0]?.title).toBe("Renamed");
    const child = await catalog.branch(file!, first);
    expect(child).not.toBe(file);
  });
});
