/**
 * Public types for the framework-agnostic broker core.
 *
 * The core only uses web-standard APIs (`Request`, `Response`, `fetch`,
 * WebCrypto), so it runs unchanged on Cloudflare Workers, Deno (Supabase Edge
 * Functions) and Node 18+.
 */

/** The authenticated caller, as returned by {@link BrokerConfig.authenticate}. */
export interface Caller {
  /**
   * A stable, unique user ID from the app's own auth system (for example a
   * JWT `sub`). Sessions are bound to it.
   */
  readonly id: string;
}

/** What the broker remembers about each SFU session it created. */
export interface SessionRecord {
  /** The room the session was created for (the `X-Realtime-Room` header). */
  readonly roomId: string;
  /** {@link Caller.id} of the caller that created the session. */
  readonly ownerId: string;
  /** Creation time, in milliseconds since the Unix epoch. */
  readonly createdAt: number;
}

/**
 * Server-side map of SFU session ID to {@link SessionRecord}.
 *
 * It is required: rule 4 (same-room pulls) must look up the room of a session
 * that belongs to *another* participant, and only the broker knows it. It also
 * provides rule 3 (session binding) when signed session tokens are off.
 *
 * Implementations should expire records (the reference stores use a TTL) and
 * must be readable from every broker instance soon after a write: a peer
 * usually pulls a new session within seconds of its creation.
 */
export interface SessionStore {
  put(sessionId: string, record: SessionRecord): Promise<void>;
  /** Returns the record, or `null` if it is unknown or expired. */
  get(sessionId: string): Promise<SessionRecord | null>;
}

/** Cloudflare TURN key settings. */
export interface TurnConfig {
  /** The TURN key ID (not secret). */
  readonly keyId: string;
  /** The TURN key's API token (secret). */
  readonly apiToken: string;
  /** Credential lifetime in seconds. Defaults to 86400 (24 hours). */
  readonly ttlSeconds?: number;
}

/**
 * Settings for the optional signed `X-Realtime-Session-Token`.
 *
 * When set, `sessions/new` returns a token and every later call on that
 * session must echo it. See `session_token.ts` for when to use it.
 */
export interface SessionTokenConfig {
  /**
   * HMAC-SHA256 key, at least 32 characters. Use a dedicated random secret;
   * never reuse the Cloudflare App Secret.
   */
  readonly secret: string;
  /** Token lifetime in seconds. Defaults to 86400 (24 hours). */
  readonly ttlSeconds?: number;
}

/** CORS settings, needed for Flutter Web clients. */
export interface CorsConfig {
  /**
   * Exact origins (scheme://host[:port]) allowed to call the broker, or `"*"`
   * for any origin. Requests that carry an `Origin` header that isn't listed
   * are rejected with 403. Native clients send no `Origin` and are unaffected.
   *
   * `"*"` is safe from a CSRF point of view because the broker never uses
   * cookies, but prefer an explicit list.
   */
  readonly allowedOrigins: "*" | readonly string[];
  /**
   * Request headers the browser may send, in addition to the defaults
   * (`authorization`, `content-type`, `x-realtime-room`,
   * `x-realtime-session-token`). Add any custom auth headers your app's
   * `headers` provider sets.
   */
  readonly extraAllowedHeaders?: readonly string[];
  /** Preflight cache lifetime in seconds. Defaults to 600. */
  readonly maxAgeSeconds?: number;
}

/** A sanitized diagnostic event. It never contains secrets, SDP, tokens or headers. */
export interface BrokerErrorInfo {
  /** The matched route name, for example `tracks/new`, or `unknown`. */
  readonly route: string;
  /** A short, sanitized description. */
  readonly message: string;
  /**
   * For a failed upstream call: the underlying error's `code` or `name`
   * chain, for example `TypeError: UND_ERR_CONNECT_TIMEOUT` or
   * `TypeError: ENOTFOUND`. Never the error's message (see `errorCause`).
   */
  readonly cause?: string;
  /** For a failed upstream call: how long it ran before failing, in milliseconds. */
  readonly elapsedMs?: number;
}

/** The broker routes that act on DataChannels; see {@link BrokerConfig.authorizeDataChannels}. */
export type DataChannelRouteName =
  | "datachannels/establish"
  | "datachannels/new"
  | "datachannels/update"
  | "datachannels/close";

