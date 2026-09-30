/**
 * A {@link SessionStore} backed by the `public.realtime_broker_sessions`
 * table (see supabase/migrations). Postgres is strongly consistent, so a
 * session is visible to every function instance as soon as it is written.
 *
 * It talks to the table through the small {@link SessionTable} interface so
 * that it has no Deno or supabase-js dependency and can be unit-tested; the
 * Edge Function adapts a service-role supabase-js client to it.
 */

import type { SessionRecord, SessionStore } from "../_shared/broker-core/mod.ts";

/** Name of the table created by the migration. */
export const SESSION_TABLE = "realtime_broker_sessions";

/** A row of {@link SESSION_TABLE}. */
export interface SessionRow {
  session_id: string;
  room_id: string;
  owner_id: string;
  /** ISO 8601. */
  created_at: string;
  /** ISO 8601. */
  expires_at: string;
}

interface DbError {
  message: string;
}

/** The two table operations the store needs. */
export interface SessionTable {
  insert(row: SessionRow): PromiseLike<{ error: DbError | null }>;
  /** Selects the row for `sessionId` whose `expires_at` is after `nowIso`, or `null`. */
  findUnexpired(
    sessionId: string,
    nowIso: string,
  ): PromiseLike<{
    data: Pick<SessionRow, "room_id" | "owner_id" | "created_at"> | null;
    error: DbError | null;
  }>;
}

/** Stores session records in Postgres with a TTL (`expires_at`). */
export class PostgresSessionStore implements SessionStore {
  readonly #table: SessionTable;
  readonly #ttlMs: number;
  readonly #now: () => number;

  constructor(table: SessionTable, options: { ttlSeconds?: number; now?: () => number } = {}) {
    this.#table = table;
    this.#ttlMs = (options.ttlSeconds ?? 86400) * 1000;
    this.#now = options.now ?? Date.now;
  }

  async put(sessionId: string, record: SessionRecord): Promise<void> {
    const { error } = await this.#table.insert({
      session_id: sessionId,
      room_id: record.roomId,
      owner_id: record.ownerId,
      created_at: new Date(record.createdAt).toISOString(),
      expires_at: new Date(this.#now() + this.#ttlMs).toISOString(),
    });
    if (error) throw new Error("session insert failed");
  }

  async get(sessionId: string): Promise<SessionRecord | null> {
    const { data, error } = await this.#table.findUnexpired(
      sessionId,
      new Date(this.#now()).toISOString(),
    );
    if (error) throw new Error("session lookup failed");
    if (!data) return null;
    return {
      roomId: data.room_id,
      ownerId: data.owner_id,
      createdAt: Date.parse(data.created_at),
    };
  }
}
