/**
 * Signed session tokens (`X-Realtime-Session-Token`).
 *
 * A token binds an SFU session to the room and the caller that created it:
 *
 *     base64url(JSON {v, sid, room, sub, exp}) "." base64url(HMAC-SHA256)
 *
 * The HMAC covers the first segment, which encodes the session ID, room ID,
 * owner ID and expiry (seconds since the epoch).
 *
 * When to use it: the broker always needs a {@link SessionStore} for rule 4
 * (a pull names *another* participant's session, whose room only the store
 * knows). Tokens are an optional extra for rule 3:
 * - They let the broker check ownership of the caller's own session without a
 *   store read on every `tracks/*`, `renegotiate` and `datachannels/*` call,
 *   which saves latency when the store is remote.
 * - They keep ownership checks working when the store is eventually
 *   consistent across regions and the caller's next request lands somewhere
 *   the write isn't visible yet.
 * - They add defense in depth: a leaked session ID alone is not enough to
 *   mutate a session, even if the store is misconfigured.
 *
 * If your store is strongly consistent and close to the broker (as the
 * reference Durable Object and Postgres stores are), you can leave tokens off.
 */

const encoder = new TextEncoder();
const decoder = new TextDecoder();

/** The claims carried by a session token. */
export interface SessionTokenClaims {
  readonly sessionId: string;
  readonly roomId: string;
  readonly ownerId: string;
  /** Expiry, in seconds since the Unix epoch. */
  readonly expiresAt: number;
}

interface WirePayload {
  v: 1;
  sid: string;
  room: string;
  sub: string;
  exp: number;
}

/** The minimum secret length, in characters. */
export const MIN_SESSION_TOKEN_SECRET_LENGTH = 32;

const keyCache = new Map<string, Promise<CryptoKey>>();

function hmacKey(secret: string): Promise<CryptoKey> {
  if (secret.length < MIN_SESSION_TOKEN_SECRET_LENGTH) {
    throw new Error(
      `session token secret must be at least ${MIN_SESSION_TOKEN_SECRET_LENGTH} characters`,
    );
  }
  let key = keyCache.get(secret);
  if (!key) {
    key = crypto.subtle.importKey(
      "raw",
      encoder.encode(secret),
      { name: "HMAC", hash: "SHA-256" },
      false,
      ["sign", "verify"],
    );
    keyCache.set(secret, key);
  }
  return key;
}

function toBase64Url(bytes: Uint8Array): string {
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

// The return type is inferred on purpose: it is `Uint8Array<ArrayBuffer>` on
// TypeScript 5.7+ (as WebCrypto requires) and plain `Uint8Array` on older ones.
function fromBase64Url(text: string) {
  if (!/^[A-Za-z0-9_-]*$/.test(text)) return null;
  const padded = text.replace(/-/g, "+").replace(/_/g, "/") +
    "===".slice((text.length + 3) % 4);
  try {
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
  } catch {
    return null;
  }
}

/** Signs a token for `claims` with `secret`. */
export async function signSessionToken(
  claims: SessionTokenClaims,
  secret: string,
): Promise<string> {
  const payload: WirePayload = {
    v: 1,
    sid: claims.sessionId,
    room: claims.roomId,
    sub: claims.ownerId,
    exp: Math.floor(claims.expiresAt),
  };
  const body = toBase64Url(encoder.encode(JSON.stringify(payload)));
  const signature = await crypto.subtle.sign(
    "HMAC",
    await hmacKey(secret),
    encoder.encode(body),
  );
  return `${body}.${toBase64Url(new Uint8Array(signature))}`;
}

/**
 * Verifies `token` and returns its claims, or `null` if it is malformed,
 * tampered with, or expired at `nowSeconds`. The signature check is
 * constant-time (WebCrypto `verify`).
 */
export async function verifySessionToken(
  token: string,
  secret: string,
  nowSeconds: number,
): Promise<SessionTokenClaims | null> {
  if (token.length > 4096) return null;
  const parts = token.split(".");
  if (parts.length !== 2) return null;
  const [body, sig] = parts as [string, string];
  const signature = fromBase64Url(sig);
  const bodyBytes = fromBase64Url(body);
  if (!signature || !bodyBytes) return null;

  const valid = await crypto.subtle.verify(
    "HMAC",
    await hmacKey(secret),
    signature,
    encoder.encode(body),
  );
  if (!valid) return null;

  let payload: unknown;
  try {
    payload = JSON.parse(decoder.decode(bodyBytes));
  } catch {
    return null;
  }
  if (typeof payload !== "object" || payload === null) return null;
  const p = payload as Partial<WirePayload>;
  if (
    p.v !== 1 ||
    typeof p.sid !== "string" ||
    typeof p.room !== "string" ||
    typeof p.sub !== "string" ||
    typeof p.exp !== "number" ||
    !Number.isFinite(p.exp)
  ) {
    return null;
  }
  if (p.exp <= nowSeconds) return null;
  return {
    sessionId: p.sid,
    roomId: p.room,
    ownerId: p.sub,
    expiresAt: p.exp,
  };
}
