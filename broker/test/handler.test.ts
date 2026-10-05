import { describe, expect, it } from "vitest";
import {
  type Caller,
  createBrokerHandler,
  type DataChannelEntry,
  type DataChannelRouteName,
  errorCause,
  formatBrokerError,
  InMemorySessionStore,
} from "../supabase/functions/_shared/broker-core/mod.ts";
import { APP_SECRET, makeBroker, newSession, req, SFU } from "./helpers.ts";

const FORBIDDEN = { errorCode: "forbidden" };

describe("routing", () => {
  it("returns 404 for unknown paths without calling upstream", async () => {
    const h = makeBroker();
    for (const path of ["/", "/sessions", "/sessions/abc/tracks", "/sessions/a.b/tracks/new", "/apps/x/sessions/new"]) {
      const res = await h.handler(req("POST", path, { user: "alice", room: "room-a" }));
      expect(res.status, path).toBe(404);
    }
    expect(h.calls).toHaveLength(0);
  });

  it("returns 405 for the wrong method", async () => {
    const h = makeBroker();
    const res = await h.handler(req("GET", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(405);
    expect(res.headers.get("Allow")).toBe("POST, OPTIONS");
  });

  it("serves routes under basePath only", async () => {
    const h = makeBroker({ basePath: "/realtime/" });
    expect((await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }))).status).toBe(404);
    expect((await h.handler(req("POST", "/realtimex/sessions/new", { user: "alice", room: "room-a" }))).status)
      .toBe(404);
    const res = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a", base: "/realtime" }));
    expect(res.status).toBe(201);
    expect(h.calls[0]!.url).toBe(`${SFU}/sessions/new`);
  });

  it("rejects invalid configuration", () => {
    const store = new InMemorySessionStore();
    const base = { appId: "a", appSecret: "s", authenticate: () => null, isRoomMember: () => false, sessionStore: store };
    expect(() => createBrokerHandler({ ...base, appSecret: "" })).toThrow();
    expect(() => createBrokerHandler({ ...base, sessionToken: { secret: "short" } })).toThrow();
    expect(() => createBrokerHandler({ ...base, turn: { keyId: "k", apiToken: "" } })).toThrow();
  });
});

describe("forwarding (rule 5)", () => {
  it("forwards sessions/new with only the App Secret and content type", async () => {
    const h = makeBroker();
    const res = await h.handler(
      req("POST", "/sessions/new?correlationId=abc", {
        user: "alice",
        room: "room-a",
        body: { sessionDescription: { type: "offer", sdp: "v=0" } },
        headers: {
          "Cookie": "sid=secret-cookie",
          "X-Realtime-Session-Token": "client-token",
          "X-Realtime-Other": "x",
          "X-Forwarded-For": "10.0.0.1",
          "Connection": "keep-alive",
          "X-Custom-App-Header": "y",
        },
      }),
    );
    expect(res.status).toBe(201);
    expect(await res.json()).toEqual({ sessionId: "sess1" });

    expect(h.calls).toHaveLength(1);
    const call = h.calls[0]!;
    expect(call.url).toBe(`${SFU}/sessions/new?correlationId=abc`);
    expect(call.method).toBe("POST");
    expect([...call.headers.keys()].sort()).toEqual(["authorization", "content-type"]);
    expect(call.headers.get("Authorization")).toBe(`Bearer ${APP_SECRET}`);
    expect(call.headers.get("Content-Type")).toBe("application/json");
    expect(JSON.parse(call.body!)).toEqual({ sessionDescription: { type: "offer", sdp: "v=0" } });
  });

  it("sends no body or content type when the client sends none", async () => {
    const h = makeBroker();
    await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(h.calls[0]!.body).toBeNull();
    expect([...h.calls[0]!.headers.keys()]).toEqual(["authorization"]);
  });

  it("drops upstream headers other than Content-Type", async () => {
    const h = makeBroker();
    const res = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(res.headers.get("Set-Cookie")).toBeNull();
    expect(res.headers.get("X-Upstream-Trace")).toBeNull();
    expect(res.headers.get("Content-Type")).toContain("application/json");
    expect(res.headers.get("Cache-Control")).toBe("no-store");
  });

  it("maps every session route to the same path under /apps/{appId}", async () => {
    const h = makeBroker();
    const { sessionId } = await newSession(h, "alice", "room-a");
    const routes: [string, string][] = [
      ["POST", "tracks/new"],
      ["PUT", "tracks/update"],
      ["PUT", "renegotiate"],
      ["PUT", "tracks/close"],
      ["POST", "datachannels/establish"],
      ["POST", "datachannels/new"],
      ["PUT", "datachannels/update"],
      ["PUT", "datachannels/close"],
    ];
    for (const [method, sub] of routes) {
      const res = await h.handler(req(method, `/sessions/${sessionId}/${sub}`, { user: "alice", room: "room-a", body: {} }));
      expect(res.status, sub).toBe(200);
      const call = h.calls.at(-1)!;
      expect(call.url).toBe(`${SFU}/sessions/${sessionId}/${sub}`);
      expect(call.method).toBe(method);
    }
    const res = await h.handler(req("GET", `/sessions/${sessionId}`, { user: "alice", room: "room-a" }));
    expect(res.status).toBe(200);
    expect(h.calls.at(-1)!.url).toBe(`${SFU}/sessions/${sessionId}`);
    expect(h.calls.at(-1)!.method).toBe("GET");
  });

  it("passes SFU errors through unchanged (410 session_error)", async () => {
    const h = makeBroker({}, (call) =>
      call.url.endsWith("/sessions/new")
        ? Response.json({ sessionId: "sess1" }, { status: 201 })
        : Response.json({ errorCode: "session_error", errorDescription: "gone" }, { status: 410 }));
    const { sessionId } = await newSession(h, "alice", "room-a");
    const res = await h.handler(req("PUT", `/sessions/${sessionId}/renegotiate`, { user: "alice", room: "room-a", body: {} }));
    expect(res.status).toBe(410);
    expect(await res.json()).toEqual({ errorCode: "session_error", errorDescription: "gone" });
  });

  it("does not store a session when sessions/new fails", async () => {
    const h = makeBroker({}, () => Response.json({ errorCode: "x", sessionId: "sessX" }, { status: 400 }));
    const res = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(400);
    expect(await h.store.get("sessX")).toBeNull();
  });

  it("returns 502 when the SFU is unreachable, and reports it without secrets", async () => {
    const h = makeBroker({}, () => {
      throw new TypeError(`network error for ${APP_SECRET}`);
    });
    const res = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(502);
    expect(h.errors).toHaveLength(1);
    expect(JSON.stringify(h.errors)).not.toContain(APP_SECRET);
  });

  it("reports the upstream error's code and how long the call took, never its message", async () => {
    // Shaped like Node's fetch failing on DNS: the messages name the URL.
    let h!: ReturnType<typeof makeBroker>;
    h = makeBroker({}, () => {
      h.clock.now += 1234;
      const cause = Object.assign(new Error(`getaddrinfo ENOTFOUND rtc.live.cloudflare.com ${APP_SECRET}`), {
        code: "ENOTFOUND",
      });
      throw new TypeError(`fetch failed: ${SFU}`, { cause });
    });
    const res = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(502);
    expect(h.errors).toEqual([
      { route: "sessions/new", message: "SFU request failed", cause: "TypeError: ENOTFOUND", elapsedMs: 1234 },
    ]);
    expect(formatBrokerError(h.errors[0]!)).toBe(
      "sessions/new: SFU request failed (TypeError: ENOTFOUND, after 1234 ms)",
    );
    expect(JSON.stringify(h.errors)).not.toContain("rtc.live.cloudflare.com");
    expect(JSON.stringify(h.errors)).not.toContain(APP_SECRET);
  });

  it("returns 500 when the store fails", async () => {
    const h = makeBroker({
      sessionStore: {
        put: () => Promise.reject(new Error("db down")),
        get: () => Promise.reject(new Error("db down")),
      },
    });
    expect((await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }))).status).toBe(500);
    expect((await h.handler(req("GET", "/sessions/sess9", { user: "alice", room: "room-a" }))).status).toBe(500);
    expect(h.errors.map((e) => e.message)).toEqual(["session store write failed", "session store read failed"]);
  });

  it("rejects invalid JSON and oversized bodies", async () => {
    const h = makeBroker({ maxBodyBytes: 64 });
    const bad = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a", rawBody: "{nope" }));
    expect(bad.status).toBe(400);
    const array = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a", rawBody: "[]" }));
    expect(array.status).toBe(400);
    const big = await h.handler(
      req("POST", "/sessions/new", { user: "alice", room: "room-a", body: { sdp: "x".repeat(100) } }),
    );
    expect(big.status).toBe(413);
    expect(h.calls).toHaveLength(0);
  });
});

