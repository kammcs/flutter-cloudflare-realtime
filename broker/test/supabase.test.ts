import { describe, expect, it } from "vitest";
import { createSupabaseAuthenticator, type GetUser } from "../supabase/functions/realtime-broker/auth.ts";
import { authorizeDataChannels } from "../supabase/functions/realtime-broker/data_channels.ts";
import {
  PostgresSessionStore,
  type SessionRow,
  type SessionTable,
} from "../supabase/functions/realtime-broker/postgres_store.ts";
import { isRoomMember } from "../supabase/functions/realtime-broker/room_membership.ts";

const withBearer = (token?: string) =>
  new Request("https://broker.example/", token ? { headers: { Authorization: `Bearer ${token}` } } : {});

describe("Supabase authenticator", () => {
  const getUser: GetUser = (jwt) =>
    Promise.resolve(
      jwt === "good-jwt"
        ? { data: { user: { id: "user-1" } }, error: null }
        : { data: { user: null }, error: new Error("invalid") },
    );
  const authenticate = createSupabaseAuthenticator(getUser);

  it("returns the Supabase user ID for a valid token", async () => {
    expect(await authenticate(withBearer("good-jwt"))).toEqual({ id: "user-1" });
  });

  it("rejects missing and invalid tokens, and auth errors", async () => {
    expect(await authenticate(withBearer())).toBeNull();
    expect(await authenticate(withBearer("bad-jwt"))).toBeNull();
    const throwing = createSupabaseAuthenticator(() => Promise.reject(new Error("network")));
    expect(await throwing(withBearer("good-jwt"))).toBeNull();
  });
});

describe("Supabase room membership stub", () => {
  it("fails closed", async () => {
    expect(await isRoomMember({ id: "user-1" }, "room-a")).toBe(false);
  });
});

describe("Supabase DataChannel rules", () => {
  it("are unset by default", () => {
    expect(authorizeDataChannels).toBeUndefined();
  });
});

describe("PostgresSessionStore", () => {
  function fakeTable() {
    const rows = new Map<string, SessionRow>();
    const table: SessionTable = {
      insert: (row) => {
        rows.set(row.session_id, row);
        return Promise.resolve({ error: null });
      },
      findUnexpired: (sessionId, nowIso) => {
        const row = rows.get(sessionId);
        const data = row && row.expires_at > nowIso
          ? { room_id: row.room_id, owner_id: row.owner_id, created_at: row.created_at }
          : null;
        return Promise.resolve({ data, error: null });
      },
    };
    return { rows, table };
  }

  it("inserts rows with an expiry and reads them back", async () => {
    const clock = { now: Date.UTC(2026, 8, 30) };
    const { rows, table } = fakeTable();
    const store = new PostgresSessionStore(table, { ttlSeconds: 60, now: () => clock.now });
    const record = { roomId: "room-a", ownerId: "user-1", createdAt: clock.now };
    await store.put("sess1", record);
    expect(rows.get("sess1")).toEqual({
      session_id: "sess1",
      room_id: "room-a",
      owner_id: "user-1",
      created_at: "2026-09-30T00:00:00.000Z",
      expires_at: "2026-09-30T00:01:00.000Z",
    });
    expect(await store.get("sess1")).toEqual(record);
    expect(await store.get("missing")).toBeNull();
    clock.now += 61_000;
    expect(await store.get("sess1")).toBeNull();
  });

  it("throws on database errors", async () => {
    const store = new PostgresSessionStore({
      insert: () => Promise.resolve({ error: { message: "boom" } }),
      findUnexpired: () => Promise.resolve({ data: null, error: { message: "boom" } }),
    });
    await expect(store.put("s", { roomId: "r", ownerId: "o", createdAt: 0 })).rejects.toThrow();
    await expect(store.get("s")).rejects.toThrow();
  });
});
