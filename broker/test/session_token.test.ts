import { describe, expect, it } from "vitest";
import { signSessionToken, verifySessionToken } from "../supabase/functions/_shared/broker-core/mod.ts";
import { TOKEN_SECRET } from "./helpers.ts";

const claims = { sessionId: "sess1", roomId: "room-a", ownerId: "alice", expiresAt: 2_000_000_000 };
const now = 1_900_000_000;

function b64url(text: string): string {
  return Buffer.from(text).toString("base64url");
}

describe("session tokens", () => {
  it("round-trips", async () => {
    const token = await signSessionToken(claims, TOKEN_SECRET);
    expect(await verifySessionToken(token, TOKEN_SECRET, now)).toEqual(claims);
  });

  it("rejects expired tokens", async () => {
    const token = await signSessionToken(claims, TOKEN_SECRET);
    expect(await verifySessionToken(token, TOKEN_SECRET, claims.expiresAt)).toBeNull();
    expect(await verifySessionToken(token, TOKEN_SECRET, claims.expiresAt + 1)).toBeNull();
  });

  it("rejects a different secret", async () => {
    const token = await signSessionToken(claims, TOKEN_SECRET);
    expect(await verifySessionToken(token, `${TOKEN_SECRET}-other`, now)).toBeNull();
  });

  it("rejects a tampered payload", async () => {
    const token = await signSessionToken(claims, TOKEN_SECRET);
    const [, sig] = token.split(".");
    const forged = b64url(JSON.stringify({ v: 1, sid: "sess2", room: "room-a", sub: "alice", exp: claims.expiresAt }));
    expect(await verifySessionToken(`${forged}.${sig}`, TOKEN_SECRET, now)).toBeNull();
  });

  it("rejects a tampered signature", async () => {
    const token = await signSessionToken(claims, TOKEN_SECRET);
    const [body, sig] = token.split(".");
    const bytes = Buffer.from(sig!, "base64url");
    bytes[0] = bytes[0]! ^ 1;
    expect(await verifySessionToken(`${body}.${bytes.toString("base64url")}`, TOKEN_SECRET, now)).toBeNull();
  });

  it("rejects malformed tokens", async () => {
    for (const bad of ["", "abc", "a.b.c", "!!.??", `${b64url("{}")}.`, "x".repeat(5000)]) {
      expect(await verifySessionToken(bad, TOKEN_SECRET, now), bad.slice(0, 10)).toBeNull();
    }
  });

  it("rejects a validly signed payload with the wrong shape", async () => {
    // Sign a raw body by hand with the same key to check shape validation.
    const key = await crypto.subtle.importKey(
      "raw",
      new TextEncoder().encode(TOKEN_SECRET),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign"],
    );
    const body = b64url(JSON.stringify({ v: 2, sid: "s", room: "r", sub: "u", exp: claims.expiresAt }));
    const sig = Buffer.from(await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body))).toString("base64url");
    expect(await verifySessionToken(`${body}.${sig}`, TOKEN_SECRET, now)).toBeNull();
  });

  it("refuses short secrets", async () => {
    await expect(signSessionToken(claims, "short")).rejects.toThrow();
  });
});
