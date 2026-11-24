import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import { describe, expect, it } from "vitest";
import { NativeSessionCatalog, openNativeSessionForWrite } from "../src/pi/session-catalog.js";

describe("native session catalog", () => {
  it("preserves a truncated native file and blocks writes to it", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-tail-"));
    try {
      const catalog = new NativeSessionCatalog([root]);
      const file = await catalog.createFile(root, root, "session");
      const before = (await readFile(file, "utf8")) + '{"type":"message"';
      await writeFile(file, before);
      expect(await catalog.scan()).toMatchObject([{ id: "session", readOnlyReason: "append_unverified" }]);
      expect(await catalog.history(file)).toEqual([]);
      await expect(catalog.appendUserMessage(file, "after")).rejects.toMatchObject({ code: "SESSION_READ_ONLY" });
      expect(await readFile(file, "utf8")).toBe(before);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("blocks a stale writer when a native Pi writer advances the leaf", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-leaf-"));
    try {
      const catalog = new NativeSessionCatalog([root]);
      const file = await catalog.createFile(root, root, "session");
      const host = await openNativeSessionForWrite(file, "session");
      const external = SessionManager.open(file);
      const entry = external.appendMessage({ role: "user", content: "external entry", timestamp: 1 });
      const saved = await readFile(file, "utf8");
      expect(() => host.appendMessage({ role: "user", content: "stale entry", timestamp: 2 })).toThrow("external_write_conflict");
      expect(await readFile(file, "utf8")).toBe(saved);
      expect(SessionManager.open(file).getLeafId()).toBe(entry);
    } finally {
      await rm(root, { recursive: true, force: true });
    }
  });

  it("scans, appends, renames, and branches real Pi v3 sessions", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-session-"));
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
