import { appendFile, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";
import * as storage from "../src/util/json-file.js";
import { EventJournal } from "../src/events/journal.js";

describe("event journal", () => {
  it("repairs only the active suffix and preserves a complete unterminated record", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-tail-"));
    const journal = new EventJournal(root);
    await journal.load();
    const path = join(root, "meta", "events.jsonl");
    const line = (sequence: number) => JSON.stringify({ sequence, kind: "test", scope: "host", payload: {} });
    await writeFile(`${path}.1`, line(1) + "\n");
    await writeFile(path, line(2));
    await journal.load();
    await journal.append("host", "test", {});
    await appendFile(path, '{"sequence":');
    await journal.load();
    await journal.load();
    expect(journal.replay("host", undefined, { epoch: journal.epoch, sequence: 0 }).map(event => event.sequence)).toEqual([1, 2, 3]);
  });

  it("does not reuse an occupied sequence after directory sync failure", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-sync-"));
    const journal = new EventJournal(root);
    await journal.load();
    const sync = vi.spyOn(storage, "syncDirectory").mockRejectedValueOnce(new Error("sync failed"));
    try { await expect(journal.append("session", "turn.failed", {})).rejects.toThrow("sync failed"); }
    finally { sync.mockRestore(); }
    await journal.append("host", "host.changed", {});
    await journal.append("session", "turn.failed", {});
    await journal.load();
    const rows = (await readFile(join(root, "meta", "events.jsonl"), "utf8")).trim().split("\n").map(line => JSON.parse(line));
    expect(rows.map(entry => entry.sequence)).toEqual([1, 2]);
  });

  it("remembers unconfirmed terminals after memory and disk rotation across restart", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-terminal-"));
    const journal = new EventJournal(root, 1, 128, 1);
    await journal.load();
    await journal.append("session", "turn.failed", {}, { sessionId: "session", turnId: "pending" });
    await journal.append("host", "session.deleted", {}, { sessionId: "gone" });
    for (let index = 0; index < 5; index++) await journal.append("host", "test", { index });
    const restarted = new EventJournal(root, 1, 128, 1);
    await restarted.load(new Set(["pending", "deleted:gone"]));
    expect(restarted.hasTransition("session.deleted", "gone")).toBe(true);
    restarted.confirmTransition("deleted:gone");
    expect(restarted.hasTransition("session.deleted", "gone")).toBe(false);
    expect(restarted.hasTransition("turn.failed", "session", "pending")).toBe(true);
    restarted.confirmTransition("pending");
    expect(restarted.hasTransition("turn.failed", "session", "pending")).toBe(false);
  });
  it("persists and replays concurrent appends in sequence order", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-events-race-"));
    const journal = new EventJournal(root);
    await journal.load();
    const events = await Promise.all(Array.from({ length: 20 }, (_, i) => journal.append("host", "test", { i })));
    const lines = (await readFile(join(root, "meta", "events.jsonl"), "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(lines.map((event) => event.sequence)).toEqual(events.map((event) => event.sequence));
    expect(journal.replay("host", undefined, { epoch: journal.epoch, sequence: 1 }).map((event) => event.sequence)).toEqual(events.slice(1).map((event) => event.sequence));
  });
  it("replays only events after the cursor and expires old epochs", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-adaptor-events-"));
    const journal = new EventJournal(root);
    await journal.load();
    const first = await journal.append("session", "turn.started", { turn: {} }, { sessionId: "s1" });
    await journal.append("session", "item.delta", { delta: "a" }, { sessionId: "s1" });
    await journal.append("session", "item.delta", { delta: "b" }, { sessionId: "s2" });
    const replayed = journal.replay("session", "s1", { epoch: journal.epoch, sequence: first.sequence! });
    expect(replayed).toHaveLength(1);
    expect(() => journal.replay("session", "s1", { epoch: "old", sequence: 1 })).toThrow();
  });
});
