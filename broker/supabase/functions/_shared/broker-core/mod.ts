/**
 * Framework-agnostic core of the cloudflare_realtime reference brokers.
 *
 * It only uses web-standard APIs and has no dependencies, so the Cloudflare
 * Worker (bundled by wrangler) and the Supabase Edge Function (Deno) import
 * these same files. See broker/README.md.
 */

export { createBrokerHandler, ROOM_HEADER, SESSION_TOKEN_HEADER } from "./handler.ts";
export type { BrokerHandler } from "./handler.ts";
export { errorCause, formatBrokerError } from "./diagnostics.ts";
export { InMemorySessionStore } from "./memory_store.ts";
export { STUN_ONLY } from "./ice.ts";
export type { IceServer, IceServersResponse } from "./ice.ts";
export {
  MIN_SESSION_TOKEN_SECRET_LENGTH,
  signSessionToken,
  verifySessionToken,
} from "./session_token.ts";
export type { SessionTokenClaims } from "./session_token.ts";
export type {
  BrokerConfig,
  BrokerErrorInfo,
  Caller,
  CorsConfig,
  DataChannelEntry,
  DataChannelRouteName,
  SessionRecord,
  SessionStore,
  SessionTokenConfig,
  TurnConfig,
} from "./types.ts";
export { parseAllowedOrigins, parseList, parsePositiveInt } from "./env.ts";
