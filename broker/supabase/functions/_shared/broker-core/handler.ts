/**
 * The framework-agnostic broker handler (docs/design.md §5).
 *
 * `createBrokerHandler(config)` returns a `(Request) => Promise<Response>`
 * function that serves the broker contract and forwards allowed calls to the
 * Cloudflare Realtime SFU. It enforces the five security rules:
 *
 * 1. Authenticate the caller (`config.authenticate`).
 * 2. Authorize the room named by `X-Realtime-Room` (`config.isRoomMember`).
 * 3. Bind each session to its creator: calls on `sessions/{id}` require that
 *    the caller created `{id}` for the same room (store lookup, or a signed
 *    `X-Realtime-Session-Token`).
 * 4. Restrict pulls to the same room: every `sessionId` named in a request
 *    body must be a session the broker created for the caller's room.
 * 5. Forward only what Cloudflare needs (the App Secret as `Authorization`,
 *    and `Content-Type`), and never log secrets, SDP, tokens or headers.
 */

import { BadBodyError, EMPTY_BODY, type InspectedBody, inspectBody } from "./body.ts";
import { corsResponseHeaders, isOriginAllowed, preflightResponse } from "./cors.ts";
import { errorCause } from "./diagnostics.ts";
import { generateIceServers, STUN_ONLY, TurnError } from "./ice.ts";
import { matchRoute, type Route } from "./routes.ts";
import { MIN_SESSION_TOKEN_SECRET_LENGTH, signSessionToken, verifySessionToken } from "./session_token.ts";
import type { BrokerConfig, Caller, SessionStore } from "./types.ts";

/** Request header naming the room. */
export const ROOM_HEADER = "X-Realtime-Room";
/** Request and response header carrying the optional signed session token. */
export const SESSION_TOKEN_HEADER = "X-Realtime-Session-Token";

const DEFAULT_API_BASE_URL = "https://rtc.live.cloudflare.com/v1";
const DEFAULT_MAX_BODY_BYTES = 1024 * 1024;
const MAX_ROOM_ID_LENGTH = 256;

/** A broker request handler. */
export type BrokerHandler = (request: Request) => Promise<Response>;

/** Thrown when the store fails; mapped to 500. */
class StoreError extends Error {}

function errorBody(errorCode: string, errorDescription: string): string {
  return JSON.stringify({ errorCode, errorDescription });
}

/** Checks the room header. Room IDs are opaque, but must be short printable text. */
function isValidRoomId(roomId: string): boolean {
  // deno-lint-ignore no-control-regex
  return roomId.length > 0 && roomId.length <= MAX_ROOM_ID_LENGTH && !/[\u0000-\u001f\u007f]/.test(roomId);
}