describe("rule 1: authentication", () => {
  it("returns 401 without valid credentials, before any upstream call", async () => {
    const h = makeBroker();
    for (const path of ["/sessions/new", "/generate-ice-servers"]) {
      const res = await h.handler(req("POST", path, { room: "room-a" }));
      expect(res.status).toBe(401);
      expect(await res.json()).toMatchObject({ errorCode: "unauthorized" });
    }
    expect(h.calls).toHaveLength(0);
  });
});

describe("rule 2: room membership", () => {
  it("requires a valid X-Realtime-Room header", async () => {
    const h = makeBroker();
    expect((await h.handler(req("POST", "/sessions/new", { user: "alice" }))).status).toBe(400);
    const long = "r".repeat(300);
    expect((await h.handler(req("POST", "/sessions/new", { user: "alice", room: long }))).status).toBe(400);
  });

  it("returns 403 forbidden for non-members", async () => {
    const h = makeBroker();
    const res = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-b" }));
    expect(res.status).toBe(403);
    expect(await res.json()).toMatchObject(FORBIDDEN);
    expect(h.calls).toHaveLength(0);
  });

  it("records the room and owner of a new session", async () => {
    const h = makeBroker();
    const { sessionId } = await newSession(h, "alice", "room-a");
    expect(await h.store.get(sessionId)).toEqual({ roomId: "room-a", ownerId: "alice", createdAt: h.clock.now });
  });
});

describe("rule 3: session binding (store)", () => {
  it("lets the creator use its session", async () => {
    const h = makeBroker();
    const { sessionId } = await newSession(h, "alice", "room-a");
    const res = await h.handler(
      req("POST", `/sessions/${sessionId}/tracks/new`, {
        user: "alice",
        room: "room-a",
        body: { sessionDescription: { type: "offer", sdp: "v=0" }, tracks: [{ location: "local", mid: "0", trackName: "cam" }] },
      }),
    );
    expect(res.status).toBe(200);
  });

  it("rejects another user, another room, and unknown sessions", async () => {
    const h = makeBroker();
    const { sessionId } = await newSession(h, "alice", "room-a");
    const cases = [
      req("PUT", `/sessions/${sessionId}/tracks/close`, { user: "bob", room: "room-a", body: { tracks: [{ mid: "0" }] } }),
      req("GET", `/sessions/${sessionId}`, { user: "bob", room: "room-a" }),
      req("PUT", `/sessions/${sessionId}/renegotiate`, { user: "alice", room: "room-c", body: {} }),
      req("PUT", "/sessions/unknownsession/renegotiate", { user: "alice", room: "room-a", body: {} }),
    ];
    for (const r of cases) {
      const res = await h.handler(r);
      expect(res.status).toBe(403);
      expect(await res.json()).toMatchObject(FORBIDDEN);
    }
    expect(h.calls).toHaveLength(1); // only sessions/new
  });

  it("forgets sessions after the store TTL", async () => {
    const h = makeBroker();
    const { sessionId } = await newSession(h, "alice", "room-a");
    h.clock.now += 86400 * 1000 + 1;
    const res = await h.handler(req("GET", `/sessions/${sessionId}`, { user: "alice", room: "room-a" }));
    expect(res.status).toBe(403);
  });
});

