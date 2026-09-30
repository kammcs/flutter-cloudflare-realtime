import type { Caller } from "../../supabase/functions/_shared/broker-core/mod.ts";

/**
 * Rule 2: is `caller` allowed in `roomId`?
 *
 * APP-SPECIFIC. REPLACE THIS. It fails closed, so the broker rejects every
 * room with 403 until you implement it. Typical implementations:
 * - query your API or database for a membership row (use a service binding,
 *   D1, or `fetch` to your backend with a server-side credential);
 * - check a `rooms` claim in the caller's JWT, if your auth server issues one.
 *
 * Never trust a room list the client sends in its own headers or body.
 */
export function isRoomMember(_caller: Caller, _roomId: string): Promise<boolean> {
  return Promise.resolve(false);
}
