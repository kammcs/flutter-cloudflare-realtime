import { afterEach, describe, expect, it } from "vitest";
import { createDevAuthenticator, isValidDevUser, tokenMatches } from "../src/dev_auth.ts";
import { APP_SECRET, DEV_TOKEN, type Running, SFU, start } from "./helpers.ts";

let running: Running | undefined;
afterEach(async () => {
  await running?.server.close();
  running = undefined;
});

function headers(extra: Record<string, string> = {}): Record<string, string> {
  return { "Authorization": `Bearer ${DEV_TOKEN}`, "X-Dev-User": "alice", "X-Realtime-Room": "room-1", ...extra };
}

describe("broker mounting", () => {
  it("serves sessions/new through the shared core and forwards with the App Secret", async () => {
    running = await start();
    const res = await fetch(`${running.base}/sessions/new`, { method: "POST", headers: headers() });
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ sessionId: "sess1" });
    expect(running.upstream).toHaveLength(1);
    expect(running.upstream[0]!.url).toBe(`${SFU}/sessions/new`);
    expect(running.upstream[0]!.headers.get("Authorization")).toBe(`Bearer ${APP_SECRET}`);
    expect(running.upstream[0]!.headers.has("X-Dev-User")).toBe(false);
  });

  it("passes JSON bodies through and binds sessions to the dev user", async () => {
    running = await start();
    await fetch(`${running.base}/sessions/new`, { method: "POST", headers: headers() });
    const body = { sessionDescription: { type: "offer", sdp: "v=0" }, tracks: [] };
    const own = await fetch(`${running.base}/sessions/sess1/tracks/new`, {
      method: "POST",
      headers: headers({ "Content-Type": "application/json" }),
      body: JSON.stringify(body),
    });
    expect(own.status).toBe(200);
    expect(JSON.parse(running.upstream[1]!.body!)).toEqual(body);

    // Another dev user can't act on alice's session (rule 3).
    const other = await fetch(`${running.base}/sessions/sess1/tracks/new`, {
      method: "POST",
      headers: headers({ "X-Dev-User": "bob", "Content-Type": "application/json" }),
      body: JSON.stringify(body),
    });
    expect(other.status).toBe(403);
  });

  it("lets any dev user join any room", async () => {
    running = await start();
    for (const room of ["a", "b", "some other room"]) {
      const res = await fetch(`${running.base}/generate-ice-servers`, {
        method: "POST",
        headers: headers({ "X-Realtime-Room": room }),
      });
      expect(res.status).toBe(200);
      expect(await res.json()).toEqual({ iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }] });
    }
  });

  it("serves an unauthenticated health check", async () => {
    running = await start();
    const res = await fetch(`${running.base}/healthz`);
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true, devOnly: true });
  });

  it("returns 404 for unknown paths", async () => {
    running = await start();
    const res = await fetch(`${running.base}/nope`, { method: "POST", headers: headers() });
    expect(res.status).toBe(404);
  });

  it("allows the X-Dev-User header in CORS preflights", async () => {
    running = await start();
    const res = await fetch(`${running.base}/sessions/new`, {
      method: "OPTIONS",
      headers: {
        "Origin": "http://localhost:5000",
        "Access-Control-Request-Method": "POST",
        "Access-Control-Request-Headers": "authorization,x-dev-user,x-realtime-room",
      },
    });
    expect(res.status).toBeLessThan(300);
    expect(res.headers.get("Access-Control-Allow-Headers")?.toLowerCase()).toContain("x-dev-user");
  });

  it("logs method, path and status without secrets", async () => {
    running = await start();
    await fetch(`${running.base}/sessions/new`, { method: "POST", headers: headers() });
    const all = running.logs.join("\n");
    expect(all).toContain("POST /sessions/new -> 201 (alice)");
    expect(all).not.toContain(DEV_TOKEN);
    expect(all).not.toContain(APP_SECRET);
  });
});

describe("dev auth", () => {
  it("rejects a missing or wrong token with 401", async () => {
    running = await start();
    for (const auth of [undefined, "Bearer wrong-token", `Basic ${DEV_TOKEN}`, DEV_TOKEN]) {
      const h = headers();
      if (auth === undefined) delete h.Authorization;
      else h.Authorization = auth;
      const res = await fetch(`${running.base}/sessions/new`, { method: "POST", headers: h });
      expect(res.status, String(auth)).toBe(401);
    }
    expect(running.upstream).toHaveLength(0);
  });

  it("rejects a missing or invalid X-Dev-User with 401", async () => {
    running = await start();
    for (const user of [undefined, "", "x".repeat(129)]) {
      const h = headers();
      if (user === undefined) delete h["X-Dev-User"];
      else h["X-Dev-User"] = user;
      const res = await fetch(`${running.base}/sessions/new`, { method: "POST", headers: h });
      expect(res.status, JSON.stringify(user)).toBe(401);
    }
  });

  it("validates user names", () => {
    expect(isValidDevUser("alice")).toBe(true);
    expect(isValidDevUser("Ada Lovelace")).toBe(true);
    expect(isValidDevUser("a")).toBe(true);
    expect(isValidDevUser(null)).toBe(false);
    expect(isValidDevUser("alice ")).toBe(false);
    expect(isValidDevUser("al\tice")).toBe(false);
  });

  it("compares tokens exactly", () => {
    expect(tokenMatches(DEV_TOKEN, DEV_TOKEN)).toBe(true);
    expect(tokenMatches(`${DEV_TOKEN}x`, DEV_TOKEN)).toBe(false);
    expect(tokenMatches("", DEV_TOKEN)).toBe(false);
    expect(tokenMatches(null, DEV_TOKEN)).toBe(false);
  });

  it("returns the user as the caller", () => {
    const auth = createDevAuthenticator(DEV_TOKEN);
    const req = new Request("http://x/", { headers: { "Authorization": `bearer ${DEV_TOKEN}`, "X-Dev-User": "bob" } });
    expect(auth(req)).toEqual({ id: "bob" });
  });
});