describe("rule 4: same-room pulls", () => {
  async function setup() {
    const h = makeBroker();
    const alice = (await newSession(h, "alice", "room-a")).sessionId;
    const bob = (await newSession(h, "bob", "room-a")).sessionId;
    const carol = (await newSession(h, "carol", "room-b")).sessionId;
    const aliceInC = (await newSession(h, "alice", "room-c")).sessionId;
    return { h, alice, bob, carol, aliceInC };
  }

  const pull = (sessionId: string, from: string[], sub = "tracks/new") =>
    req(sub.endsWith("update") || sub.endsWith("close") ? "PUT" : "POST", `/sessions/${sessionId}/${sub}`, {
      user: "alice",
      room: "room-a",
      body: sub.startsWith("datachannels")
        ? { dataChannels: from.map((s) => ({ location: "remote", sessionId: s, dataChannelName: "input" })) }
        : { tracks: from.map((s) => ({ location: "remote", sessionId: s, trackName: "cam" })) },
    });

  it("allows pulls from sessions in the same room", async () => {
    const { h, alice, bob } = await setup();
    expect((await h.handler(pull(alice, [bob]))).status).toBe(200);
    expect((await h.handler(pull(alice, [bob], "datachannels/new"))).status).toBe(200);
    expect((await h.handler(pull(alice, [bob], "tracks/update"))).status).toBe(200);
    expect((await h.handler(pull(alice, [bob], "datachannels/update"))).status).toBe(200);
  });

  it("rejects pulls from another room, even the caller's own session there", async () => {
    const { h, alice, bob, carol, aliceInC } = await setup();
    const before = h.calls.length;
    for (const r of [
      pull(alice, [carol]),
      pull(alice, [bob, carol]),
      pull(alice, [aliceInC]),
      pull(alice, [carol], "datachannels/new"),
      pull(alice, [carol], "tracks/update"),
      pull(alice, [carol], "datachannels/update"),
      pull(alice, [carol], "datachannels/establish"),
    ]) {
      const res = await h.handler(r);
      expect(res.status).toBe(403);
      expect(await res.json()).toMatchObject(FORBIDDEN);
    }
    expect(h.calls.length).toBe(before);
  });

  it("rejects pulls from unknown sessions", async () => {
    const { h, alice } = await setup();
    expect((await h.handler(pull(alice, ["deadbeef"]))).status).toBe(403);
  });

  it("requires remote entries to name a session", async () => {
    const { h, alice } = await setup();
    const res = await h.handler(
      req("POST", `/sessions/${alice}/tracks/new`, {
        user: "alice",
        room: "room-a",
        body: { tracks: [{ location: "remote", trackName: "cam" }] },
      }),
    );
    expect(res.status).toBe(400);
  });

  it("allows establishing the DataChannel transport (server-events has no sessionId)", async () => {
    const { h, alice } = await setup();
    const res = await h.handler(
      req("POST", `/sessions/${alice}/datachannels/establish`, {
        user: "alice",
        room: "room-a",
        body: { dataChannel: { location: "remote", dataChannelName: "server-events" } },
      }),
    );
    expect(res.status).toBe(200);
  });

  it("rejects look-alike keys and non-string session IDs", async () => {
    const { h, alice, carol } = await setup();
    for (const entry of [
      { location: "remote", SessionId: carol, trackName: "cam" },
      { location: "remote", sessionid: carol, trackName: "cam" },
      { location: "remote", sessionId: [carol], trackName: "cam" },
    ]) {
      const res = await h.handler(
        req("POST", `/sessions/${alice}/tracks/new`, { user: "alice", room: "room-a", body: { tracks: [entry] } }),
      );
      expect(res.status).toBe(400);
    }
    const res = await h.handler(
      req("POST", `/sessions/${alice}/tracks/new`, { user: "alice", room: "room-a", body: { Tracks: [] } }),
    );
    expect(res.status).toBe(400);
    expect(h.calls.length).toBe(4); // only the four sessions/new
  });

  it("rejects Unicode look-alikes that case-folding decoders match (ſ for s, the Kelvin sign for k)", async () => {
    const { h, alice, carol } = await setup();
    const before = h.calls.length;
    const path = `/sessions/${alice}/tracks/new`;
    for (const rawBody of [
      `{"tracks":[{"location":"remote","ſessionId":"${carol}","trackName":"cam"}]}`,
      `{"tracKs":[{"location":"remote","sessionId":"${carol}","trackName":"cam"}]}`,
      `{"tracKS":[]}`,
    ]) {
      const res = await h.handler(req("POST", path, { user: "alice", room: "room-a", rawBody }));
      expect(res.status, rawBody).toBe(400);
      expect(await res.json()).toMatchObject({ errorCode: "bad_request" });
    }
    expect(h.calls.length).toBe(before);
  });

  it("rejects look-alike DataChannel keys (dataChannelName, canReply, id)", async () => {
    const { h, alice, bob } = await setup();
    const before = h.calls.length;
    const cases: [string, string, unknown][] = [
      ["POST", "datachannels/new", { dataChannels: [{ location: "local", DataChannelName: "chat" }] }],
      ["POST", "datachannels/new", { dataChannels: [{ location: "local", datachannelname: "chat" }] }],
      ["POST", "datachannels/new", {
        dataChannels: [{ location: "local", dataChannelName: "chat", DATACHANNELNAME: "x" }],
      }],
      ["POST", "datachannels/new", {
        dataChannels: [{ location: "remote", sessionId: bob, dataChannelName: "chat", CanReply: true }],
      }],
      ["PUT", "datachannels/update", {
        dataChannels: [{ location: "remote", sessionId: bob, dataChannelName: "chat", canreply: true }],
      }],
      ["PUT", "datachannels/close", { dataChannels: [{ ID: 2 }] }],
      ["PUT", "datachannels/close", { dataChannels: [{ Id: 2 }] }],
      ["POST", "datachannels/establish", { dataChannel: { location: "remote", DataChannelName: "server-events" } }],
    ];
    for (const [method, sub, body] of cases) {
      const res = await h.handler(req(method, `/sessions/${alice}/${sub}`, { user: "alice", room: "room-a", body }));
      expect(res.status, JSON.stringify(body)).toBe(400);
    }
    expect(h.calls.length).toBe(before);
  });

  it("checks and forwards the same value when keys are duplicated", async () => {
    const { h, alice, bob, carol } = await setup();
    const path = `/sessions/${alice}/tracks/new`;
    const smuggled = `{"tracks":[{"location":"remote","sessionId":"${bob}","sessionId":"${carol}","trackName":"cam"}]}`;
    expect((await h.handler(req("POST", path, { user: "alice", room: "room-a", rawBody: smuggled }))).status).toBe(403);

    const reversed = `{"tracks":[{"location":"remote","sessionId":"${carol}","sessionId":"${bob}","trackName":"cam"}]}`;
    expect((await h.handler(req("POST", path, { user: "alice", room: "room-a", rawBody: reversed }))).status).toBe(200);
    const forwarded = h.calls.at(-1)!.body!;
    expect(forwarded).not.toContain(carol);
    expect(JSON.parse(forwarded)).toEqual({ tracks: [{ location: "remote", sessionId: bob, trackName: "cam" }] });
  });
});

