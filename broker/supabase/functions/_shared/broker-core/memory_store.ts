import type { SessionRecord, SessionStore } from "./types.ts";

/**
 * A process-local {@link SessionStore} with a TTL.
 *
 * For tests and single-instance development only: serverless runtimes run
 * many isolates, and each would have its own map.
 */
export class InMemorySessionStore implements SessionStore {
  readonly #records = new Map<string, { record: SessionRecord; expiresAt: number }>();
  readonly #ttlMs: number;
  readonly #now: () => number;

  constructor(options: { ttlSeconds?: number; now?: () => number } = {}) {
    this.#ttlMs = (options.ttlSeconds ?? 86400) * 1000;
    this.#now = options.now ?? Date.now;
  }

  put(sessionId: string, record: SessionRecord): Promise<void> {
    this.#records.set(sessionId, { record, expiresAt: this.#now() + this.#ttlMs });
    return Promise.resolve();
  }

  get(sessionId: string): Promise<SessionRecord | null> {
    const entry = this.#records.get(sessionId);
    if (!entry) return Promise.resolve(null);
    if (entry.expiresAt <= this.#now()) {
      this.#records.delete(sessionId);
      return Promise.resolve(null);
    }
    return Promise.resolve(entry.record);
  }
}
