/**
 * Reference Cloudflare Worker broker for cloudflare_realtime.
 *
 * Configure it in wrangler.toml (non-secret vars) and with
 * `wrangler secret put` (secrets). See broker/README.md.
 */

import {
  type BrokerHandler,
  createBrokerHandler,
  parseAllowedOrigins,
  parseList,
  parsePositiveInt,
} from "../../supabase/functions/_shared/broker-core/mod.ts";
import { createJwtAuthenticator } from "./auth.ts";
import { DurableObjectSessionStore, type SessionObjectStub } from "./durable_object_store.ts";
import { isRoomMember } from "./room_membership.ts";
import type { RealtimeSessionObject } from "./session_object.ts";

export { RealtimeSessionObject } from "./session_object.ts";

/** Bindings and variables. Secrets are marked; set them with `wrangler secret put`. */
export interface Env {
  REALTIME_SESSIONS: DurableObjectNamespace<RealtimeSessionObject>;
  REALTIME_APP_ID: string;
  /** Secret. */
  REALTIME_APP_SECRET: string;
  TURN_KEY_ID?: string;
  /** Secret. */
  TURN_KEY_API_TOKEN?: string;
  TURN_TTL_SECONDS?: string;
  /** Secret. Enables signed session tokens when set. */
  SESSION_TOKEN_SECRET?: string;
  SESSION_TTL_SECONDS?: string;
  BASE_PATH?: string;
  ALLOWED_ORIGINS?: string;
  EXTRA_ALLOWED_HEADERS?: string;
  JWT_ISSUER: string;
  JWT_AUDIENCE: string;
  JWT_JWKS_URL?: string;
  /** Secret (only for HS256). */
  JWT_SECRET?: string;
}

function buildHandler(env: Env): BrokerHandler {
  const sessionTtlSeconds = parsePositiveInt(env.SESSION_TTL_SECONDS, 86400);
  const allowedOrigins = parseAllowedOrigins(env.ALLOWED_ORIGINS);
  return createBrokerHandler({
    appId: env.REALTIME_APP_ID,
    appSecret: env.REALTIME_APP_SECRET,
    basePath: env.BASE_PATH,
    authenticate: createJwtAuthenticator({
      issuer: env.JWT_ISSUER,
      audience: env.JWT_AUDIENCE,
      jwksUrl: env.JWT_JWKS_URL || undefined,
      secret: env.JWT_SECRET || undefined,
    }),
    isRoomMember,
    sessionStore: new DurableObjectSessionStore(
      (sessionId): SessionObjectStub => env.REALTIME_SESSIONS.get(env.REALTIME_SESSIONS.idFromName(sessionId)),
      { ttlSeconds: sessionTtlSeconds },
    ),
    turn: env.TURN_KEY_ID && env.TURN_KEY_API_TOKEN
      ? {
        keyId: env.TURN_KEY_ID,
        apiToken: env.TURN_KEY_API_TOKEN,
        ttlSeconds: parsePositiveInt(env.TURN_TTL_SECONDS, 86400),
      }
      : undefined,
    sessionToken: env.SESSION_TOKEN_SECRET
      ? { secret: env.SESSION_TOKEN_SECRET, ttlSeconds: sessionTtlSeconds }
      : undefined,
    cors: allowedOrigins
      ? { allowedOrigins, extraAllowedHeaders: parseList(env.EXTRA_ALLOWED_HEADERS) }
      : undefined,
    onError: ({ route, message }) => console.error(`realtime-broker ${route}: ${message}`),
  });
}

let cached: { env: Env; handler: BrokerHandler } | undefined;

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    if (cached?.env !== env) cached = { env, handler: buildHandler(env) };
    return cached.handler(request);
  },
} satisfies ExportedHandler<Env>;