/** Creates a broker handler from `config`. Throws on invalid configuration. */
export function createBrokerHandler<C extends Caller>(config: BrokerConfig<C>): BrokerHandler {
  if (!config.appId) throw new Error("appId is required");
  if (!config.appSecret) throw new Error("appSecret is required");
  if (config.sessionToken && config.sessionToken.secret.length < MIN_SESSION_TOKEN_SECRET_LENGTH) {
    throw new Error(
      `sessionToken.secret must be at least ${MIN_SESSION_TOKEN_SECRET_LENGTH} characters`,
    );
  }
  if (config.turn && (!config.turn.keyId || !config.turn.apiToken)) {
    throw new Error("turn.keyId and turn.apiToken are both required when turn is set");
  }

  const basePath = (config.basePath ?? "").replace(/\/+$/, "");
  const apiBaseUrl = (config.apiBaseUrl ?? DEFAULT_API_BASE_URL).replace(/\/+$/, "");
  const maxBodyBytes = config.maxBodyBytes ?? DEFAULT_MAX_BODY_BYTES;
  const fetchImpl = config.fetch ?? ((input, init) => fetch(input, init));
  const now = config.now ?? Date.now;
  const store: SessionStore = config.sessionStore;
  const upstreamBase = `${apiBaseUrl}/apps/${encodeURIComponent(config.appId)}`;

  const report = (route: string, message: string, upstream?: { error: unknown; startedAt: number }) => {
    try {
      const cause = upstream === undefined ? undefined : errorCause(upstream.error);
      config.onError?.({
        route,
        message,
        ...(cause !== undefined ? { cause } : {}),
        ...(upstream !== undefined ? { elapsedMs: Math.max(0, now() - upstream.startedAt) } : {}),
      });
    } catch {
      // Diagnostics must never break a request.
    }
  };

  const storeGet = async (sessionId: string) => {
    try {
      return await store.get(sessionId);
    } catch {
      throw new StoreError("session store read failed");
    }
  };

  return async function handle(request: Request): Promise<Response> {
    const origin = request.headers.get("Origin");
    const cors = corsResponseHeaders(origin, config.cors);

    const json = (status: number, body: string, extra: Record<string, string> = {}) =>
      new Response(body, {
        status,
        headers: {
          "Content-Type": "application/json",
          "Cache-Control": "no-store",
          ...cors,
          ...extra,
        },
      });
    const fail = (status: number, code: string, description: string, extra?: Record<string, string>) =>
      json(status, errorBody(code, description), extra);

    if (request.method === "OPTIONS") return preflightResponse(request, config.cors);
    if (!isOriginAllowed(origin, config.cors)) {
      return fail(403, "forbidden", "origin not allowed");
    }

    // Routing.
    const url = new URL(request.url);
    let path = url.pathname;
    if (basePath) {
      if (path !== basePath && !path.startsWith(`${basePath}/`)) {
        return fail(404, "not_found", "unknown path");
      }
      path = path.slice(basePath.length);
    }
    const route = matchRoute(path);
    if (!route) return fail(404, "not_found", "unknown path");
    if (!route.methods.includes(request.method)) {
      return fail(405, "method_not_allowed", "method not allowed", {
        "Allow": [...route.methods, "OPTIONS"].join(", "),
      });
    }

    try {
      // Rule 1: authenticate.
      const caller = await config.authenticate(request);
      if (!caller || typeof caller.id !== "string" || caller.id === "") {
        return fail(401, "unauthorized", "authentication required");
      }

      // Rule 2: authorize the room.
      const roomId = request.headers.get(ROOM_HEADER);
      if (roomId === null || !isValidRoomId(roomId)) {
        return fail(400, "bad_request", `missing or invalid ${ROOM_HEADER} header`);
      }
      if (!(await config.isRoomMember(caller, roomId))) {
        return fail(403, "forbidden", "not a member of this room");
      }

      if (route.name === "generate-ice-servers") {
        if (!config.turn) return json(200, JSON.stringify(STUN_ONLY));
        const startedAt = now();
        try {
          return json(200, JSON.stringify(await generateIceServers(config.turn, apiBaseUrl, fetchImpl)));
        } catch (e) {
          if (e instanceof TurnError) report(route.name, e.message);
          else report(route.name, "TURN request failed", { error: e, startedAt });
          return fail(502, "upstream_error", "could not generate ICE servers");
        }
      }

      // Body (limited, parsed, inspected, re-serialized).
      let body: InspectedBody = EMPTY_BODY;
      if (request.method !== "GET") {
        const declared = Number(request.headers.get("Content-Length") ?? "0");
        if (declared > maxBodyBytes) return fail(413, "payload_too_large", "request body too large");
        const text = await request.text();
        if (new TextEncoder().encode(text).byteLength > maxBodyBytes) {
          return fail(413, "payload_too_large", "request body too large");
        }
        try {
          body = inspectBody(text);
        } catch (e) {
          if (e instanceof BadBodyError) return fail(400, "bad_request", e.message);
          throw e;
        }
      }
      if (
        body.remoteEntriesWithoutSessionId > 0 &&
        (route.name === "tracks/new" || route.name === "datachannels/new")
      ) {
        return fail(400, "bad_request", "remote entries must name a sessionId");
      }

      // Rule 3: the caller must own the session named in the path.
      if (route.sessionId !== undefined) {
        const owns = await ownsSession(request, route.sessionId, caller.id, roomId);
        if (!owns) return fail(403, "forbidden", "session not owned by caller");
      }

      // Rule 4: every other session named in the body must be in the same room.
      for (const sessionId of body.sessionIds) {
        if (sessionId === route.sessionId) continue;
        const record = await storeGet(sessionId);
        if (!record || record.roomId !== roomId) {
          return fail(403, "forbidden", "session is not in this room");
        }
      }

      // Rule 5: forward with only the headers Cloudflare needs.
      const upstream = await forward(route, url.search, request.method, body.json);
      if (upstream === null) return fail(502, "upstream_error", "could not reach the SFU");

      if (route.name === "sessions/new") {
        return await completeNewSession(upstream, caller.id, roomId, cors);
      }
      return passThrough(upstream, cors);
    } catch (e) {
      report(route.name, e instanceof StoreError ? e.message : "internal error");
      return fail(500, "internal_error", "internal error");
    }
  };

  async function ownsSession(
    request: Request,
    sessionId: string,
    callerId: string,
    roomId: string,
  ): Promise<boolean> {
    if (config.sessionToken) {
      const token = request.headers.get(SESSION_TOKEN_HEADER);
      if (!token) return false;
      const claims = await verifySessionToken(token, config.sessionToken.secret, now() / 1000);
      return claims !== null &&
        claims.sessionId === sessionId &&
        claims.roomId === roomId &&
        claims.ownerId === callerId;
    }
    const record = await storeGet(sessionId);
    return record !== null && record.ownerId === callerId && record.roomId === roomId;
  }

  async function forward(
    route: Route,
    search: string,
    method: string,
    json: string | null,
  ): Promise<Response | null> {
    const headers: Record<string, string> = { "Authorization": `Bearer ${config.appSecret}` };
    if (json !== null) headers["Content-Type"] = "application/json";
    const startedAt = now();
    try {
      return await fetchImpl(`${upstreamBase}${route.upstreamPath}${search}`, {
        method,
        headers,
        body: json,
      });
    } catch (e) {
      report(route.name, "SFU request failed", { error: e, startedAt });
      return null;
    }
  }

  async function completeNewSession(
    upstream: Response,
    callerId: string,
    roomId: string,
    cors: Record<string, string>,
  ): Promise<Response> {
    const text = await upstream.text();
    const headers: Record<string, string> = { ...responseHeaders(upstream), ...cors };
    let sessionId: unknown;
    if (upstream.ok) {
      try {
        sessionId = (JSON.parse(text) as { sessionId?: unknown }).sessionId;
      } catch {
        sessionId = undefined;
      }
    }
    if (typeof sessionId === "string" && sessionId !== "") {
      const createdAt = now();
      try {
        await store.put(sessionId, { roomId, ownerId: callerId, createdAt });
      } catch {
        throw new StoreError("session store write failed");
      }
      if (config.sessionToken) {
        headers[SESSION_TOKEN_HEADER] = await signSessionToken(
          {
            sessionId,
            roomId,
            ownerId: callerId,
            expiresAt: createdAt / 1000 + (config.sessionToken.ttlSeconds ?? 86400),
          },
          config.sessionToken.secret,
        );
      }
    }
    return new Response(text, { status: upstream.status, headers });
  }
}

/** Only the upstream headers a client needs; everything else (cookies, tracing) is dropped. */
function responseHeaders(upstream: Response): Record<string, string> {
  const headers: Record<string, string> = { "Cache-Control": "no-store" };
  const contentType = upstream.headers.get("Content-Type");
  if (contentType) headers["Content-Type"] = contentType;
  return headers;
}

/** Returns the SFU's status and body unchanged (including 410 `session_error`). */
function passThrough(upstream: Response, cors: Record<string, string>): Response {
  const nullBody = upstream.status === 204 || upstream.status === 304;
  return new Response(nullBody ? null : upstream.body, {
    status: upstream.status,
    headers: { ...responseHeaders(upstream), ...cors },
  });
}