describe("authorizeDataChannels", () => {
  interface HookCall {
    caller: Caller;
    roomId: string;
    sessionId: string;
    route: DataChannelRouteName;
    entries: readonly DataChannelEntry[];
  }

  /** A broker whose hook records its calls and answers with `decide`. */
  async function setup(decide: (call: HookCall) => unknown = () => true) {
    const hookCalls: HookCall[] = [];
    const h = makeBroker({
      authorizeDataChannels: (caller, roomId, sessionId, route, entries) => {
        const call = { caller, roomId, sessionId, route, entries };
        hookCalls.push(call);
        return decide(call) as Promise<boolean> | boolean;
      },
    });
    const alice = (await newSession(h, "alice", "room-a")).sessionId;
    const bob = (await newSession(h, "bob", "room-a")).sessionId;
    const carol = (await newSession(h, "carol", "room-b")).sessionId;
    return { h, hookCalls, alice, bob, carol, sessionsCreated: h.calls.length };
  }

  const dc = (method: string, sessionId: string, sub: string, body?: unknown, user = "alice", room = "room-a") =>
    req(method, `/sessions/${sessionId}/${sub}`, { user, room, ...(body === undefined ? {} : { body }) });

  /** One request per DataChannel route, as the Dart client sends them. */
  const everyRoute = (alice: string, bob: string) => [
    {
      route: "datachannels/establish",
      request: dc("POST", alice, "datachannels/establish", {
        dataChannel: { location: "remote", dataChannelName: "server-events" },
      }),
      entries: [{ location: "remote", dataChannelName: "server-events" }],
    },
    {
      route: "datachannels/new",
      request: dc("POST", alice, "datachannels/new", {
        dataChannels: [
          { location: "local", dataChannelName: "pair:alice:bob", ordered: true },
          { location: "remote", sessionId: bob, dataChannelName: "chat", canReply: false, maxRetransmits: 0 },
        ],
      }),
      entries: [
        { location: "local", dataChannelName: "pair:alice:bob" },
        { location: "remote", sessionId: bob, dataChannelName: "chat", canReply: false },
      ],
    },
    {
      route: "datachannels/update",
      request: dc("PUT", alice, "datachannels/update", {
        dataChannels: [{ location: "remote", sessionId: bob, dataChannelName: "chat", canReply: true }],
      }),
      entries: [{ location: "remote", sessionId: bob, dataChannelName: "chat", canReply: true }],
    },
    {
      route: "datachannels/close",
      request: dc("PUT", alice, "datachannels/close", { dataChannels: [{ id: 2 }, { id: 3 }] }),
      entries: [{ id: 2 }, { id: 3 }],
    },
  ] as const;

  it("leaves every DataChannel route unchanged when unset", async () => {
    const h = makeBroker();
    const alice = (await newSession(h, "alice", "room-a")).sessionId;
    const bob = (await newSession(h, "bob", "room-a")).sessionId;
    for (const { route, request } of everyRoute(alice, bob)) {
      const sent = await request.clone().text();
      const res = await h.handler(request);
      expect(res.status, route).toBe(200);
      expect(h.calls.at(-1)!.url).toBe(`${SFU}/sessions/${alice}/${route}`);
      expect(JSON.parse(h.calls.at(-1)!.body!)).toEqual(JSON.parse(sent));
    }
    expect(h.calls).toHaveLength(2 + 4);
  });

  it("forwards when the hook returns true, and passes it the caller, room, session, route and entries", async () => {
    const { h, hookCalls, alice, bob, sessionsCreated } = await setup();
    const cases = everyRoute(alice, bob);
    for (const { route, request } of cases) {
      const sent = await request.clone().text();
      const res = await h.handler(request);
      expect(res.status, route).toBe(200);
      expect(JSON.parse(h.calls.at(-1)!.body!)).toEqual(JSON.parse(sent));
    }
    expect(h.calls).toHaveLength(sessionsCreated + cases.length);
    expect(hookCalls).toEqual(
      cases.map(({ route, entries }) => ({
        caller: { id: "alice" },
        roomId: "room-a",
        sessionId: alice,
        route,
        entries,
      })),
    );
    for (const { entries } of hookCalls) {
      expect(Object.isFrozen(entries)).toBe(true);
      for (const entry of entries) expect(Object.isFrozen(entry)).toBe(true);
    }
  });

  it("gives no entries for a request without a body", async () => {
    const { h, hookCalls, alice } = await setup();
    expect((await h.handler(dc("PUT", alice, "datachannels/close"))).status).toBe(200);
    expect(hookCalls.map((c) => c.entries)).toEqual([[]]);
  });

  it("refuses with 403 forbidden, and forwards nothing, unless the hook returns true", async () => {
    for (const answer of [false, undefined, null, 1, "true", Promise.resolve(false)]) {
      const { h, hookCalls, alice, bob, sessionsCreated } = await setup(() => answer);
      for (const { route, request } of everyRoute(alice, bob)) {
        const res = await h.handler(request);
        expect(res.status, `${route} ${String(answer)}`).toBe(403);
        expect(await res.json()).toEqual({
          errorCode: "forbidden",
          errorDescription: "DataChannel request not allowed",
        });
      }
      expect(hookCalls).toHaveLength(4);
      expect(h.calls).toHaveLength(sessionsCreated);
    }
  });

  it("returns 500 without the error's text, and forwards nothing, when the hook throws or rejects", async () => {
    const secretText = "lookup failed for grant table at db.internal";
    for (const decide of [
      () => {
        throw new Error(secretText);
      },
      () => Promise.reject(new Error(secretText)),
    ]) {
      const { h, alice, bob, sessionsCreated } = await setup(decide);
      for (const { route, request } of everyRoute(alice, bob)) {
        const res = await h.handler(request);
        expect(res.status, route).toBe(500);
        const text = await res.text();
        expect(JSON.parse(text)).toEqual({ errorCode: "internal_error", errorDescription: "internal error" });
        expect(text).not.toContain("lookup failed");
      }
      expect(h.calls).toHaveLength(sessionsCreated);
      expect(h.errors.map((e) => e.route)).toEqual([
        "datachannels/establish",
        "datachannels/new",
        "datachannels/update",
        "datachannels/close",
      ]);
      expect(h.errors.every((e) => e.message === "authorizeDataChannels failed" && e.cause === undefined)).toBe(true);
      expect(JSON.stringify(h.errors)).not.toContain("lookup failed");
    }
  });

  it("runs only after authentication, room membership, session ownership and same-room checks pass", async () => {
    const { h, hookCalls, alice, bob, carol, sessionsCreated } = await setup();
    const publish = { dataChannels: [{ location: "local", dataChannelName: "chat" }] };
    const cases: [Request, number][] = [
      [req("POST", `/sessions/${alice}/datachannels/new`, { room: "room-a", body: publish }), 401], // rule 1
      [dc("POST", alice, "datachannels/new", publish, "alice", "room-b"), 403], // rule 2
      [req("POST", `/sessions/${alice}/datachannels/new`, { user: "alice", body: publish }), 400], // rule 2: no room
      [dc("POST", alice, "datachannels/new", publish, "bob"), 403], // rule 3: bob doesn't own alice's session
      [dc("POST", "unknownsession", "datachannels/new", publish), 403], // rule 3: unknown session
      [dc("POST", alice, "datachannels/new", { // rule 4: carol's session is in room-b
        dataChannels: [{ location: "remote", sessionId: carol, dataChannelName: "chat" }],
      }), 403],
      [dc("PUT", alice, "datachannels/update", {
        dataChannels: [{ location: "remote", sessionId: carol, dataChannelName: "chat", canReply: true }],
      }), 403],
      [dc("POST", alice, "datachannels/new", { // remote entry without a session
        dataChannels: [{ location: "remote", dataChannelName: "chat" }],
      }), 400],
      [req("POST", `/sessions/${alice}/datachannels/new`, { user: "alice", room: "room-a", rawBody: "{nope" }), 400],
      [dc("POST", alice, "datachannels/new", { dataChannels: [{ location: "local", DataChannelName: "chat" }] }), 400],
    ];
    for (const [request, status] of cases) {
      expect((await h.handler(request)).status).toBe(status);
    }
    expect(hookCalls).toHaveLength(0);
    expect(h.calls).toHaveLength(sessionsCreated);
    // And a request that passes them reaches it.
    expect((await h.handler(dc("POST", alice, "datachannels/new", {
      dataChannels: [{ location: "remote", sessionId: bob, dataChannelName: "chat" }],
    }))).status).toBe(200);
    expect(hookCalls).toHaveLength(1);
  });

  it("isn't called for other routes, even when their body names DataChannels", async () => {
    const { h, hookCalls, alice, bob } = await setup(() => false);
    const res = await h.handler(
      req("POST", `/sessions/${alice}/tracks/new`, {
        user: "alice",
        room: "room-a",
        body: { tracks: [{ location: "remote", sessionId: bob, trackName: "cam" }] },
      }),
    );
    expect(res.status).toBe(200);
    expect((await h.handler(req("PUT", `/sessions/${alice}/renegotiate`, { user: "alice", room: "room-a", body: {} })))
      .status).toBe(200);
    expect((await h.handler(req("GET", `/sessions/${alice}`, { user: "alice", room: "room-a" }))).status).toBe(200);
    expect(hookCalls).toHaveLength(0);
  });

  it("sees the same value that is forwarded when keys are duplicated", async () => {
    const { h, hookCalls, alice } = await setup((call) => call.entries.every((e) => e.dataChannelName === "chat"));
    const path = `/sessions/${alice}/datachannels/new`;
    // The last duplicate wins in JSON.parse; the broker forwards its own serialization.
    const reserved = `{"dataChannels":[{"location":"local","dataChannelName":"chat","dataChannelName":"pair:alice:bob"}]}`;
    expect((await h.handler(req("POST", path, { user: "alice", room: "room-a", rawBody: reserved }))).status).toBe(403);
    const allowed = `{"dataChannels":[{"location":"local","dataChannelName":"pair:alice:bob","dataChannelName":"chat"}]}`;
    expect((await h.handler(req("POST", path, { user: "alice", room: "room-a", rawBody: allowed }))).status).toBe(200);
    const forwarded = h.calls.at(-1)!.body!;
    expect(forwarded).not.toContain("pair:");
    expect(JSON.parse(forwarded)).toEqual({ dataChannels: [{ location: "local", dataChannelName: "chat" }] });
    expect(hookCalls.map((c) => c.entries[0]!.dataChannelName)).toEqual(["pair:alice:bob", "chat"]);
  });

  it("covers both the dataChannel object and the dataChannels list on every route", async () => {
    const { h, hookCalls, alice } = await setup();
    const res = await h.handler(dc("POST", alice, "datachannels/new", {
      dataChannel: { location: "local", dataChannelName: "a" },
      dataChannels: [{ location: "local", dataChannelName: "b" }],
    }));
    expect(res.status).toBe(200);
    expect(hookCalls[0]!.entries).toEqual([
      { location: "local", dataChannelName: "a" },
      { location: "local", dataChannelName: "b" },
    ]);
  });

  it("refuses entries with fields of the wrong type with 400, before the hook", async () => {
    const { h, hookCalls, alice, sessionsCreated } = await setup();
    for (const body of [
      { dataChannels: [{ location: "local", dataChannelName: 7 }] },
      { dataChannels: [{ location: "local", dataChannelName: ["pair:alice:bob"] }] },
      { dataChannels: [{ location: "Local", dataChannelName: "chat" }] },
      { dataChannels: [{ location: null, dataChannelName: "chat" }] },
      { dataChannels: [{ location: "local", dataChannelName: "chat", canReply: "yes" }] },
      { dataChannels: [{ id: 1.5 }] },
      { dataChannels: [{ id: "2" }] },
      { dataChannels: ["chat"] },
      { dataChannel: "server-events" },
      { dataChannel: [{ location: "remote", dataChannelName: "server-events" }] },
    ]) {
      const res = await h.handler(dc("POST", alice, "datachannels/new", body));
      expect(res.status, JSON.stringify(body)).toBe(400);
      expect(await res.json()).toMatchObject({ errorCode: "bad_request" });
    }
    expect(hookCalls).toHaveLength(0);
    expect(h.calls).toHaveLength(sessionsCreated);
  });

  it("can limit a channel prefix to a granted pair (the README's example)", async () => {
    const granted = new Set(["alice:bob"]);
    const { h, alice, bob, sessionsCreated } = await setup(({ caller, entries }) => {
      for (const { dataChannelName } of entries) {
        if (dataChannelName === undefined || !dataChannelName.startsWith("pair:")) continue;
        const ids = dataChannelName.slice("pair:".length).split(":");
        if (ids.length !== 2 || !ids.includes(caller.id)) return false;
        if (!granted.has([...ids].sort().join(":"))) return false;
      }
      return true;
    });
    const mallory = (await newSession(h, "carol", "room-c")).sessionId;
    const aliceInC = (await newSession(h, "alice", "room-c")).sessionId;
    const publish = (name: string) => ({ dataChannels: [{ location: "local", dataChannelName: name }] });
    const subscribe = (from: string, name: string) => ({
      dataChannels: [{ location: "remote", sessionId: from, dataChannelName: name }],
    });

    expect((await h.handler(dc("POST", alice, "datachannels/new", publish("pair:alice:bob")))).status).toBe(200);
    expect((await h.handler(dc("POST", bob, "datachannels/new", subscribe(alice, "pair:alice:bob"), "bob"))).status)
      .toBe(200);
    expect((await h.handler(dc("POST", bob, "datachannels/new", subscribe(alice, "chat"), "bob"))).status).toBe(200);
    // carol is in room-c with alice, but not in the pair: she can neither publish nor subscribe to it.
    const carolCalls = [
      dc("POST", mallory, "datachannels/new", publish("pair:alice:bob"), "carol", "room-c"),
      dc("POST", mallory, "datachannels/new", subscribe(aliceInC, "pair:alice:bob"), "carol", "room-c"),
      dc("POST", mallory, "datachannels/new", subscribe(aliceInC, "pair:carol:alice"), "carol", "room-c"),
    ];
    for (const r of carolCalls) expect((await h.handler(r)).status).toBe(403);
    expect(h.calls).toHaveLength(sessionsCreated + 2 + 3);
  });
});

