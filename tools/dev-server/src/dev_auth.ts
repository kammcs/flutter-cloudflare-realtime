/**
 * DEV ONLY authentication: one shared bearer token for everybody, and the
 * caller names itself in `X-Dev-User`. Anyone with the token can act as any
 * user. Never use this outside a developer's own machine and network.
 */

import { randomBytes, timingSafeEqual } from "node:crypto";
import type { IncomingMessage } from "node:http";
import type { Caller } from "../../../broker/supabase/functions/_shared/broker-core/mod.ts";

/** Request header that names the caller. */
export const DEV_USER_HEADER = "X-Dev-User";

/** Minimum length of a dev token supplied through the environment. */
export const MIN_DEV_TOKEN_LENGTH = 16;

const MAX_USER_LENGTH = 128;

/** Generates a random, URL-safe dev token. */
export function generateDevToken(): string {
  return randomBytes(24).toString("base64url");
}

/** Constant-time comparison of a presented token with the expected one. */
export function tokenMatches(presented: string | null | undefined, expected: string): boolean {
  if (typeof presented !== "string") return false;
  const a = Buffer.from(presented);
  const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

/** Extracts the token from an `Authorization: Bearer <token>` value. */
export function bearerToken(header: string | null | undefined): string | null {
  const match = header ? /^Bearer\s+(\S+)$/i.exec(header) : null;
  return match ? match[1]! : null;
}

/** Whether a user name is acceptable: printable ASCII, no leading or trailing spaces. */
export function isValidDevUser(user: string | null): user is string {
  return user !== null && user.length > 0 && user.length <= MAX_USER_LENGTH && /^[\x21-\x7e]([\x20-\x7e]*[\x21-\x7e])?$/.test(user);
}

/**
 * The broker's `authenticate` hook: `Authorization: Bearer <token>` must
 * match, and `X-Dev-User` becomes the caller ID.
 */
export function createDevAuthenticator(token: string): (request: Request) => Caller | null {
  return (request) => {
    if (!tokenMatches(bearerToken(request.headers.get("Authorization")), token)) return null;
    const user = request.headers.get(DEV_USER_HEADER);
    return isValidDevUser(user) ? { id: user } : null;
  };
}

/**
 * Authorizes a signaling WebSocket upgrade: `?token=<token>` (browsers can't
 * set headers on a WebSocket) or `Authorization: Bearer <token>`.
 */
export function createUpgradeAuthorizer(token: string): (request: IncomingMessage) => boolean {
  return (request) => {
    const url = new URL(request.url ?? "/", "http://localhost");
    const presented = url.searchParams.get("token") ?? bearerToken(request.headers.authorization);
    return tokenMatches(presented, token);
  };
}
