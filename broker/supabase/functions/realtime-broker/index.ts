/**
 * Reference Supabase Edge Function (Deno) broker for cloudflare_realtime.
 *
 * This file is the only Deno-specific part (Deno.serve, Deno.env, the jsr
 * import). The logic lives in ../_shared/broker-core and in the portable
 * modules next to this file. See broker/README.md.
 *
 * Secrets (set with `supabase secrets set`): REALTIME_APP_ID,
 * REALTIME_APP_SECRET, and optionally TURN_KEY_ID, TURN_KEY_API_TOKEN,
 * SESSION_TOKEN_SECRET, ALLOWED_ORIGINS, EXTRA_ALLOWED_HEADERS,
 * SESSION_TTL_SECONDS, TURN_TTL_SECONDS, BASE_PATH.
 * SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided
 * by the platform.
 */

import { createClient } from "jsr:@supabase/supabase-js@2";
import {
  createBrokerHandler,
  formatBrokerError,
  parseAllowedOrigins,
  parseList,
  parsePositiveInt,
} from "../_shared/broker-core/mod.ts";
import { createSupabaseAuthenticator } from "./auth.ts";
import { PostgresSessionStore, SESSION_TABLE, type SessionTable } from "./postgres_store.ts";
import { isRoomMember } from "./room_membership.ts";

function required(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`missing environment variable ${name}`);
  return value;
}

const env = (name: string) => Deno.env.get(name) || undefined;

const clientOptions = { auth: { persistSession: false, autoRefreshToken: false } };
const authClient = createClient(required("SUPABASE_URL"), required("SUPABASE_ANON_KEY"), clientOptions);
const adminClient = createClient(
  required("SUPABASE_URL"),
  required("SUPABASE_SERVICE_ROLE_KEY"),
  clientOptions,
);

const table: SessionTable = {
  insert: (row) => adminClient.from(SESSION_TABLE).insert(row),
  findUnexpired: (sessionId, nowIso) =>
    adminClient
      .from(SESSION_TABLE)
      .select("room_id, owner_id, created_at")
      .eq("session_id", sessionId)
      .gt("expires_at", nowIso)
      .maybeSingle(),
};

const sessionTtlSeconds = parsePositiveInt(env("SESSION_TTL_SECONDS"), 86400);
const allowedOrigins = parseAllowedOrigins(env("ALLOWED_ORIGINS"));
const turnKeyId = env("TURN_KEY_ID");
const turnApiToken = env("TURN_KEY_API_TOKEN");
const sessionTokenSecret = env("SESSION_TOKEN_SECRET");

const handler = createBrokerHandler({
  appId: required("REALTIME_APP_ID"),
  appSecret: required("REALTIME_APP_SECRET"),
  // Supabase routes /functions/v1/<name>/... to the function as /<name>/...
  basePath: env("BASE_PATH") ?? "/realtime-broker",
  authenticate: createSupabaseAuthenticator((jwt) => authClient.auth.getUser(jwt)),
  isRoomMember,
  sessionStore: new PostgresSessionStore(table, { ttlSeconds: sessionTtlSeconds }),
  turn: turnKeyId && turnApiToken
    ? {
      keyId: turnKeyId,
      apiToken: turnApiToken,
      ttlSeconds: parsePositiveInt(env("TURN_TTL_SECONDS"), 86400),
    }
    : undefined,
  sessionToken: sessionTokenSecret ? { secret: sessionTokenSecret, ttlSeconds: sessionTtlSeconds } : undefined,
  cors: allowedOrigins
    ? {
      allowedOrigins,
      // supabase-js style clients also send these.
      extraAllowedHeaders: ["apikey", "x-client-info", ...parseList(env("EXTRA_ALLOWED_HEADERS"))],
    }
    : undefined,
  onError: (info) => console.error(`realtime-broker ${formatBrokerError(info)}`),
});

Deno.serve(handler);
