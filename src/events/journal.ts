import { appendFile, mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { HostError } from "../errors.js";
import { uuid } from "../util/id.js";

export type Cursor = { epoch: string; sequence: number };

export type HostEvent = {
  scope: "host" | "session";
  kind: string;
  sessionId?: string;
  epoch?: string;
  sequence?: number;
  afterSequence?: number;
  revision?: number;
  turnId?: string;
  payload: Record<string, unknown>;
};

export type Subscription = {
  id: string;
  scope: "host" | "session";
  sessionId?: string;
  cursor: Cursor | null;
};

export class EventJournal {
  readonly epoch = uuid();
  private readonly path: string;
  private events: HostEvent[] = [];
  private sequence = 0;
  private pending: Promise<void> = Promise.resolve();
  /**
   * Highest sequence number of an event that has already been evicted from the
   * in-memory buffer, split by scope. A cursor at or below these watermarks can
   * no longer be replayed completely, so `replay` must answer CURSOR_EXPIRED
   * instead of silently returning the surviving suffix.
   */
  private droppedHostSequence = 0;
  private readonly droppedSessionSequence = new Map<string, number>();

  constructor(dataDir: string, private readonly maxEvents = 10_000) {
    this.path = join(dataDir, "meta", "events.jsonl");
  }

  async load(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
    let raw = "";
    try {
      raw = await readFile(this.path, "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    this.events = [];
    this.sequence = 0;
    this.droppedHostSequence = 0;
    this.droppedSessionSequence.clear();
    let hadCorruptedTail = false;
    if (raw.length > 0 && !raw.endsWith("\n")) {
      hadCorruptedTail = true;
    }
    const validLines: string[] = [];
    for (const line of raw.split("\n")) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line) as HostEvent;
        this.events.push(event);
        this.sequence = Math.max(this.sequence, event.sequence ?? 0);
        validLines.push(line);
      } catch {
        hadCorruptedTail = true;
      }
    }
    if (hadCorruptedTail) {
      const sanitized = validLines.length > 0 ? validLines.join("\n") + "\n" : "";
      await writeFile(this.path, sanitized, { mode: 0o600 });
    }
    this.trim();
  }

  /** Drop the oldest buffered events past `maxEvents`, advancing watermarks. */
  private trim(): void {
    if (this.events.length <= this.maxEvents) return;
    const removed = this.events.splice(0, this.events.length - this.maxEvents);
    for (const event of removed) this.noteDropped(event);
  }

  private noteDropped(event: HostEvent): void {
    const sequence = event.sequence ?? 0;
    if (event.scope === "host") {
      this.droppedHostSequence = Math.max(this.droppedHostSequence, sequence);
    } else if (event.sessionId) {
      this.droppedSessionSequence.set(
        event.sessionId,
        Math.max(this.droppedSessionSequence.get(event.sessionId) ?? 0, sequence)
      );
    }
  }

  async append(
    scope: "host" | "session",
    kind: string,
    payload: Record<string, unknown>,
    extra: Partial<HostEvent> = {}
  ): Promise<HostEvent> {
    const result = this.pending.then(async () => {
      const nextSequence = this.sequence + 1;
      const event: HostEvent = {
        scope,
        kind,
        epoch: this.epoch,
        sequence: nextSequence,
        payload,
        ...extra
      };
      await appendFile(this.path, `${JSON.stringify(event)}\n`, { mode: 0o600 });
      this.sequence = nextSequence;
      this.events.push(event);
      this.trim();
      return event;
    });
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  replay(scope: "host" | "session", sessionId: string | undefined, after: Cursor | null): HostEvent[] {
    if (!after) return [];
    if (after.epoch !== this.epoch) throw new HostError("CURSOR_EXPIRED", "event epoch changed");
    // A cursor below the retention watermark means events that satisfy this
    // subscription were already evicted; the surviving suffix is incomplete.
    if (scope === "host") {
      if (this.droppedHostSequence > after.sequence) {
        throw new HostError("CURSOR_EXPIRED", "event journal no longer contains cursor");
      }
    } else if ((this.droppedSessionSequence.get(sessionId ?? "") ?? 0) > after.sequence) {
      throw new HostError("CURSOR_EXPIRED", "event journal no longer contains cursor");
    }
    const start = this.events.findIndex(
      (event) =>
        (event.sequence ?? 0) > after.sequence &&
        event.scope === scope &&
        (scope === "host" || event.sessionId === sessionId)
    );
    if (start < 0) return [];
    return this.events.slice(start).filter(
      (event) => event.scope === scope && (scope === "host" || event.sessionId === sessionId)
    );
  }

  currentCursor(): Cursor {
    return { epoch: this.epoch, sequence: this.sequence };
  }
}
