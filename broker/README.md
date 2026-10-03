# Reference brokers

The Cloudflare Realtime SFU API needs your **App Secret**, so `cloudflare_realtime` never calls Cloudflare directly. It calls a small **broker** that you run. The broker authenticates your users, checks room membership, binds sessions to their creators, and forwards allowed calls to Cloudflare. See [docs/design.md §5](../docs/design.md#5-broker-contract) for the contract.

This directory has two reference brokers that share one core:

| | Runtime | Session store | Caller auth |
|---|---|---|---|
| [`cloudflare-worker/`](cloudflare-worker/) | Cloudflare Workers | Durable Objects (one per session) | JWT via `jose` (HS256 secret or JWKS) |
| [`supabase/functions/realtime-broker/`](supabase/functions/realtime-broker/) | Supabase Edge Functions (Deno) | Postgres table (service role only) | Supabase JWT (`auth.getUser`) |

They are **references**, not drop-in products: each has a room-membership stub that **rejects every room** until you implement it.

## Layout

```
broker/
├── supabase/
│   ├── config.toml                          # verify_jwt = false for the function
│   ├── migrations/…_realtime_broker_sessions.sql
│   └── functions/
│       ├── _shared/broker-core/             # the framework-agnostic core (both brokers)
│       └── realtime-broker/                 # Supabase Edge Function
├── cloudflare-worker/                       # Worker + wrangler.toml
└── test/                                    # vitest tests (Node)
```

**Why the core lives under `supabase/functions/_shared/`.** The Supabase CLI only bundles files inside `supabase/functions/` (folders starting with `_` are shared), both for `functions serve` and for the Docker-based deploy. Wrangler's bundler (esbuild) can import from anywhere. So keeping the core there is the one layout that deploys cleanly on both. The core only uses web-standard APIs (`Request`, `Response`, `fetch`, WebCrypto), has no dependencies, and uses `.ts` import specifiers, which Deno, esbuild and TypeScript (`allowImportingTsExtensions`) all accept.

## Wire contract (summary)

- Paths mirror the SFU API under the broker's base URL: `POST sessions/new`, `POST sessions/{id}/tracks/new`, `PUT …/tracks/update`, `PUT …/renegotiate`, `PUT …/tracks/close`, `GET sessions/{id}`, `POST …/datachannels/establish`, `POST …/datachannels/new`, `PUT …/datachannels/update`, `PUT …/datachannels/close`, and `POST generate-ice-servers` (`GET` is accepted too, for partytracks clients).
- Every request carries the app's auth headers and `X-Realtime-Room: <roomId>`.
- `sessions/new` may return `X-Realtime-Session-Token`; the client echoes it on later calls for that session.
- Errors: `401` unauthenticated; `400` for a missing room header or a malformed body; `403` with `{"errorCode":"forbidden","errorDescription":"…"}` when the caller isn't in the room, doesn't own the session, or names a session from another room. Otherwise the SFU's status and body pass through unchanged (including `410` / `session_error`).
- `generate-ice-servers` returns `{"iceServers":[…]}`: Cloudflare TURN credentials when a TURN key is configured, otherwise `stun:stun.cloudflare.com:3478` only. TURN URLs on port 53 are dropped (browsers block that port).

## Security model

The core enforces these rules on every request. Keep them if you write your own broker.

1. **Authenticate the caller** with your app's credential (`authenticate` hook). No credential, no call: `401`.
2. **Authorize the room.** The client names the room in `X-Realtime-Room`; the broker asks your `isRoomMember(caller, roomId)` hook. `403` otherwise. Never trust a room list from the client.
3. **Bind sessions to their creator.** `sessions/new` records `{roomId, ownerId, createdAt}` in the `SessionStore`. Every call on `sessions/{id}` requires that the caller created `{id}` for the same room. With signed tokens enabled, the token proves this instead of a store read.
4. **Restrict pulls to the same room.** The broker parses every JSON body and finds each `sessionId` it names, at any depth (`tracks[]`, `dataChannels[]`, `dataChannel`), on every route. Each one must be a session the broker created **for the caller's room**, or the request is refused with `403`. This covers `tracks/new` pulls, `tracks/update` transceiver reuse, and DataChannel subscriptions. A `remote` entry without a `sessionId` in `tracks/new` or `datachannels/new` is a `400`. The broker forwards its own re-serialization of the parsed body, so duplicate keys can't smuggle a different value past the check, and look-alike keys (`SessionId`) are refused.
5. **Forward only what Cloudflare needs.** Upstream requests carry exactly `Authorization: Bearer <App Secret>` and, with a body, `Content-Type: application/json`. Cookies, the client's `Authorization`, `X-Realtime-*`, forwarding and hop-by-hop headers never reach Cloudflare. Responses keep only `Content-Type` (plus CORS). The core logs nothing itself; its `onError` hook only receives a route name and a sanitized message, never the App Secret, SDP, tokens or headers.

Also:
- **CORS** (Flutter Web): list your web origins. A request with an `Origin` that isn't listed is refused, and without any list every browser request is refused. Native clients send no `Origin` and are unaffected. The broker never uses cookies, so it doesn't send `Access-Control-Allow-Credentials`. `X-Realtime-Session-Token` is exposed to browsers.
- **Session IDs** in paths must be URL-safe (`[A-Za-z0-9_-]`, up to 128 characters). Bodies are limited to 1 MiB.
- **`generate-ice-servers`** also requires authentication and room membership, so TURN credentials only go to your users.

### Signed session tokens: when to use them

Set `SESSION_TOKEN_SECRET` (at least 32 random characters; never reuse the App Secret) to turn them on. `sessions/new` then returns `X-Realtime-Session-Token`, an HMAC-SHA256 over `{sessionId, roomId, ownerId, expiry}`, and every later call on that session must echo it.

The store is still required: rule 4 must look up **other** participants' sessions. Tokens help when:
- your store is remote or slow, since they check ownership of the caller's own session without a store read on each `tracks/*`, `renegotiate` and `datachannels/*` call;
- your store is eventually consistent across regions, and the caller's next request could land where the write isn't visible yet;
- you want defense in depth, so that a leaked session ID alone can't be used to mutate a session.

With the reference stores (Durable Objects, Postgres), both strongly consistent, tokens are optional.

## What your app must implement

1. **Authentication.** The Worker verifies a JWT from your identity provider (`sub` becomes the caller ID). The Supabase function verifies the caller's Supabase access token. Your Flutter app's broker `headers` provider sends that token as `Authorization: Bearer …`.
2. **Room membership.** Replace the stub in `cloudflare-worker/src/room_membership.ts` or `supabase/functions/realtime-broker/room_membership.ts`. It gets the authenticated caller and the room ID and returns whether the caller may join. Fail closed.
3. **Signaling.** The broker doesn't know who is in a room right now; your `Signaling` implementation tells peers each other's `sessionId`s.

## Cloudflare prerequisites

- An **SFU app**: Cloudflare dashboard → Realtime → SFU. You get an **App ID** and an **App Secret**.
- Optional, for clients behind strict NATs or firewalls: a **TURN key**: Realtime → TURN. You get a **TURN key ID** and an **API token**.

## Cloudflare Worker

```sh
cd broker
npm ci
cd cloudflare-worker
# Edit wrangler.toml: REALTIME_APP_ID, TURN_KEY_ID, JWT_ISSUER, JWT_AUDIENCE,
# JWT_JWKS_URL (or use the JWT_SECRET secret), ALLOWED_ORIGINS, BASE_PATH.
npx wrangler secret put REALTIME_APP_SECRET
npx wrangler secret put TURN_KEY_API_TOKEN      # optional
npx wrangler secret put SESSION_TOKEN_SECRET    # optional
npx wrangler secret put JWT_SECRET              # only for HS256
npx wrangler deploy
```

- **Session store:** a Durable Object per session (`RealtimeSessionObject`, SQLite-backed, so it works on the Workers Free plan). An alarm deletes each record after `SESSION_TTL_SECONDS` (default 24 hours). The migration in `wrangler.toml` creates the class on first deploy. **Why not Workers KV:** a peer pulls a new session within seconds, often from another Cloudflare location, and KV can take up to a minute to make a write visible elsewhere. That would cause spurious `403`s on pulls. Durable Objects are strongly consistent.
- **Local development:** put secrets in `cloudflare-worker/.dev.vars` (git-ignored) and run `npx wrangler dev`.
- The broker is served at the Worker's root unless you set `BASE_PATH` (for example `/realtime` when you route `api.example.com/realtime/*` to it). Point the Flutter `BrokerOptions.baseUrl` at the same URL.

## Supabase Edge Function

```sh
cd broker
supabase link --project-ref <your-project-ref>
supabase db push                                   # creates public.realtime_broker_sessions
supabase secrets set REALTIME_APP_ID=<app id> REALTIME_APP_SECRET=<app secret>
supabase secrets set TURN_KEY_ID=<turn key id> TURN_KEY_API_TOKEN=<turn api token>   # optional
supabase secrets set SESSION_TOKEN_SECRET=<32+ random chars>                           # optional
supabase secrets set ALLOWED_ORIGINS=https://app.example.com                           # for Flutter Web
supabase functions deploy realtime-broker --no-verify-jwt
```

Replace the placeholders with your values. Don't paste real secrets into shell history on shared machines; `supabase secrets set --env-file <file>` reads them from a (git-ignored) file.

- **URL:** `https://<project-ref>.supabase.co/functions/v1/realtime-broker`. Use it as the Flutter `BrokerOptions.baseUrl`. The function strips the `/realtime-broker` prefix (override with `BASE_PATH`).
- **JWT verification:** the function verifies the caller's token itself with `auth.getUser`, so the gateway check is off (`verify_jwt = false` in `config.toml`, or `--no-verify-jwt`). CORS preflights carry no token, so the gateway check would block Flutter Web.
- **Session store:** the migration creates `public.realtime_broker_sessions` with RLS enabled, no policies, and no privileges for `anon` or `authenticated`. Only the service role (which the function uses, from the platform-provided `SUPABASE_SERVICE_ROLE_KEY`) can read or write it. Expired rows are ignored; the migration shows an optional `pg_cron` cleanup job.
- **Other environment:** `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY` are provided by the platform. Optional: `SESSION_TTL_SECONDS`, `TURN_TTL_SECONDS`, `EXTRA_ALLOWED_HEADERS`.
- **Local development:** `supabase functions serve realtime-broker --no-verify-jwt --env-file supabase/functions/.env` (the `.env` file is git-ignored).

## Development

```sh
cd broker
npm ci
npm run typecheck   # tsc --noEmit for the core, the Worker and the tests
npm test            # vitest
```

- The tests cover the core with an in-memory store and a mocked upstream `fetch`, plus the Worker's JWT check and store, and the Supabase function's auth and Postgres store through fakes.
- The Deno entry (`supabase/functions/realtime-broker/index.ts`) is kept thin and is **not** type-checked or tested in CI, because CI has no Deno. Everything it wires together is.
- `InMemorySessionStore` is for tests only: serverless runtimes run many isolates, each with its own memory.
