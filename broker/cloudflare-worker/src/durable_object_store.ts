/**
 * A {@link SessionStore} backed by one Durable Object per SFU session.
 *
 * Why Durable Objects rather than Workers KV: rule 4 needs read-after-write
 * consistency across locations. A peer usually pulls a session seconds after
 * it was created, from a different Cloudflare location, and KV can take up to
 * a minute to make a write visible elsewhere, which would cause spurious 403s.
 * Durable Object storage is strongly consistent. One object per session
 * (addressed by `idFromName(sessionId)`) avoids a global hot spot, and an
 * alarm deletes each record when its TTL ends.
 */

import type { SessionRecord, SessionStore } from "../../supabase/functions/_shared/broker-core/mod.ts";

/** The RPC surface of {@link RealtimeSessionObject} that the store uses. */
export interface SessionObjectStub {
  put(record: SessionRecord, expiresAt: number): Promise<void>;
  get(): Promise<SessionRecord | null>;
}

/** Stores records in the Durable Object that `stubFor(sessionId)` returns. */
export class DurableObjectSessionStore implements SessionStore {
  readonly #stubFor: (sessionId: string) => SessionObjectStub;
  readonly #ttlMs: number;
  readonly #now: () => number;

  constructor(
    stubFor: (sessionId: string) => SessionObjectStub,
    options: { ttlSeconds?: number; now?: () => number } = {},
  ) {
    this.#stubFor = stubFor;
    this.#ttlMs = (options.ttlSeconds ?? 86400) * 1000;
    this.#now = options.now ?? Date.now;
  }

  async put(sessionId: string, record: SessionRecord): Promise<void> {
    await this.#stubFor(sessionId).put(
      { roomId: record.roomId, ownerId: record.ownerId, createdAt: record.createdAt },
      this.#now() + this.#ttlMs,
    );
  }

  async get(sessionId: string): Promise<SessionRecord | null> {
    return await this.#stubFor(sessionId).get();
  }
}
