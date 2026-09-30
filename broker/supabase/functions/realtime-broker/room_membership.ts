import type { Caller } from "../_shared/broker-core/mod.ts";

/**
 * Rule 2: is `caller` allowed in `roomId`?
 *
 * APP-SPECIFIC. REPLACE THIS. It fails closed, so the broker rejects every
 * room with 403 until you implement it. A typical implementation queries
 * your own membership table with the service-role client, for example:
 *
 *     const { data, error } = await admin
 *       .from("room_members")
 *       .select("room_id")
 *       .eq("room_id", roomId)
 *       .eq("user_id", caller.id)
 *       .maybeSingle();
 *     return !error && data !== null;
 *
 * Never trust a room list the client sends in its own headers or body.
 */
export function isRoomMember(_caller: Caller, _roomId: string): Promise<boolean> {
  return Promise.resolve(false);
}
