import {
  type BrokerConfig,
  type BrokerErrorInfo,
  type Caller,
  createBrokerHandler,
  InMemorySessionStore,
} from "../supabase/functions/_shared/broker-core/mod.ts";

// Fake, test-only values. They are not real credentials.
export const APP_ID = "test-app-id";
export const APP_SECRET = "test-app-secret-not-real";
export const TOKEN_SECRET = "test-session-token-secret-0123456789abcdef";
export const SFU = `https://rtc.live.cloudflare.com/v1/apps/${APP_ID}`;

export interface RecordedCall {
  url: string;
  method: string;
  headers: Headers;
  body: string | null;
}

export type Upstream = (call: RecordedCall) => Response | Promise<Response>;

/** A mocked upstream `fetch` that records every call. */
export function mockFetch(upstream: Upstream) {
  const calls: RecordedCall[] = [];
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    const call: RecordedCall = {
      url: String(input),
      method: init?.method ?? "GET",
      headers: new Headers(init?.headers),
      body: typeof init?.body === "string" ? init.body : init?.body == null ? null : "<stream>",
    };
    calls.push(call);
    return upstream(call);
  }) as typeof fetch;
  return { calls, fetchImpl };
}

/** The default fake SFU: `sessions/new` returns a fresh ID, everything else echoes 200. */
export function fakeSfu(): Upstream {
  let n = 0;
  return (call) => {
    if (call.url.startsWith(`${SFU}/sessions/new`)) {
      n++;
      return Response.json({ sessionId: `sess${n}` }, {
        status: 201,
        headers: { "Set-Cookie": "upstream=1", "X-Upstream-Trace": "abc" },
      });
    }
    return Response.json({ ok: true, requiresImmediateRenegotiation: false });
  };
}

/** Room membership used by the tests: alice and bob are in room-a, carol in room-b, all in room-c. */
export const MEMBERS: Record<string, string[]> = {
  "room-a": ["alice", "bob"],
  "room-b": ["carol"],
  "room-c": ["alice", "bob", "carol"],
};

export interface Harness {
  handler: (request: Request) => Promise<Response>;
  calls: RecordedCall[];
  store: InMemorySessionStore;
  errors: BrokerErrorInfo[];
  clock: { now: number };
}

export function makeBroker(
  overrides: Partial<BrokerConfig<Caller>> = {},
  upstream: Upstream = fakeSfu(),
): Harness {
  const clock = { now: Date.UTC(2026, 8, 30, 12, 0, 0) };
  const store = new InMemorySessionStore({ now: () => clock.now });
  const { calls, fetchImpl } = mockFetch(upstream);
  const errors: BrokerErrorInfo[] = [];
  const handler = createBrokerHandler<Caller>({
    appId: APP_ID,
    appSecret: APP_SECRET,
    authenticate: (req) => {
      const m = /^Bearer user:(\w+)$/.exec(req.headers.get("Authorization") ?? "");
      return m ? { id: m[1]! } : null;
    },
    isRoomMember: (caller, roomId) => MEMBERS[roomId]?.includes(caller.id) ?? false,
    sessionStore: store,
    fetch: fetchImpl,
    now: () => clock.now,
    onError: (info) => errors.push(info),
    ...overrides,
  });
  return { handler, calls, store, errors, clock };
}

/** Builds a broker request as the Dart client would send it. */
export function req(
  method: string,
  path: string,
  options: {
    user?: string;
    room?: string;
    body?: unknown;
    rawBody?: string;
    headers?: Record<string, string>;
    base?: string;
  } = {},
): Request {
  const headers = new Headers(options.headers);
  if (options.user) headers.set("Authorization", `Bearer user:${options.user}`);
  if (options.room) headers.set("X-Realtime-Room", options.room);
  let body: string | undefined;
  if (options.rawBody !== undefined) body = options.rawBody;
  else if (options.body !== undefined) body = JSON.stringify(options.body);
  if (body !== undefined) headers.set("Content-Type", "application/json");
  return new Request(`https://broker.example${options.base ?? ""}${path}`, { method, headers, body });
}

/** Creates a session through the broker and returns its ID and token header. */
export async function newSession(
  h: Harness,
  user: string,
  room: string,
): Promise<{ sessionId: string; token: string | null }> {
  const res = await h.handler(req("POST", "/sessions/new", { user, room }));
  if (res.status !== 201) throw new Error(`sessions/new failed: ${res.status}`);
  const { sessionId } = (await res.json()) as { sessionId: string };
  return { sessionId, token: res.headers.get("X-Realtime-Session-Token") };
}
