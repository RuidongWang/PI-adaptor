import { appendFile, mkdir, rename, rm, stat, writeFile } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
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
  /// Disk retention: the active JSONL is rotated once it reaches this size and
  /// only the newest `maxFiles` rotated files are kept.
  private bytesWritten = 0;

  constructor(
    dataDir: string,
    private readonly maxEvents = 10_000,
    private readonly maxFileBytes = 8 * 1024 * 1024,
    private readonly maxFiles = 5
  ) {
    this.path = join(dataDir, "meta", "events.jsonl");
  }

  private rotatedPath(index: number): string {
    return `${this.path}.${index}`;
  }

  private async rotate(): Promise<void> {
    // Drop the oldest, shift the rest, then move the active file aside.
    await rm(this.rotatedPath(this.maxFiles), { force: true });
    for (let index = this.maxFiles - 1; index >= 1; index -= 1) {
      const from = this.rotatedPath(index);
      const to = this.rotatedPath(index + 1);
      try {
        await rename(from, to);
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
      }
    }
    try {
      await rename(this.path, this.rotatedPath(1));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
    this.bytesWritten = 0;
  }

  async load(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
    this.events = [];
    this.sequence = 0;
    this.droppedHostSequence = 0;
    this.droppedSessionSequence.clear();
    let hadCorruptedTail = false;
    // Read rotated files oldest-first, then the active file. Only the last
    // `maxEvents` events stay in memory; the file is streamed line by line so a
    // long-lived journal does not have to fit in RAM at startup.
    const files: string[] = [];
    for (let index = this.maxFiles; index >= 1; index -= 1) files.push(this.rotatedPath(index));
    files.push(this.path);
    for (const file of files) {
      try {
        const info = await stat(file);
        if (file === this.path) this.bytesWritten = info.size;
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
        throw error;
      }
      const reader = createInterface({ input: createReadStream(file, { encoding: "utf8" }), crlfDelay: Infinity });
      try {
        for await (const line of reader) {
          if (!line.trim()) continue;
          try {
            const event = JSON.parse(line) as HostEvent;
            this.events.push(event);
            this.sequence = Math.max(this.sequence, event.sequence ?? 0);
            if (event.sequence === undefined || typeof event.payload !== "object" || event.payload === null) {
              hadCorruptedTail = true;
            }
            if (this.events.length > this.maxEvents) this.trim();
          } catch {
            if (file === this.path) hadCorruptedTail = true;
          }
        }
      } finally {
        reader.close();
      }
    }
    if (hadCorruptedTail) {
      // Rewrite only the active file with the surviving suffix; rotated files
      // are retained as-is because they are already bounded and immutable.
      const sanitized = this.events.length > 0 ? this.events.map((event) => JSON.stringify(event)).join("\n") + "\n" : "";
      await writeFile(this.path, sanitized, { mode: 0o600 });
      this.bytesWritten = Buffer.byteLength(sanitized, "utf8");
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
      const line = `${JSON.stringify(event)}\n`;
      const lineBytes = Buffer.byteLength(line, "utf8");
      if (this.bytesWritten > 0 && this.bytesWritten + lineBytes > this.maxFileBytes) {
        await this.rotate();
      }
      await appendFile(this.path, line, { mode: 0o600 });
      this.bytesWritten += lineBytes;
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