describe("signed session tokens", () => {
  const withTokens = () => makeBroker({ sessionToken: { secret: "test-session-token-secret-0123456789abcdef" } });

  it("returns a token from sessions/new and accepts it on later calls", async () => {
    const h = withTokens();
    const { sessionId, token } = await newSession(h, "alice", "room-a");
    expect(token).toMatch(/^[\w-]+\.[\w-]+$/);
    const res = await h.handler(
      req("PUT", `/sessions/${sessionId}/renegotiate`, {
        user: "alice",
        room: "room-a",
        body: {},
        headers: { "X-Realtime-Session-Token": token! },
      }),
    );
    expect(res.status).toBe(200);
    // The token is never forwarded.
    expect(h.calls.at(-1)!.headers.has("X-Realtime-Session-Token")).toBe(false);
  });

  it("requires the token when enabled", async () => {
    const h = withTokens();
    const { sessionId } = await newSession(h, "alice", "room-a");
    const res = await h.handler(req("PUT", `/sessions/${sessionId}/renegotiate`, { user: "alice", room: "room-a", body: {} }));
    expect(res.status).toBe(403);
  });

  it("rejects a token for another session, room or user, a tampered token, and an expired one", async () => {
    const h = withTokens();
    const a = await newSession(h, "alice", "room-a");
    const b = await newSession(h, "bob", "room-a");
    const c = await newSession(h, "alice", "room-c");
    const call = (sessionId: string, token: string, user = "alice", room = "room-a") =>
      h.handler(
        req("PUT", `/sessions/${sessionId}/renegotiate`, {
          user,
          room,
          body: {},
          headers: { "X-Realtime-Session-Token": token },
        }),
      );
    expect((await call(a.sessionId, b.token!)).status).toBe(403); // bob's token on alice's session
    expect((await call(b.sessionId, b.token!, "alice")).status).toBe(403); // bob's session, alice calling
    expect((await call(c.sessionId, c.token!, "alice", "room-a")).status).toBe(403); // room mismatch
    const [body, sig] = a.token!.split(".");
    const flipped = sig!.startsWith("A") ? `B${sig!.slice(1)}` : `A${sig!.slice(1)}`;
    expect((await call(a.sessionId, `${body}.${flipped}`)).status).toBe(403);
    expect((await call(a.sessionId, "garbage")).status).toBe(403);
    expect((await call(a.sessionId, a.token!)).status).toBe(200);
    h.clock.now += 86400 * 1000 + 1000;
    expect((await call(a.sessionId, a.token!)).status).toBe(403);
  });

  it("still checks pulls against the store", async () => {
    const h = withTokens();
    const a = await newSession(h, "alice", "room-a");
    const carol = await newSession(h, "carol", "room-b");
    const res = await h.handler(
      req("POST", `/sessions/${a.sessionId}/tracks/new`, {
        user: "alice",
        room: "room-a",
        body: { tracks: [{ location: "remote", sessionId: carol.sessionId, trackName: "cam" }] },
        headers: { "X-Realtime-Session-Token": a.token! },
      }),
    );
    expect(res.status).toBe(403);
  });

  it("does not send a token when disabled", async () => {
    const h = makeBroker();
    expect((await newSession(h, "alice", "room-a")).token).toBeNull();
  });
});

