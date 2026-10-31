import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { EventJournal } from "../src/events/journal.js";

describe("event journal", () => {
  it("persists and replays concurrent appends in sequence order", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-events-race-"));
    const journal = new EventJournal(root);
    await journal.load();
    const events = await Promise.all(Array.from({ length: 20 }, (_, i) => journal.append("host", "test", { i })));
    const lines = (await readFile(join(root, "meta", "events.jsonl"), "utf8")).trim().split("\n").map((line) => JSON.parse(line));
    expect(lines.map((event) => event.sequence)).toEqual(events.map((event) => event.sequence));
    expect(journal.replay("host", undefined, { epoch: journal.epoch, sequence: 1 }).map((event) => event.sequence)).toEqual(events.slice(1).map((event) => event.sequence));
  });
  it("replays only events after the cursor and expires old epochs", async () => {
    const root = await mkdtemp(join(tmpdir(), "pi-host-events-"));
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
