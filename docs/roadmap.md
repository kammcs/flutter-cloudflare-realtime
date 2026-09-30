# Roadmap

Effort is in developer-weeks for the whole package. The total is **about 10–16 weeks** to a production-ready 1.0.

| # | Milestone | Work | Est. |
|---|---|---|---|
| M0 | Repo and CI (**done**) | Scaffold, CI (analyze, format, test, gitleaks), example app shell with the in-memory `Signaling` | S |
| M1 | Broker (**done**) | The broker contract ([design.md §5](design.md#5-broker-contract)), with its security rules. A reference **Cloudflare Worker** and a **Supabase Edge Function** in `broker/` (shared core, tests and CI; see [broker/README.md](../broker/README.md)). A `BrokerClient` in Dart (typed models, `HttpBrokerClient`, error mapping). ICE servers from `generate-ice-servers` | 1–2 wk |
| M2 | Core session (**done**, pending a real-broker run) | `SfuSession`: push, pull, update, close, renegotiation, a serialized op queue with batching, per-track errors. Port from partytracks. **Status:** implemented with unit tests against a fake broker and a fake peer connection; session failures are surfaced and publications/subscriptions can move to a new session (the hooks M5 needs). The loopback integration test (`example/integration_test/`) still has to be run against a real broker | 3–4 wk |
| M3 | Rooms (**done**, pending a real-broker run) | `Room` on top of the `Signaling` interface (the interface and `InMemorySignaling` landed with M0), participant diffing, and pull-on-subscribe. **Status:** `CloudflareRealtime.join`, `Room` (participants, events, connection state, `leave`), `LocalParticipant` (camera/microphone/screen publish, mute via `TrackInfo.muted`, the `TrackInfo.simulcast` hint), `RemoteParticipant`/`RemoteTrackPublication` (pull on subscribe or lease, layers, following session changes, pull retries), `room.data`, and `ParticipantVideoView` with a layer-reporter hook ([design.md §4.3](design.md#43-room)); unit and widget tests on the fakes, including a four-participant scenario. The example app has a call screen with in-memory or dev-server signaling. Still to do: a multi-device run through the dev server | 1 wk |
| M4 | Simulcast and active speaker (**partial**) | Publish a/b/c encodings, set `preferredRid` by tile size, `ridNotAvailable` fallback, active speaker from `getStats`. **Landed**, unit-tested: the layer policy with hysteresis, the per-subscription debouncer, the `SimulcastLayerReporter` widget, the stats audio-level source, and the active-speaker detector with its poller ([design.md §6.1](design.md#61-layer-selection), [§7](design.md#7-active-speaker)). **Still to do:** publish the encodings (with M2), wire it all into the Room, a level source for the muted mic, and check the encoder layer limit on devices | 1–2 wk |
| M5 | Reconnection (**partial**) | Replace the session on failure, 410 handling, network changes, mobile background/foreground, backoff. **Landed**, unit-tested: `Backoff` (full jitter) and the `ReconnectTrigger` decision logic ([design.md §8](design.md#8-reconnection)). **Still to do:** the re-session procedure, the network-change and lifecycle event sources, and the `reconnecting`/`reconnected` states | 2–3 wk |
| M6 | Screen share | Desktop picker (`desktopCapturer`) and web `getDisplayMedia` capture (**landed early**, with the media layer: [design.md §10](design.md#10-screen-share-by-platform)). Publishing the share landed with M3 (`LocalParticipant.publishScreen`, one encoding by default). Still to do: Android MediaProjection, iOS Broadcast Upload Extension, VP8 by default on Windows, device QA | 3–4 wk (includes QA) |
| M7 | DataChannels (**done** at the session level, pending a real-broker run) | Reliable and unreliable profiles, `canReply`, sender `sessionId` exposed. **Status:** `SfuSession.publishDataChannel`/`subscribeDataChannel` with lazy `datachannels/establish`, batching, per-channel errors, backpressure, and `republishDataChannel`/`resubscribeDataChannel` for M5 ([design.md §9](design.md#9-datachannels)); unit-tested against the fakes. `room.data` landed with M3. Still to do: running `example/integration_test/datachannel_echo_test.dart` against a real broker, and the web `maxRetransmits: 0` gap in `flutter_webrtc` | S–M |
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
  - participant diffing and pull-on-subscribe (**done**);
  - layer selection (**done**);
  - backoff and the reconnect trigger (**done**);
  - active-speaker detection (**done**).
- **Integration:** use a real SFU app with the example app and a local broker. The DEV ONLY [`tools/dev-server/`](../tools/dev-server/README.md) provides the broker and WebSocket signaling for multi-device runs, including the week-6 checkpoint calls. Keep the credentials in the environment only (see [CLAUDE.md](../CLAUDE.md)).
- **Device matrix before 1.0:** Windows, macOS, Android, iOS, and Web (Chrome, Safari, Firefox).
