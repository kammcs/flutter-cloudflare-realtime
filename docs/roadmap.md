# Roadmap

Effort is in developer-weeks for the whole package. The total is **about 10–16 weeks** to a production-ready 1.0.

| # | Milestone | Work | Est. |
|---|---|---|---|
| M0 | Repo and CI (**done**) | Scaffold, CI (analyze, format, test, gitleaks), example app shell with the in-memory `Signaling` | S |
| M1 | Broker | The broker contract ([design.md §5](design.md#5-broker-contract)), with its security rules. A reference **Cloudflare Worker** and a **Supabase Edge Function** in `broker/`. A `BrokerClient` in Dart. ICE servers from `generate-ice-servers` | 1–2 wk |
| M2 | Core session | `SfuSession`: push, pull, update, close, renegotiation, a serialized op queue with batching, per-track errors. Port from partytracks | 3–4 wk |
| M3 | Rooms | `Room` on top of the `Signaling` interface (the interface and `InMemorySignaling` landed with M0), participant diffing, and pull-on-subscribe | 1 wk |
| M4 | Simulcast and active speaker | Publish a/b/c encodings, set `preferredRid` by tile size, `ridNotAvailable` fallback, active speaker from `getStats` | 1–2 wk |
| M5 | Reconnection | Replace the session on failure, 410 handling, network changes, mobile background/foreground, backoff | 2–3 wk |
| M6 | Screen share | Desktop picker (`desktopCapturer`) and web `getDisplayMedia` capture (**landed early**, with the media layer: [design.md §10](design.md#10-screen-share-by-platform)). Still to do: Android MediaProjection, iOS Broadcast Upload Extension, publishing the share, VP8 by default on Windows, device QA | 3–4 wk (includes QA) |
| M7 | DataChannels | Reliable and unreliable profiles, `canReply`, sender `sessionId` exposed | S–M |
| M8 | Publish to pub.dev | API review, dartdoc, README setup guides (iOS extension, Android FGS, broker), example app, remove `publish_to: none`, widen the SDK constraint, 0.1.0 | M |

M7 can run alongside M4–M6. The first consumer's remote-control feature needs it.

## Consumer checkpoint (week 6)

**At week 6 of this work**, the first consumer (buildIt.Social) makes a go/no-go call. It continues on this package only if all three of these hold:

1. **Calls work:** a 1:1 **and** a 4-person call on **Windows, macOS and Android**.
2. **Simulcast layer switching** works.
3. **Recovery:** a call recovers from a network drop.

If any fails, that app switches to LiveKit behind its own `VideoProvider` interface, and this package continues as a side project.

**So prioritize M1–M4 plus a basic M5 and a desktop-only M6 path over polish.** The example app should be able to demonstrate all three criteria.

## Testing

- **Unit tests:**
  - the op queue and batching, against a fake `BrokerClient`;
  - participant diffing;
  - layer selection;
  - backoff.
- **Integration:** use a real SFU app with the example app and a local broker. Keep the credentials in the environment only (see [CLAUDE.md](../CLAUDE.md)).
- **Device matrix before 1.0:** Windows, macOS, Android, iOS, and Web (Chrome, Safari, Firefox).