describe("generate-ice-servers", () => {
  it("returns Cloudflare STUN only without TURN", async () => {
    const h = makeBroker();
    const res = await h.handler(req("POST", "/generate-ice-servers", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ iceServers: [{ urls: ["stun:stun.cloudflare.com:3478"] }] });
    expect(h.calls).toHaveLength(0);
  });

  it("generates TURN credentials with the TURN key", async () => {
    const turnToken = "test-turn-token-not-real";
    const h = makeBroker(
      { turn: { keyId: "turnkey1", apiToken: turnToken, ttlSeconds: 3600 } },
      () =>
        Response.json(
          {
            iceServers: [
              { urls: ["stun:stun.cloudflare.com:3478", "stun:stun.cloudflare.com:53"] },
              {
                urls: [
                  "turn:turn.cloudflare.com:3478?transport=udp",
                  "turn:turn.cloudflare.com:53?transport=udp",
                  "turns:turn.cloudflare.com:443?transport=tcp",
                ],
                username: "u",
                credential: "c",
              },
            ],
          },
          { status: 201 },
        ),
    );
    const res = await h.handler(req("POST", "/generate-ice-servers", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({
      iceServers: [
        { urls: ["stun:stun.cloudflare.com:3478"] },
        {
          urls: ["turn:turn.cloudflare.com:3478?transport=udp", "turns:turn.cloudflare.com:443?transport=tcp"],
          username: "u",
          credential: "c",
        },
      ],
    });
    const call = h.calls[0]!;
    expect(call.url).toBe("https://rtc.live.cloudflare.com/v1/turn/keys/turnkey1/credentials/generate-ice-servers");
    expect(call.method).toBe("POST");
    expect(call.headers.get("Authorization")).toBe(`Bearer ${turnToken}`);
    expect(JSON.parse(call.body!)).toEqual({ ttl: 3600 });
  });

  it("accepts GET for partytracks compatibility", async () => {
    const h = makeBroker();
    expect((await h.handler(req("GET", "/generate-ice-servers", { user: "alice", room: "room-a" }))).status).toBe(200);
  });

  it("returns 502 when the TURN API fails", async () => {
    const h = makeBroker({ turn: { keyId: "k", apiToken: "test-turn-token-not-real" } }, () =>
      new Response("nope", { status: 401 }));
    const res = await h.handler(req("POST", "/generate-ice-servers", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(502);
    expect(h.errors).toEqual([{ route: "generate-ice-servers", message: "TURN API returned HTTP 401" }]);
  });

  it("reports why the TURN API couldn't be reached, by error code only", async () => {
    const turnToken = "test-turn-token-not-real";
    const h = makeBroker({ turn: { keyId: "k", apiToken: turnToken } }, () => {
      const cause = Object.assign(new Error(`Connect Timeout Error ${turnToken}`), {
        name: "ConnectTimeoutError",
        code: "UND_ERR_CONNECT_TIMEOUT",
      });
      throw new TypeError("fetch failed", { cause });
    });
    const res = await h.handler(req("POST", "/generate-ice-servers", { user: "alice", room: "room-a" }));
    expect(res.status).toBe(502);
    expect(h.errors).toEqual([{
      route: "generate-ice-servers",
      message: "TURN request failed",
      cause: "TypeError: UND_ERR_CONNECT_TIMEOUT",
      elapsedMs: 0,
    }]);
    expect(JSON.stringify(h.errors)).not.toContain(turnToken);
  });

  it("requires room membership", async () => {
    const h = makeBroker();
    expect((await h.handler(req("POST", "/generate-ice-servers", { user: "alice", room: "room-b" }))).status)
      .toBe(403);
  });
});

describe("CORS", () => {
  const origin = "https://app.example.com";
  const cors = { allowedOrigins: [origin], extraAllowedHeaders: ["X-App-Version"] };

  it("answers an allowed preflight", async () => {
    const h = makeBroker({ cors });
    const res = await h.handler(
      new Request("https://broker.example/sessions/abc/tracks/new", {
        method: "OPTIONS",
        headers: { "Origin": origin, "Access-Control-Request-Method": "POST" },
      }),
    );
    expect(res.status).toBe(204);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe(origin);
    expect(res.headers.get("Access-Control-Allow-Methods")).toBe("GET, POST, PUT, OPTIONS");
    expect(res.headers.get("Access-Control-Allow-Headers")).toBe(
      "authorization, content-type, x-realtime-room, x-realtime-session-token, x-app-version",
    );
    expect(res.headers.get("Access-Control-Allow-Credentials")).toBeNull();
    expect(res.headers.get("Vary")).toBe("Origin");
  });

  it("rejects a preflight from another origin", async () => {
    const h = makeBroker({ cors });
    const res = await h.handler(
      new Request("https://broker.example/sessions/new", {
        method: "OPTIONS",
        headers: { "Origin": "https://evil.example" },
      }),
    );
    expect(res.status).toBe(403);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBeNull();
  });

  it("adds CORS headers to responses, including errors, and exposes the session token", async () => {
    const h = makeBroker({ cors });
    const ok = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a", headers: { Origin: origin } }));
    expect(ok.status).toBe(201);
    expect(ok.headers.get("Access-Control-Allow-Origin")).toBe(origin);
    expect(ok.headers.get("Access-Control-Expose-Headers")).toBe("x-realtime-session-token");
    const denied = await h.handler(req("POST", "/sessions/new", { room: "room-a", headers: { Origin: origin } }));
    expect(denied.status).toBe(401);
    expect(denied.headers.get("Access-Control-Allow-Origin")).toBe(origin);
  });

  it("rejects requests from origins that are not allowed", async () => {
    const h = makeBroker({ cors });
    const res = await h.handler(
      req("POST", "/sessions/new", { user: "alice", room: "room-a", headers: { Origin: "https://evil.example" } }),
    );
    expect(res.status).toBe(403);
    expect(h.calls).toHaveLength(0);
  });

  it("rejects browser requests when CORS is not configured, but allows native clients", async () => {
    const h = makeBroker();
    const browser = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a", headers: { Origin: origin } }));
    expect(browser.status).toBe(403);
    const native = await h.handler(req("POST", "/sessions/new", { user: "alice", room: "room-a" }));
    expect(native.status).toBe(201);
  });

  it("supports a wildcard origin", async () => {
    const h = makeBroker({ cors: { allowedOrigins: "*" } });
    const res = await h.handler(
      req("POST", "/sessions/new", { user: "alice", room: "room-a", headers: { Origin: "https://any.example" } }),
    );
    expect(res.status).toBe(201);
    expect(res.headers.get("Access-Control-Allow-Origin")).toBe("*");
  });
});

describe("diagnostics", () => {
  it("describes errors by code or name along the cause chain", () => {
    const connect = Object.assign(new Error("x"), { name: "ConnectTimeoutError", code: "UND_ERR_CONNECT_TIMEOUT" });
    expect(errorCause(new TypeError("fetch failed", { cause: connect }))).toBe("TypeError: UND_ERR_CONNECT_TIMEOUT");
    expect(errorCause(new TypeError("error sending request for url (https://example)"))).toBe("TypeError");
    expect(errorCause(new DOMException("signal timed out", "TimeoutError"))).toBe("TimeoutError");
    const reset = Object.assign(new Error("read ECONNRESET"), { code: "ECONNRESET" });
    expect(errorCause(new TypeError("fetch failed", { cause: reset }))).toBe("TypeError: ECONNRESET");
  });

  it("never passes free text through", () => {
    const sneaky = Object.assign(new Error("m"), { name: "has spaces and a https://url", code: "Bearer abc def" });
    expect(errorCause(sneaky)).toBeUndefined();
    expect(errorCause("a string")).toBeUndefined();
    expect(errorCause(null)).toBeUndefined();
    expect(errorCause({ code: 42 })).toBeUndefined();
  });

  it("stops on cyclic cause chains", () => {
    const a = new Error("a") as Error & { cause?: unknown; code?: string };
    a.code = "EA";
    const b = new Error("b") as Error & { cause?: unknown; code?: string };
    b.code = "EB";
    a.cause = b;
    b.cause = a;
    expect(errorCause(a)).toBe("EA: EB: EA: EB");
  });

  it("formats an error line", () => {
    expect(formatBrokerError({ route: "tracks/new", message: "internal error" })).toBe("tracks/new: internal error");
    expect(formatBrokerError({ route: "sessions/new", message: "SFU request failed", elapsedMs: 10012.4 })).toBe(
      "sessions/new: SFU request failed (after 10012 ms)",
    );
  });
});
