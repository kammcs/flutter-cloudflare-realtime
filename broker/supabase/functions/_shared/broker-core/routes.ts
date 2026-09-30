/** Route table for the broker contract (docs/design.md §5). */

/** Names of the routes the broker serves. */
export type RouteName =
  | "sessions/new"
  | "sessions/get"
  | "tracks/new"
  | "tracks/update"
  | "renegotiate"
  | "tracks/close"
  | "datachannels/establish"
  | "datachannels/new"
  | "datachannels/update"
  | "datachannels/close"
  | "generate-ice-servers";

/** A matched route. */
export interface Route {
  readonly name: RouteName;
  /** HTTP methods the route accepts. */
  readonly methods: readonly string[];
  /** The `{id}` path segment for session routes. */
  readonly sessionId?: string;
  /** The SFU path under `/apps/{appId}` (for example `/sessions/abc/tracks/new`). */
  readonly upstreamPath?: string;
}

/**
 * Session IDs are opaque to the broker, but they are always URL-safe tokens
 * (32 hex characters today). Anything else (dots, `%`, slashes) is rejected so
 * that a crafted ID can't change the upstream path.
 */
const SESSION_ID = "[A-Za-z0-9_-]{1,128}";

const SESSION_SUBROUTES: Record<string, { name: RouteName; method: string }> = {
  "tracks/new": { name: "tracks/new", method: "POST" },
  "tracks/update": { name: "tracks/update", method: "PUT" },
  "renegotiate": { name: "renegotiate", method: "PUT" },
  "tracks/close": { name: "tracks/close", method: "PUT" },
  "datachannels/establish": { name: "datachannels/establish", method: "POST" },
  "datachannels/new": { name: "datachannels/new", method: "POST" },
  "datachannels/update": { name: "datachannels/update", method: "PUT" },
  "datachannels/close": { name: "datachannels/close", method: "PUT" },
};

const SESSION_ROUTE = new RegExp(
  `^/sessions/(${SESSION_ID})(?:/(tracks/new|tracks/update|renegotiate|tracks/close|datachannels/establish|datachannels/new|datachannels/update|datachannels/close))?$`,
);

/**
 * Matches `path` (the request path with the base path already removed).
 * Returns `null` for unknown paths.
 */
export function matchRoute(path: string): Route | null {
  if (path === "/sessions/new") {
    return { name: "sessions/new", methods: ["POST"], upstreamPath: "/sessions/new" };
  }
  if (path === "/generate-ice-servers") {
    // POST is the contract; GET keeps partytracks clients working.
    return { name: "generate-ice-servers", methods: ["POST", "GET"] };
  }
  const m = SESSION_ROUTE.exec(path);
  if (!m) return null;
  const sessionId = m[1]!;
  const sub = m[2];
  if (sub === undefined) {
    return {
      name: "sessions/get",
      methods: ["GET"],
      sessionId,
      upstreamPath: `/sessions/${sessionId}`,
    };
  }
  const { name, method } = SESSION_SUBROUTES[sub]!;
  return {
    name,
    methods: [method],
    sessionId,
    upstreamPath: `/sessions/${sessionId}/${sub}`,
  };
}
