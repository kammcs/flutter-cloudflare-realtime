import type { BrokerConfig, Caller } from "../_shared/broker-core/mod.ts";

/**
 * Optional: your app's own rules for `datachannels/*` requests
 * (`BrokerConfig.authorizeDataChannels`).
 *
 * APP-SPECIFIC, OPTIONAL. Unset by default, which allows every DataChannel
 * request that passes the broker's rules 1 to 4. The SFU forwards a published
 * channel to every subscriber that names it, so set this when your app
 * reserves channel names for certain participants. It runs after the caller
 * is authenticated, is in the room, owns the session, and every session in
 * the body is in the room. Return `true` to forward; anything else is a 403,
 * and a thrown error a 500. See broker/README.md for an example.
 */
export const authorizeDataChannels: BrokerConfig<Caller>["authorizeDataChannels"] = undefined;
