# Roadmap

Effort is in developer-weeks for the whole package. The total is **about 10–16 weeks** to a production-ready 1.0.

| # | Milestone | Work | Est. |
|---|---|---|---|
| M0 | Repo and CI (**done**) | Scaffold, CI (analyze, format, test, gitleaks), example app shell with the in-memory `Signaling` | S |
| M1 | Broker (**done**) | The broker contract ([design.md §5](design.md#5-broker-contract)), with its security rules. A reference **Cloudflare Worker** and a **Supabase Edge Function** in `broker/` (shared core, tests and CI; see [broker/README.md](../broker/README.md)). A `BrokerClient` in Dart (typed models, `HttpBrokerClient`, error mapping). ICE servers from `generate-ice-servers` | 1–2 wk |
| M2 | Core session (**done**, verified on the real SFU: Windows, Android, macOS, iOS) | `SfuSession`: push, pull, update, close, renegotiation, a serialized op queue with batching, per-track errors. Port from partytracks. **Status:** implemented with unit tests against a fake broker and a fake peer connection; session failures are surfaced and publications/subscriptions can move to a new session (the hooks M5 needs). The loopback integration test (`example/integration_test/`) still has to be run against a real broker | 3–4 wk |
| M3 | Rooms (**done**, verified on the real SFU: Windows ↔ Android, Windows ↔ macOS, Android ↔ macOS and iOS ↔ macOS cross-device) | `Room` on top of the `Signaling` interface (the interface and `InMemorySignaling` landed with M0), participant diffing, and pull-on-subscribe. **Status:** `CloudflareRealtime.join`, `Room` (participants, events, connection state, `leave`), `LocalParticipant` (camera/microphone/screen publish, mute via `TrackInfo.muted`, the `TrackInfo.simulcast` hint), `RemoteParticipant`/`RemoteTrackPublication` (pull on subscribe or lease, layers, following session changes, pull retries), `room.data`, and `ParticipantVideoView` with a layer-reporter hook ([design.md §4.3](design.md#43-room)); unit and widget tests on the fakes, including a four-participant scenario. The example app has a call screen with in-memory or dev-server signaling. Still to do: a multi-device run through the dev server | 1 wk |
| M4 | Simulcast and active speaker (**done**; layer switching verified Windows ↔ Android, Windows ↔ macOS, Android ↔ macOS and iOS ↔ macOS on the real SFU; active speaker pending a device check) | Publish a/b/c encodings, set `preferredRid` by tile size, `ridNotAvailable` fallback, active speaker from `getStats`. **Status:** the encodings are published (M2/M3); the Room owns the layer controller (`Room.layerReporter`, reported to by `ParticipantVideoView` by default), with ladders from `TrackInfo.simulcast`, hidden tiles dropping to the lowest layer and released after a linger, a lease grace period, and a manual `setPreferredLayer` override; `SfuSession.getStats()` feeds `Room.activeSpeakers`/`dominantSpeaker` and per-participant `isSpeaking`/`audioLevel` ([design.md §6.1](design.md#61-layer-selection), [§7](design.md#7-active-speaker)); unit and widget tests on the fakes. The example call screen demonstrates layer switching (stage/gallery layouts, a rid/resolution overlay, a layer menu) and speaking highlights. **Still to do:** "speaking while muted" (unsupported with `flutter_webrtc` 1.6: no level for a track without a sender), and checking the encoder layer limit and layer switching on devices | 1–2 wk |
| M5 | Reconnection (**done**, verified on the real SFU: Windows, Android, macOS, iOS; real network drop pending) | Replace the session on failure, 410 handling, network changes, mobile background/foreground, backoff. **Status:** the Room re-sessions by itself ([design.md §8](design.md#8-reconnection)): `ReconnectTrigger` fed by the session's state and failures (410 included), an injectable `NetworkChangeSource` and the app lifecycle; attempts spaced by full-jitter backoff that gives up after 2 minutes; tracks and DataChannels republished under the same names without restarting capture; the new session announced (signaling retried with backoff); subscriptions pulled again; `RoomReconnecting`/`Reconnected`/`ReconnectFailedEvent`, `Room.reconnect()` and `Room.debugSimulateConnectionFailure()`. Unit-tested on the fakes with `fake_async`; the example app shows the reconnecting state, has a "simulate network drop" button and watches interface addresses for network changes. **Still to do:** run `example/integration_test/reconnect_test.dart` against a real broker and a real network drop on devices; mobile background specifics (keeping audio alive in the background, iOS `beginBackgroundTask`/CallKit, Android foreground service) belong with M6/M8; confirm what the SFU returns for a pull from a publisher session that is gone (the session now confirms itself with `GET sessions/{id}` before failing on such a `session_error`, so the subscriber no longer re-sessions for a peer's stale session; see §4.2) | 2–3 wk |
| M6 | Screen share (**desktop and web done**, pending device QA; mobile remains) | Desktop picker (`desktopCapturer`) and web `getDisplayMedia` capture (landed early, with the media layer: [design.md §10](design.md#10-screen-share-by-platform)); publishing with M3 (`LocalParticipant.publishScreen`). **Status (desktop path, end to end):** one text-friendly layer by default (`ScreenSharePresets.detail`: 15 fps, 2.5 Mbps; `motion` and `simulcast` presets as options; [design.md §12](design.md#12-open-questions), question 2), VP8 like every video track, a share that ends outside the app unpublished with its audio and announced (`LocalTrackUnpublishedEvent.endReason`), the macOS Screen Recording permission detected from its symptoms (`ScreenPickerState.permissionProblem`, `LocalScreenShareStalledEvent`, `ScreenCapturePermissionException` with guidance), and first-class "Share screen" / "Stop sharing" in the example's call screen, with remote shares on the stage. Unit and widget tests on the fakes. **Still to do:** Android MediaProjection, iOS Broadcast Upload Extension; device QA (text legibility, the simulcast preset's low layer, which permission symptoms macOS versions show) | 3–4 wk (includes QA) |
| M7 | DataChannels (**done**, verified on the real SFU: Windows, Android, macOS, iOS) | Reliable and unreliable profiles, `canReply`, sender `sessionId` exposed. **Status:** `SfuSession.publishDataChannel`/`subscribeDataChannel` with lazy `datachannels/establish`, batching, per-channel errors, backpressure, and `republishDataChannel`/`resubscribeDataChannel` for M5 ([design.md §9](design.md#9-datachannels)); unit-tested against the fakes. `room.data` landed with M3. Still to do: running `example/integration_test/datachannel_echo_test.dart` against a real broker, and the web `maxRetransmits: 0` gap in `flutter_webrtc` | S–M |
| M8 | Publish to pub.dev | API review, dartdoc, README setup guides (iOS extension, Android FGS, broker), example app, remove `publish_to: none`, widen the SDK constraint, 0.1.0 | M |

M7 can run alongside M4–M6. The first consumer's remote-control feature needs it.

## Consumer checkpoint (week 6)

**At week 6 of this work**, the first consumer (buildIt.Social) makes a go/no-go call. It continues on this package only if all three of these hold:

1. **Calls work:** a 1:1 **and** a 4-person call on **Windows, macOS and Android**.
2. **Simulcast layer switching** works.
3. **Recovery:** a call recovers from a network drop.

If any fails, that app switches to LiveKit behind its own `VideoProvider` interface, and this package continues as a side project.

**So prioritize M1–M4 plus a basic M5 and a desktop-only M6 path over polish.** The example app should be able to demonstrate all three criteria. **[checkpoint.md](checkpoint.md) is the runbook** for demonstrating them with the example app and the dev server.

## Same behaviour on every platform

A goal for the whole package ([design.md §2](design.md#2-goals-and-non-goals)): the basic camera and audio calls do the same thing on every OS, so apps don't branch on the platform.

- **Camera (done, verified on Android, macOS and iOS):**
  - the front camera opens by default (`CameraOptions.facing`);
  - the preset's resolution is honoured (it wasn't on Darwin or Android);
  - `switchCamera()` flips front ↔ back on phones and cycles through cameras elsewhere, without renegotiating;
  - the self-view is mirrored except for a back camera.
  
  `example/integration_test/camera_switch_test.dart` checks this on each device.
- **Audio (to check on devices):** the API is already one call per operation; what's left is making sure each platform does the same thing with it.
  - **Speaker routing on phones.** Android's `flutter_webrtc` prefers Bluetooth, then wired, then the speakerphone, then the earpiece. iOS uses the speaker in video-chat mode but the earpiece in voice-chat mode (no video). A call should start on the speaker (or a headset) on both.
  - **Choosing the speaker.** `Room.setAudioOutputDevice` lists earpiece/speaker/Bluetooth/wired on Android, but on iOS it can only switch between the speaker and the current route. Decide on one model, for example a `speakerphone` switch plus the device list.
  - **Choosing the microphone on phones.** `MicrophoneSource` selects a device through `getUserMedia`'s `sourceId`; on Android and iOS the input follows the audio route (`Helper.selectAudioInput`) instead. Check that choosing a headset microphone works.
- **Still to do for the camera:** the web (labels decide which way a camera faces there).
- **A publish that waits on a permission prompt.** If the first publish waits long enough on the camera or microphone prompt (about a minute, seen on iOS), the SFU drops the still-unused session and the publish throws `SessionGoneException` (410). The Room re-sessions, but doesn't retry that publish. On phones, where the prompt comes with the first publish, the publish should survive this: retry it on the new session, or capture before the session's first use.

## Testing

- **Unit tests:**
  - the op queue and batching, against a fake `BrokerClient`;
  - participant diffing and pull-on-subscribe (**done**);
  - layer selection (**done**), and its Room wiring (**done**);
  - backoff and the reconnect trigger (**done**);
  - the room's re-session: triggers, backoff and giving up, moving tracks, DataChannels and subscriptions, `leave()` mid-reconnect (**done**, with `fake_async`);
  - active-speaker detection (**done**), and its Room wiring (**done**).
- **Integration:** use a real SFU app with the example app and a local broker. The DEV ONLY [`tools/dev-server/`](../tools/dev-server/README.md) provides the broker and WebSocket signaling for multi-device runs, including the week-6 checkpoint calls. Keep the credentials in the environment only (see [CLAUDE.md](../CLAUDE.md)).
- **Device matrix before 1.0:** Windows, macOS, Android, iOS, and Web (Chrome, Safari, Firefox).
