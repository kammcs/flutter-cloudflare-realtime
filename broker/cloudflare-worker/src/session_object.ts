import { DurableObject } from "cloudflare:workers";
import type { SessionRecord } from "../../supabase/functions/_shared/broker-core/mod.ts";
import type { SessionObjectStub } from "./durable_object_store.ts";

interface Entry {
  record: SessionRecord;
  /** Milliseconds since the epoch. */
  expiresAt: number;
}

const KEY = "session";

/**
 * Holds the {@link SessionRecord} of one SFU session (the object's name is
 * the session ID). An alarm deletes it when it expires, and reads check the
 * expiry too, so a late alarm never extends a record's life.
 */
export class RealtimeSessionObject extends DurableObject implements SessionObjectStub {
  async put(record: SessionRecord, expiresAt: number): Promise<void> {
    const entry: Entry = { record, expiresAt };
    await this.ctx.storage.put(KEY, entry);
    await this.ctx.storage.setAlarm(expiresAt);
  }

  async get(): Promise<SessionRecord | null> {
    const entry = await this.ctx.storage.get<Entry>(KEY);
    if (!entry) return null;
    if (entry.expiresAt <= Date.now()) {
      await this.ctx.storage.deleteAll();
      return null;
    }
    return entry.record;
  }

  override async alarm(): Promise<void> {
    await this.ctx.storage.deleteAll();
  }
}
