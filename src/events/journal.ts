import { appendFile, mkdir, open, readFile, rename, rm, stat } from "node:fs/promises";
import { createReadStream } from "node:fs";
import { createInterface } from "node:readline";
import { dirname, join } from "node:path";
import { HostError } from "../errors.js";
import { uuid } from "../util/id.js";
import { readJsonFile, syncDirectory, writeJsonFileAtomic } from "../util/json-file.js";

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
  private rollbackSize: number | undefined;
  private readonly unconfirmedTransitions = new Set<string>();
  private checkpointExists = false;

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
    if (this.unconfirmedTransitions.size || this.checkpointExists) {
      await writeJsonFileAtomic(`${this.path}.pending-transitions.json`, [...this.unconfirmedTransitions]);
      this.checkpointExists = this.unconfirmedTransitions.size > 0;
    }
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

  async load(pendingTransitions: ReadonlySet<string> = new Set()): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
    this.events = [];
    this.bytesWritten = 0;
    this.sequence = 0;
    this.droppedHostSequence = 0;
    this.droppedSessionSequence.clear();
    this.unconfirmedTransitions.clear();
    const saved = await readJsonFile<string[]>(`${this.path}.pending-transitions.json`, []);
    this.checkpointExists = saved.length > 0;
    for (const id of saved) if (pendingTransitions.has(id)) this.unconfirmedTransitions.add(id);
    // Read rotated files oldest-first, then the active file. Only the last
    // `maxEvents` events stay in memory; the file is streamed line by line so a
    // long-lived journal does not have to fit in RAM at startup.
    const files: string[] = [];
    for (let index = this.maxFiles; index >= 1; index -= 1) files.push(this.rotatedPath(index));
    files.push(this.path);
    for (const file of files) {
      try {
        const info = await stat(file);
        if (file === this.path) {
          this.bytesWritten = info.size;
          if (info.size) await this.repairTail();
        }
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
            if (!Number.isSafeInteger(event?.sequence) || !event.payload || typeof event.payload !== "object") continue;
            this.events.push(event);
            this.sequence = Math.max(this.sequence, event.sequence ?? 0);
            const id = this.transitionKey(event);
            if (id && pendingTransitions.has(id)) this.unconfirmedTransitions.add(id);
            if (this.events.length > this.maxEvents) this.trim();
          } catch { continue; }
        }
      } finally {
        reader.close();
      }
    }
    this.trim();
  }

  private transitionKey(event: Pick<HostEvent, "kind" | "turnId" | "sessionId">): string | undefined {
    if (["turn.completed", "turn.failed", "turn.interrupted"].includes(event.kind)) return event.turnId;
    if (event.kind === "session.created" && event.sessionId) return `branch:${event.sessionId}`;
    if (event.kind === "session.deleted" && event.sessionId) return `deleted:${event.sessionId}`;
    return undefined;
  }

  confirmTransition(id: string): void { this.unconfirmedTransitions.delete(id); }

  private async repairTail(): Promise<void> {
    const handle = await open(this.path, "r+");
    try {
      const last = Buffer.alloc(1);
      await handle.read(last, 0, 1, this.bytesWritten - 1);
      if (last[0] === 10) return;
      const bytes = await readFile(this.path);
      const start = bytes.lastIndexOf(10) + 1;
      let complete = false;
      try { complete = Number.isSafeInteger(JSON.parse(bytes.toString("utf8", start))?.sequence); } catch { /* torn record */ }
      if (complete) {
        await handle.write(Buffer.from("\n"), 0, 1, this.bytesWritten);
        this.bytesWritten++;
      } else {
        await handle.truncate(start);
        this.bytesWritten = start;
      }
      await handle.sync();
    } finally { await handle.close(); }
  }

  private async rollbackAppend(): Promise<void> {
    if (this.rollbackSize === undefined) return;
    const handle = await open(this.path, "a+", 0o600);
    try {
      await handle.truncate(this.rollbackSize);
      await handle.sync();
    } finally { await handle.close(); }
    await syncDirectory(dirname(this.path));
    this.rollbackSize = undefined;
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
      await this.rollbackAppend();
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
      const transition = this.transitionKey(event);
      const durable = !!transition || ["approval.resolved", "session.deleted", "turn.completed", "turn.failed", "turn.interrupted"].includes(kind);
      try {
        await appendFile(this.path, line, { mode: 0o600, flush: durable });
        if (durable) await syncDirectory(dirname(this.path));
      } catch (error) {
        this.rollbackSize = this.bytesWritten;
        await this.rollbackAppend();
        throw error;
      }
      this.bytesWritten += lineBytes;
      this.sequence = nextSequence;
      this.events.push(event);
      if (transition) this.unconfirmedTransitions.add(transition);
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

  hasTransition(kind: string, sessionId: string, turnId?: string): boolean {
    const key = this.transitionKey({ kind, sessionId, ...(turnId ? { turnId } : {}) });
    if (key && this.unconfirmedTransitions.has(key)) return true;
    return this.events.some(event => event.kind === kind && event.sessionId === sessionId && event.turnId === turnId);
  }
}