/**
 * One DataChannel named in a `datachannels/*` request body, as the broker
 * parsed it: an entry of `dataChannels[]`, or the `dataChannel` object of
 * `datachannels/establish`. Only the fields below are copied; a field the
 * client didn't send is absent.
 */
export interface DataChannelEntry {
  /** `local` publishes the channel from the caller's session; `remote` subscribes to it. */
  readonly location?: "local" | "remote";
  /** The channel's name. Absent in `datachannels/close`, which names channels by `id`. */
  readonly dataChannelName?: string;
  /** For `remote` entries: the publisher's session, already checked to be in the caller's room (rule 4). */
  readonly sessionId?: string;
  /** For `remote` entries: whether the subscriber may send back to the publisher. */
  readonly canReply?: boolean;
  /** The channel's ID on the caller's session (`datachannels/close`). */
  readonly id?: number;
}

/** Configuration for {@link createBrokerHandler}. */
export interface BrokerConfig<C extends Caller = Caller> {
  /** Cloudflare Realtime SFU App ID. */
  readonly appId: string;
  /** Cloudflare Realtime SFU App Secret. Server-side only; never logged. */
  readonly appSecret: string;

  /**
   * Rule 1: authenticate the caller from the incoming request (typically its
   * `Authorization` header). Return `null` to reject with 401. Don't throw for
   * bad credentials; a thrown error becomes a 500.
   */
  authenticate(request: Request): Promise<C | null> | C | null;

  /**
   * Rule 2: whether `caller` may join `roomId`. App-specific. Return `false`
   * (fail closed) when unsure.
   */
  isRoomMember(caller: C, roomId: string): Promise<boolean> | boolean;

  /** The session registry (rules 3 and 4). */
  readonly sessionStore: SessionStore;

  /**
   * Optional, app-specific: whether `caller` may make this DataChannel
   * request. Unset by default, which allows every DataChannel request that
   * passes rules 1 to 4.
   *
   * The SFU forwards a published channel to every subscriber that names it,
   * and lets any publisher use any name. Use this hook when your app reserves
   * channel names for certain participants (for example a channel only two
   * users may publish or subscribe to).
   *
   * It runs on every request to a {@link DataChannelRouteName} route, after
   * rules 1 to 4 have passed (the caller is authenticated and in `roomId`, it
   * owns `sessionId`, the session in the path, and every `sessionId` in the
   * body is in `roomId`), and just before the request is forwarded.
   * `entries` are parsed from the same JSON value the broker forwards, so
   * what the hook approves is exactly what Cloudflare receives; they are
   * frozen copies. A request without a body gets no entries.
   *
   * Return `true` to forward the request. Anything else refuses it with
   * `403 forbidden`, and a thrown error becomes `500 internal_error` (the
   * error's text is never returned or reported). Either way nothing reaches
   * the SFU. The safest rules decide on `dataChannelName` whatever the
   * `location`: a name reserved for publishing is reserved for subscribing too.
   */
  readonly authorizeDataChannels?: (
    caller: C,
    roomId: string,
    sessionId: string,
    route: DataChannelRouteName,
    entries: readonly DataChannelEntry[],
  ) => Promise<boolean> | boolean;

  /**
   * Path prefix that the broker is mounted under, without a trailing slash,
   * for example `/realtime`. Defaults to `""` (routes at the root).
   */
  readonly basePath?: string;

  /** TURN settings. Without them, `generate-ice-servers` returns STUN only. */
  readonly turn?: TurnConfig;

  /** Enables the signed `X-Realtime-Session-Token`. Off by default. */
  readonly sessionToken?: SessionTokenConfig;

  /** CORS settings. Without them, any request that has an `Origin` header is rejected. */
  readonly cors?: CorsConfig;

  /** Defaults to `https://rtc.live.cloudflare.com/v1`. */
  readonly apiBaseUrl?: string;

  /** Maximum request body size in bytes. Defaults to 1 MiB. */
  readonly maxBodyBytes?: number;

  /** The `fetch` used for upstream calls. Defaults to the global `fetch`. */
  readonly fetch?: typeof fetch;

  /** Clock in milliseconds since the epoch. Defaults to `Date.now`. For tests. */
  readonly now?: () => number;

  /** Receives sanitized diagnostics (upstream failures, store errors). */
  readonly onError?: (info: BrokerErrorInfo) => void;
}
