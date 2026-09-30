/**
 * Example `authenticate` hook: verifies the caller's `Authorization: Bearer
 * <JWT>` with `jose`, against either a shared HS256 secret or a JWKS URL
 * (RS256/ES256, for example from your identity provider). Issuer and audience
 * are always checked. The caller ID is the token's `sub`.
 *
 * Replace it if your app authenticates differently; keep it fail-closed.
 */

import { createRemoteJWKSet, jwtVerify, type JWTVerifyGetKey } from "jose";
import type { Caller } from "../../supabase/functions/_shared/broker-core/mod.ts";

/** Options for {@link createJwtAuthenticator}. Set exactly one of `jwksUrl` and `secret`. */
export interface JwtAuthOptions {
  /** Expected `iss`. Required. */
  readonly issuer: string;
  /** Expected `aud`. Required. */
  readonly audience: string;
  /** JWKS endpoint for asymmetric tokens. */
  readonly jwksUrl?: string;
  /** Shared HS256 secret. */
  readonly secret?: string;
  /** Allowed algorithms. Defaults to `["HS256"]` with `secret`, `["RS256", "ES256"]` with `jwksUrl`. */
  readonly algorithms?: readonly string[];
  /** Allowed clock skew in seconds. Defaults to 5. */
  readonly clockToleranceSeconds?: number;
  /** Clock override, for tests. */
  readonly currentDate?: () => Date;
}

const jwksCache = new Map<string, JWTVerifyGetKey>();

function remoteJwks(url: string): JWTVerifyGetKey {
  let jwks = jwksCache.get(url);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(url));
    jwksCache.set(url, jwks);
  }
  return jwks;
}

/** Creates an `authenticate` hook that returns `null` for any missing or invalid token. */
export function createJwtAuthenticator(options: JwtAuthOptions): (request: Request) => Promise<Caller | null> {
  if (!options.issuer || !options.audience) {
    throw new Error("JWT issuer and audience are required");
  }
  if (Boolean(options.jwksUrl) === Boolean(options.secret)) {
    throw new Error("set exactly one of JWT_JWKS_URL and JWT_SECRET");
  }
  const secretKey = options.secret ? new TextEncoder().encode(options.secret) : undefined;
  const algorithms = [...(options.algorithms ?? (secretKey ? ["HS256"] : ["RS256", "ES256"]))];

  return async (request) => {
    const header = request.headers.get("Authorization");
    const match = header ? /^Bearer\s+(\S+)$/i.exec(header) : null;
    if (!match) return null;
    const token = match[1]!;
    const verifyOptions = {
      issuer: options.issuer,
      audience: options.audience,
      algorithms,
      clockTolerance: options.clockToleranceSeconds ?? 5,
      ...(options.currentDate ? { currentDate: options.currentDate() } : {}),
    };
    try {
      const { payload } = secretKey
        ? await jwtVerify(token, secretKey, verifyOptions)
        : await jwtVerify(token, remoteJwks(options.jwksUrl!), verifyOptions);
      return typeof payload.sub === "string" && payload.sub !== "" ? { id: payload.sub } : null;
    } catch {
      return null;
    }
  };
}
