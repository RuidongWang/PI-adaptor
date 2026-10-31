/**
 * Minimal async mutex keyed by a string. Work queued under the same key runs
 * strictly one-at-a-time in arrival order; different keys never block each
 * other. Used to serialise per-session native-file writes and event emission so
 * a snapshot and its cursor can be captured against a single state point.
 */
export class KeyedMutex {
  private readonly chains = new Map<string, Promise<unknown>>();

  run<T>(key: string, work: () => Promise<T>): Promise<T> {
    const previous = this.chains.get(key) ?? Promise.resolve();
    const result = previous.then(work, work);
    const chain = result.then(
      () => undefined,
      () => undefined
    );
    this.chains.set(key, chain);
    void chain.then(() => {
      if (this.chains.get(key) === chain) this.chains.delete(key);
    });
    return result;
  }
}
