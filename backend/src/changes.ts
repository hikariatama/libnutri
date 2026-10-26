import { createHash } from 'node:crypto';
import { Fault, type Store } from './store.js';

// Tenant-bound snapshots in one process. Hashes survive reconnects and process restarts; no
// journal of food descriptions or unbounded event history is needed.
export class ChangeFeed {
  private waiters = new Set<() => void>();
  constructor(private store: Store) {
    store.onChange = () => {
      for (const wake of [...this.waiters]) wake();
    };
  }
  get pending() {
    return this.waiters.size;
  }
  capture() {
    const state = {
      entries: this.store.list(),
      attempts: this.store.operations(),
      composer: { text: '', source: 'text', entryID: null },
    };
    const settings = this.store.settings(),
      spending = this.store.spending();
    const cursor = createHash('sha256')
      .update(JSON.stringify({ userId: this.store.userId, state, settings, spending }))
      .digest('hex');
    return { cursor, state, settings, spending };
  }
  async wait(after: string | null, signal: AbortSignal, timeout = 25000) {
    const initial = this.capture();
    if (signal.aborted) throw new DOMException('Aborted', 'AbortError');
    if (after !== initial.cursor) return initial;
    if (this.waiters.size >= 256) throw new Fault('too_many_requests', 429);
    return new Promise<ReturnType<ChangeFeed['capture']> | { cursor: string; state: null }>(
      (resolve, reject) => {
        const finish = (value?: ReturnType<ChangeFeed['capture']>, error?: Error) => {
          clearTimeout(timer);
          this.waiters.delete(wake);
          signal.removeEventListener('abort', abort);
          if (error) reject(error);
          else resolve(value ?? { cursor: initial.cursor, state: null });
        };
        const wake = () => {
          const current = this.capture();
          if (current.cursor !== after) finish(current);
        };
        const abort = () => finish(undefined, new DOMException('Aborted', 'AbortError'));
        const timer = setTimeout(() => finish(), timeout);
        timer.unref();
        this.waiters.add(wake);
        signal.addEventListener('abort', abort, { once: true });
      },
    );
  }
}
