import { SignJWT } from "jose";
import { describe, expect, it } from "vitest";
import { createJwtAuthenticator } from "../cloudflare-worker/src/auth.ts";
import { authorizeDataChannels } from "../cloudflare-worker/src/data_channels.ts";
import { DurableObjectSessionStore, type SessionObjectStub } from "../cloudflare-worker/src/durable_object_store.ts";
import { isRoomMember } from "../cloudflare-worker/src/room_membership.ts";
import type { SessionRecord } from "../supabase/functions/_shared/broker-core/mod.ts";

// Fake, test-only HS256 key.
const JWT_KEY = "test-jwt-hs256-key-not-real-0123456789";
const ISSUER = "https://auth.example.com/";
const AUDIENCE = "realtime";

async function jwt(
  claims: Record<string, unknown>,
  opts: { key?: string; iss?: string; aud?: string; exp?: string | number; alg?: string } = {},
) {
  return await new SignJWT(claims)
    .setProtectedHeader({ alg: opts.alg ?? "HS256" })
    .setIssuer(opts.iss ?? ISSUER)
    .setAudience(opts.aud ?? AUDIENCE)
    .setIssuedAt()
    .setExpirationTime(opts.exp ?? "5m")
    .sign(new TextEncoder().encode(opts.key ?? JWT_KEY));
}

const withBearer = (token: string) => new Request("https://broker.example/", { headers: { Authorization: `Bearer ${token}` } });

describe("Worker JWT authenticator", () => {
  const authenticate = createJwtAuthenticator({ issuer: ISSUER, audience: AUDIENCE, secret: JWT_KEY });

  it("accepts a valid token and uses sub as the caller ID", async () => {
    expect(await authenticate(withBearer(await jwt({ sub: "alice" })))).toEqual({ id: "alice" });
  });

  it("rejects missing, malformed and invalid tokens", async () => {
    expect(await authenticate(new Request("https://broker.example/"))).toBeNull();
    expect(await authenticate(withBearer("not-a-jwt"))).toBeNull();
    expect(await authenticate(withBearer(await jwt({ sub: "alice" }, { key: `${JWT_KEY}-other` })))).toBeNull();
    expect(await authenticate(withBearer(await jwt({ sub: "alice" }, { iss: "https://other.example/" })))).toBeNull();
    expect(await authenticate(withBearer(await jwt({ sub: "alice" }, { aud: "other" })))).toBeNull();
    expect(await authenticate(withBearer(await jwt({ sub: "alice" }, { exp: Math.floor(Date.now() / 1000) - 60 }))))
      .toBeNull();
    expect(await authenticate(withBearer(await jwt({}))) ).toBeNull();
    expect(await authenticate(withBearer(await jwt({ sub: "alice" }, { alg: "HS512" })))).toBeNull();
  });

  it("requires issuer, audience and exactly one key source", () => {
    expect(() => createJwtAuthenticator({ issuer: "", audience: AUDIENCE, secret: JWT_KEY })).toThrow();
    expect(() => createJwtAuthenticator({ issuer: ISSUER, audience: "", secret: JWT_KEY })).toThrow();
    expect(() => createJwtAuthenticator({ issuer: ISSUER, audience: AUDIENCE })).toThrow();
    expect(() =>
      createJwtAuthenticator({ issuer: ISSUER, audience: AUDIENCE, secret: JWT_KEY, jwksUrl: "https://x.example/jwks" })
    ).toThrow();
  });
});

describe("Worker room membership stub", () => {
  it("fails closed", async () => {
    expect(await isRoomMember({ id: "alice" }, "room-a")).toBe(false);
  });
});

describe("Worker DataChannel rules", () => {
  it("are unset by default", () => {
    expect(authorizeDataChannels).toBeUndefined();
  });
});

describe("DurableObjectSessionStore", () => {
  it("stores each session in its own object with an expiry", async () => {
    const objects = new Map<string, { record: SessionRecord; expiresAt: number } | null>();
    const stubFor = (sessionId: string): SessionObjectStub => ({
      put: (record, expiresAt) => {
        objects.set(sessionId, { record, expiresAt });
        return Promise.resolve();
      },
      get: () => Promise.resolve(objects.get(sessionId)?.record ?? null),
    });
    const store = new DurableObjectSessionStore(stubFor, { ttlSeconds: 60, now: () => 1000 });
    const record = { roomId: "room-a", ownerId: "alice", createdAt: 1000 };
    await store.put("sess1", record);
    expect(objects.get("sess1")).toEqual({ record, expiresAt: 61_000 });
    expect(await store.get("sess1")).toEqual(record);
    expect(await store.get("sess2")).toBeNull();
  });
});
