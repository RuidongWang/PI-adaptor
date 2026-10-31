import { join } from "node:path";
import { HostError } from "../errors.js";
import { readJsonFile, writeJsonFileAtomic } from "../util/json-file.js";

/** A turn as the contract exposes it (no live handle), persisted across restarts. */
export type TurnRecord = {
  id: string;
  sessionId: string;
  status: string;
  createdAt: string;
  settledAt: string | null;
  settledReason?: string;
};

type TurnFile = { version: 1; turns: TurnRecord[] };

const EMPTY: TurnFile = { version: 1, turns: [] };

/** Statuses that mean "the host still owns a running execution". */
export const ACTIVE_TURN_STATUSES = new Set([
  "queued",
  "running",
  "waiting_approval",
  "waiting_input"
]);

/**
 * Persists turn lifecycle so a restart can reconcile turns that were running
 * when the process died. Contract §9: after restart a turn is `interrupted` only
 * when the host can prove the old execution stopped and produced no output;
 * otherwise it is `uncertain` with `settledReason:"agent_restarted_unconfirmed"`.
 * Since the in-memory buffer is gone, the host cannot prove either, so startup
 * always downgrades active records to `uncertain`.
 */
export class TurnStore {
  private readonly path: string;
  private pending: Promise<void> = Promise.resolve();

  private serialized<T>(work: () => Promise<T>): Promise<T> {
    const result = this.pending.then(work);
    this.pending = result.then(() => undefined, () => undefined);
    return result;
  }

  constructor(dataDir: string) {
    this.path = join(dataDir, "meta", "turns.json");
  }

  private async load(): Promise<TurnFile> {
    const value = await readJsonFile<TurnFile>(this.path, structuredClone(EMPTY));
    if (value.version !== 1) throw new HostError("INTERNAL", "unsupported turn store");
    return value;
  }

  private async save(value: TurnFile): Promise<void> {
    await writeJsonFileAtomic(this.path, value, 0o600);
  }

  async all(): Promise<TurnRecord[]> {
    return (await this.load()).turns;
  }

  async upsert(record: TurnRecord): Promise<void> {
    return this.serialized(async () => {
      const data = await this.load();
      const index = data.turns.findIndex((entry) => entry.id === record.id);
      if (index >= 0) data.turns[index] = { ...data.turns[index], ...record };
      else data.turns.push(record);
      await this.save(data);
    });
  }

  /**
   * Downgrade every turn that was still active at last write to `uncertain`.
   * Returns the reconciled records so the caller can seed its in-memory map.
   */
  async reconcileAfterRestart(now = new Date()): Promise<TurnRecord[]> {
    return this.serialized(async () => {
      const data = await this.load();
      for (const turn of data.turns) {
        if (!ACTIVE_TURN_STATUSES.has(turn.status)) continue;
        turn.status = "uncertain";
        turn.settledAt = now.toISOString();
        turn.settledReason = "agent_restarted_unconfirmed";
      }
      await this.save(data);
      return data.turns;
    });
  }
}
