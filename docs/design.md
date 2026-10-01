# Design: `cloudflare_realtime`

This package is a Flutter client for the [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/). It is built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) and targets **Android, iOS, macOS, Windows and Web**.

- **Status:** pre-release. Implemented and unit-tested: the broker client and reference brokers (§4.1, §5), the SFU session with DataChannels (§4.2, §9), rooms (§4.3), signaling (§4.4), media and desktop screen capture (§4.5, §10), simulcast layer selection (§6), active speaker (§7) and reconnection (§8). Verified against the real SFU on Windows and Android (loopback push/pull, DataChannel echo and reconnect integration tests), plus a Windows ↔ Android cross-device call with layer switching; macOS, iOS and 4-person calls are not yet verified. Mobile screen share (M6) and pub.dev release (M8) remain.
- **Companion docs:**
  - [cloudflare-sfu.md](cloudflare-sfu.md): what the SFU API provides.
  - [roadmap.md](roadmap.md): build order and milestones.

## 1. Why this package exists

The Cloudflare SFU is plain WebRTC media forwarding, controlled by an HTTPS sessions/tracks API. Cloudflare ships no Flutter client for it:

- **RealtimeKit's Flutter SDKs** (`realtimekit_core`, `realtimekit_ui`) were discontinued on pub.dev in August 2026. They only ever supported Android and iOS.
- The reference client is **partytracks**, a TypeScript/RxJS library. It is licensed ISC, and it lives in [`cloudflare/partykit`](https://github.com/cloudflare/partykit/tree/main/packages/partytracks). **It is the blueprint for this package.** When code is ported from it, keep its notice in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md).
- A second reference is **Cloudflare Meet** (formerly Orange Meets), a full meeting app: <https://github.com/cloudflare/meet>.

**The SFU has no concept of rooms or presence.** Cloudflare calls a room "application state". This package provides the client side of rooms, and **the app brings its own signaling** through an interface (§4.4).

## 2. Goals and non-goals

**Goals:**
- Publish camera, microphone and screen tracks, and subscribe to other participants' tracks.
- Rooms on top of a pluggable signaling/presence transport.
- **Simulcast publishing and per-subscriber layer selection. Simulcast is mandatory:** without it, SFU egress is about 3× higher (see §6).
- Active-speaker detection.
- **Automatic reconnection**, including network changes and mobile background/foreground.
- Screen share on every platform `flutter_webrtc` supports.
- DataChannels (reliable and unreliable) for app messages, such as reactions or remote-control input.
- The Cloudflare **App Secret never reaches the client.** Every SFU API call goes through a server-side broker (§5).

**Non-goals** (the app's job, or later work):
- **A signaling or room server.** The app supplies a `Signaling` implementation.
- **Remote-control input injection** (`SendInput`, `CGEventPost`). The package only carries the bytes over DataChannels.
- Recording, transcription, egress to RTMP.
- End-to-end encryption. Possible later through `flutter_webrtc`'s frame cryptor.
- Heavy UI. At most a thin video-view helper and a desktop source-picker model; no meeting UI.

## 3. First consumer and API shape

The first consumer is the buildIt.Social app. It wraps this package behind its own `VideoProvider` interface, so that `livekit_client` can be swapped in if needed.

To keep that swap cheap, **use LiveKit-like concepts where they fit**: `Room`, `LocalParticipant`/`RemoteParticipant`, track publications, `connectionState`, `activeSpeakers`. Don't copy LiveKit code or API verbatim.

## 4. Architecture

```
┌────────────────────────── app ──────────────────────────┐
│  Signaling impl (e.g. Supabase Realtime presence)       │
└──────────────┬──────────────────────────────────────────┘
               │ participants: {id, sessionId, tracks}
┌──────────────▼───────────── cloudflare_realtime ────────┐
│ Room ── participants, active speaker, layer selection   │
│   │                                                     │
│ SfuSession ── 1 RTCPeerConnection ↔ 1 SFU session       │
│   │   op queue: push / pull / update / close / renego   │
│ BrokerClient ── typed HTTP client for the broker        │
│ Media ── camera / mic / screen capture, device lists    │
└──────────────┬──────────────────────────────────────────┘
               │ HTTPS (app auth headers)
        ┌──────▼──────┐   Bearer <App Secret>   ┌──────────────────┐
        │   Broker    ├────────────────────────►│ Cloudflare SFU   │
        │ (app server)│                         │ rtc.live.cf.com  │
        └─────────────┘                         └──────────────────┘
```

### 4.1 `BrokerClient`

A typed client for the broker contract (§5), in `lib/src/broker/`. Implemented (M1).

- **`BrokerConfig`** takes:
  - the broker's base URL,
  - an async `headers` provider. The app uses it to attach its own auth, such as `Authorization: Bearer <user JWT>`. It is called before every request, so it can refresh a token;
  - optionally an injected `http.Client` and a per-request timeout (default 15 s).
- **`BrokerClient`** is an abstract interface, one method per endpoint in §5, so session code can be tested against a fake. **`HttpBrokerClient`** implements it with `package:http`. One instance serves one room.
- **Typed models** mirror the SFU's OpenAPI schema: `TracksRequest`/`TracksResponse`, `TrackObject.local`/`.remote` (with `SimulcastConfig`), `CloseTracksRequest`, `DataChannelObject`, `SessionState`, and so on.
- **Errors.** A failed call throws a `BrokerException` carrying the status, `errorCode` and `errorDescription`. Subclasses: `BrokerUnauthorizedException` (401), `BrokerForbiddenException` (403), `SessionGoneException` (410, or `errorCode: session_error` at any status; the Room re-sessions on it, §8), `BrokerNetworkException`, `BrokerTimeoutException` and `BrokerProtocolException` (an unparseable 2xx).
  - A 2xx response with a request-level `errorCode` is **returned**, not thrown, so per-track results aren't lost; check `hasError` on the response and on each track or DataChannel result.
  - The client never logs. Exception messages never contain SDP, header values or tokens.
- **ICE servers.** `getIceServers()` returns maps ready for `flutter_webrtc`'s `iceServers`, **one map per URL** with a string `urls`: `flutter_webrtc`'s Windows implementation keeps only the last entry of a `urls` array. The desktop plugin (Windows, Linux) also copies the entries into a fixed array of 8 with no bounds check, so on those platforms the peer connection factory keeps at most 8 (dropping port-53 and duplicate URLs first, then the tail). Cloudflare's TURN service returns up to 9 URLs; the reference brokers already drop the two on port 53.
- The client doesn't serialize calls. The session layer's op queue does (§4.2).

### 4.2 `SfuSession`

One `RTCPeerConnection` maps to one SFU session. A participant normally has **one session** that carries everything they push and pull. Implemented (M2) in `lib/src/session/`, ported from partytracks' `PartyTracks.ts` and `Peer.utils.ts`.

**API** (exported from the barrel):

```dart
final session = await SfuSession.connect(broker: broker, options: SfuSessionOptions(...));
session.sessionId;                      // share through signaling
session.connectionState;                // Stream<SfuConnectionState>, replays the current value
session.currentConnectionState;         // initial/connecting/connected/disconnected/failed/closed
session.failures;                       // Stream<SfuSessionFailure>: at most one, replayed to late listeners
session.failure;                        // SfuSessionGone | SfuPeerConnectionFailed | null

final pub = await session.publish(track, options: PublishOptions(trackName?, sendEncodings?, codecPreferences?));
await pub.whenSending();                // RTP is flowing: now advertise pub.trackName + pub.sessionId
await pub.replaceTrack(otherCamera);    // no renegotiation; null mutes (transceiver and mid stay)
await pub.setEncodings([...]);          // no renegotiation (bitrates, active layers)

// Or follow a media source's track stream (null while muted, a new track on device change):
final cam = await session.publishTrackStream(source.broadcastTrack.map((t) => t?.track), kind: 'video');

final sub = await session.subscribe(remoteSessionId: id, trackName: name, preferredRid: 'b');
sub.track; sub.trackStream;             // MediaStreamTrack? / Stream<MediaStreamTrack>
await sub.setPreferredRid('c');         // tracks/update

await session.getStats();               // List<StatsReport>, outside the queue (M4)
await pub.unpublish(); await sub.unsubscribe();   // tracks/close
await session.republish(pub); await session.resubscribe(sub, remoteSessionId: newId);  // on a new session
await session.close();
```

`LocalTrackPublication` and `RemoteTrackSubscription` have a `state` (`SfuTrackState`: `pending`, `active`, `interrupted`, `failed`, `closed`), a replaying `states` stream, `error`, `session` and `mid`.

- **Connect.** As in partytracks (`forkJoin`), `sessions/new` and `generate-ice-servers` are requested together (the latter skipped when `SfuSessionOptions.iceServers` is set), then the peer connection is created with `bundlePolicy: max-bundle`. Nothing is negotiated until the first push or pull. If either call fails, the new session is forgotten and the error is thrown.
- **Push** (publish local tracks):
  1. Add a `sendonly` transceiver per track (with simulcast encodings for video) and apply codec preferences.
  2. `createOffer`, then `setLocalDescription`.
  3. `POST tracks/new` with the offer, and `tracks: [{location: "local", mid, trackName}]`.
  4. `setRemoteDescription(answer)`.

  Track names are UUIDs (partytracks uses `crypto.randomUUID()`) unless the caller names the track; names are unique per session.

  **Offers and answers pass empty constraints** (`{}`). Without an argument, native `flutter_webrtc` (Android, Darwin, Windows, Linux) sends `OfferToReceiveAudio/Video: true`, and libwebrtc then adds a `recvonly` audio and a `recvonly` video transceiver to the first offer. The SFU answers those undeclared m-lines, so every session carried two stray transceivers, and on Windows they hid the close problem below. Browsers add nothing for `createOffer()`, so `{}` matches the web and partytracks (found against the real SFU, after M7).

  **Mute and device changes.** partytracks keeps sending a black or silent placeholder track while muted; `flutter_webrtc` can't make those, so the media layer's `broadcastTrack` is null while muted. `replaceTrack(null)` therefore stops sending without renegotiating: the transceiver and `mid` stay, and unmuting is another `replaceTrack`. Replacements are applied in order and settle on the latest track. `publishTrackStream(tracks, kind:)` follows such a stream (partytracks' `push(track$)`): it pushes whatever the stream holds when the push goes out (possibly nothing: the transceiver is then created from `kind`), and applies every later value. The session code takes plain `MediaStreamTrack`s and doesn't import the media layer. **Deviation:** partytracks adds the transceiver when `push` is called; here it is added inside the queued operation, so an unrelated offer in flight never carries an undeclared m-line.

  partytracks emits a pushed track's metadata only once the sender reports `bytesSent > 0`, so peers don't pull too early. Here `publish` completes when the SFU accepts the track, and `whenSending()` ports the wait (stats polled from 1 ms, ×1.1, capped at 100 ms). **Decision (M3):** the Room does *not* wait for `whenSending()`; it advertises a track as soon as the SFU accepts it, because a publication muted from the start sends no RTP and would never be announced. Subscribers instead retry pulls that fail before the first packets (§4.3).
- **Encodings and codecs.**
  - Video defaults to `SimulcastPresets.h720`: rids `a` (full, 1.2 Mbps), `b` (`scaleResolutionDownBy: 2`, 400 kbps), `c` (4, 150 kbps). `h1080` and `h360` exist too; M4 tunes the numbers. `sendEncodings: []` publishes one default encoding. Audio has none.
  - Codec preferences are MIME types; set, they **restrict** the transceiver to those codecs plus rtx/red/ulpfec/flexfec, so the SFU can't pick another. The default is `['video/VP8']` on every platform (§6, Codec; `SfuSessionDefaults.videoCodecPreferences` overrides it). A platform that rejects `setCodecPreferences` keeps its default order.
- **Pull** (subscribe to remote tracks):
  1. `POST tracks/new` with `tracks: [{location: "remote", sessionId, trackName, simulcast?}]`. `simulcast` is sent only with a `preferredRid`; `ridNotAvailable` then defaults to `asciibetical`, and `priorityOrdering` is left to the SFU default (`none`) unless given (§6).
  2. If the response has `requiresImmediateRenegotiation`, then `setRemoteDescription(offer)`, `createAnswer`, `setLocalDescription`, and `PUT renegotiate` with the answer.
  3. Map the returned `mid` to the transceiver, which gives you the remote track. Results are matched by `trackName` + `sessionId`, as in partytracks. The transceiver is looked up after renegotiation, waiting up to 5 s for its `track` event (partytracks' `resolveTransceiver`).
- **Update:** `PUT tracks/update` with the pulled track's `mid` and its full `simulcast` object (keeping the orderings). Updates are batched too, and the last `rid` per subscription in a batch wins. On a subscription that isn't active, the rid is only remembered for the next pull. partytracks fires updates outside its queue; here they are queued.
  - **The SFU rejects a layer change until it forwards the track.** Right after a pull, `tracks/update` answers `update_track_error` "The track is not configured for simulcast, no updates applicable." until media reaches the subscriber (a few hundred milliseconds against the real SFU; waiting for `inbound-rtp` bytes made it pass every time). The Room changes layers as soon as a pull lands, so `setPreferredRid` retries that one error with backoff (100 ms doubling to 1 s) for up to `SfuSessionOptions.layerUpdateRetryTimeout` (10 s), outside the queue. A newer `setPreferredRid` on the same subscription supersedes a pending retry. Once accepted, the received resolution follows only at a keyframe of the new layer: 8–13 s in most of the first Windows ↔ Android runs (sometimes 1–4 s), regular enough to look like an SFU-side timer (`docs/checkpoint.md`, criterion 2 notes). Nothing in the client waits for it. A track published without simulcast gets the same answer for good; the Room never asks for a layer there (§6.1), and a direct caller gets the error after the timeout.
- **Close:** stop the transceivers, `createOffer`, `setLocalDescription`, `PUT tracks/close` with the `mid`s and the offer (`force: false`), then apply the answer, or renegotiate if the response asks for it. `close_track_error` counts as closed. The publication or subscription is closed locally even if the request fails. On a failed or closed session, only local state changes (partytracks also skips negotiation on a dead connection). Local `MediaStreamTrack`s are never stopped: capture belongs to the app.
  - **Closing the session's last live m-lines** (every m-line of the current local description that isn't rejected, including a DataChannel `application` m-line) can't be negotiated: with `max-bundle`, libwebrtc refuses an offer whose m-lines are all rejected ("max-bundle configured but session description has no BUNDLE group"), and with `balanced` the offer goes through but the transport closes and the SFU drops the session (410 on the next call). Both seen against the real SFU on Windows. So that close uses `force: true` with no SDP, and **parks** the transceivers instead of stopping them: a parked sender gets `replaceTrack(null)`, the SFU stops forwarding, and the idle m-lines keep the transport up. Later pushes and pulls work on the same session (tested: re-pull, re-push, and a negotiated close next to a parked m-line). Stopping the transceivers without negotiating crashed the Windows app on the next SFU offer, so they are left as they are. Parked transceivers live until the session closes.
- **All operations run through one serialized queue** (`OpQueue`, a port of `FIFOScheduler`). The SFU requires each SDP exchange to finish before the next mutation on the same session.
  - Pushes, pulls, updates and closes that arrive in the same event-loop turn are each batched into one request (`BatchDispatcher`, a port of `BulkRequestDispatcher`: a zero-duration timer, at most 32 items per batch). A push batch and a pull batch in the same turn become two requests, run one after the other (one `tracks/new` is all local or all remote).
  - A failing operation fails only its own items; the queue moves on.
  - **The queue heals the signaling state.** A push or close that fails after `setLocalDescription(offer)` (broker error, request-level `errorCode`, no answer) would leave `have-local-offer`; a failure after applying an SFU offer leaves `have-remote-offer`. Either would make the next exchange fail. So after any failed operation, and before each one, the queue checks the signaling state and rolls back (`{type: rollback}` through `setLocalDescription` or `setRemoteDescription`) to `stable`. If the rollback fails or isn't supported on a platform, the session fails with `PeerConnectionFailureKind.signalingStuck`, so the Room replaces it (§8) instead of it staying wedged. partytracks doesn't do this; it relies on re-creating the whole session.
  - Cleanup runs inside the queue before an operation's futures complete: the transceivers of failed pushes (a whole-request failure, a per-track error or a missing `mid`) are stopped, so later offers leave them out (or reject them with port 0), and the publication drops them; a `republish` adds a fresh transceiver.
  - A `tracks/close` response that carries an SFU offer instead of an answer rolls back our close offer, then answers theirs.
- **Per-track errors:** an error on one track (or a missing result) fails only that publish, pull, update or close, with an `SfuTrackException` carrying the SFU's `errorCode`. The rest of the batch succeeds. A request-level `errorCode` in a 2xx fails the whole batch with an `SfuRequestException`; broker exceptions pass through unchanged.
- **Failures and replacement.** The session doesn't reconnect; the Room does (§8). It reports one `SfuSessionFailure` and then refuses operations (`SfuSessionFailedException`):
  - `SfuSessionGone` when a broker call throws `SessionGoneException`. **Except for requests that name other sessions** (pulls, and DataChannel subscribes with `location: remote`): there the 410 or `session_error` may be about the *publisher's* expired session, but `HttpBrokerClient` can only attribute it to the session in the path, ours. So the session first confirms itself with `GET sessions/{ownId}` (hardening, after M5):
    - gone (`SessionGoneException`) or refused (`403`: the broker no longer lets us use it): the session fails as above;
    - alive, or the check itself fails (network, timeout, 5xx; that proves nothing either way): only the batch's items fail, as per-item errors (`SfuTrackException` / `SfuDataChannelException` with the SFU's `errorCode`, `session_error` for a bare 410), and the Room's pull retries handle them (§4.3). A real outage still shows on the peer connection. Every item in the batch fails, since the error doesn't say which session it meant; the retries are jittered, so the healthy pulls land in other batches.

    Pushes, updates, closes, renegotiation and `datachannels/establish` name only our session and fail it at once, as before. `HttpBrokerClient` keeps the session token on a `SessionGoneException` (the confirmation needs it); `forgetSession` drops it when the session is closed.
  - `SfuPeerConnectionFailed` when the connection state becomes `failed`, the ICE state `failed`, the connection closes unexpectedly, or ICE stays `disconnected` longer than `iceDisconnectedTimeout` (7 s, as in partytracks; null disables it).

  Its publications and subscriptions become `interrupted` and detach from it; they survive the session. The Room's re-session connects a new session and calls `republish` (same `trackName`, current track and encodings) and `resubscribe` (optionally with the publisher's new `sessionId`); `trackStream` then emits the new remote track. `close()` also leaves them `interrupted`, fails queued operations with `SfuSessionClosedException`, and calls `BrokerClient.forgetSession`. partytracks instead re-creates the session inside `session$` and re-pushes automatically; here that policy is the Room's (§8).
  - **`debugSimulateFailure()`** (tests and demos only) fails the session with `PeerConnectionFailureKind.simulated` and closes its peer connection, so the whole recovery path runs as after a real drop. `Room.debugSimulateConnectionFailure()` calls it.
- **Peer-connection abstraction.** `SfuSession` talks to an internal `PeerConnection`/`PeerTransceiver` interface (including `getStats()`, M4): `FlutterWebrtcPeerConnection` wraps `flutter_webrtc`, and tests use a scripted fake with opaque SDP (`test/support/`). Native `flutter_webrtc` transceivers cache their `mid` from creation, so the wrapper re-reads it through `getTransceivers()`, finding its entry there by the **sender's ID**. The `transceiverId` isn't stable across plugins: Android reports a random ID until the transceiver has a `mid` and the `mid` afterwards, and Darwin always reports the `mid` (empty before negotiation); only the C++ desktop plugin keeps one ID. Matching on `transceiverId` failed every push on Android ("the transceiver has no mid", found against the real SFU on a Pixel). `stop()` goes through the same lookup, because Darwin finds a transceiver to stop only by its current `mid`. On Windows and Linux, at most 8 ICE server entries reach the plugin (§4.1, ICE servers); Android, Darwin and the web get the list unchanged (checked with TURN on Android: 9 URLs, no problem). The interface also creates negotiated DataChannels (`PeerDataChannel`, §9); the DataChannel layer reaches the session's queue, broker and peer connection through an internal `SfuSessionPort`. The internal `connectSfuSession(createPeerConnection: ...)` injects a fake; M3 tests can use it with `test/support/session_harness.dart`.
- **Not done here:** rendering a remote track needs a `MediaStream` for `RTCVideoRenderer`; the Room wraps it (§4.3). Pushes aren't retried one by one (partytracks retries each push/pull with backoff): a re-session republishes everything (§8), and the Room retries pulls.

### 4.3 `Room`

`Room` ties a session to signaling. Implemented (M3) in `lib/src/room/`, with the video view in `lib/src/rendering/`. The concepts follow LiveKit (§3); the code and API names are our own.

- **Join.** `CloudflareRealtime.join(roomId, signaling:, participantId:, metadata:, options:)` creates an `HttpBrokerClient` for the room (every request carries `X-Realtime-Room`), connects an `SfuSession`, then joins signaling with `{participantId, sessionId, tracks: {}, metadata}`. If any step fails, what was opened is closed and the error thrown. The broker-client and session factories (and the track wrapper, below) are injectable, so tests run on the M2 fakes (`test/support/room_harness.dart`).
- **Announcing.** The local state (`LocalParticipant.state`) is `{participantId, sessionId, tracks: {trackName → {kind, source, muted, simulcast}}, metadata}`. It is re-announced whenever the local participant publishes, unpublishes, mutes, unmutes or changes metadata. Updates go through a coalescing runner: they never overlap, and a burst becomes at most one more update. A failed `Signaling.update` is reported as a `RoomErrorEvent` and retried on the next change.
- **Publishing** (`LocalParticipant`): `publishCamera`, `publishMicrophone` and `publishScreen` each create a media source (the Room owns and disposes it; camera and microphone share one `MediaDeviceList`), start broadcasting, and push `source.broadcastTrack` with `publishTrackStream`. `publishMediaSource` publishes an app-owned source, which the Room never disposes.
  - **Advertise on accept.** A track is announced as soon as the SFU accepts the push, not after `whenSending()` (§4.2): a muted track never sends. The initial pull can then race the first packets, so subscribers retry (below).
  - **Track names** are `<source>-<uuid>`, fixed for the publication's lifetime, so a re-session's `republish` keeps the name (§8).
  - **Mute** is the media layer's broadcasting switch (§4.5): `mute()` = `stopBroadcasting()`, so the sender gets `replaceTrack(null)` and, for camera and screen, the capture is released. The track stays published and is announced with `muted: true`. `publishCamera(muted: true)` / `publishMicrophone(muted: true)` publish without capturing.
  - **Simulcast hint.** `publishCamera` announces its layers as `TrackInfo.simulcast` (rids, the requested capture size and scale factors), from the encodings (default `SimulcastPresets.h720`) and the `CameraOptions` preset. A single encoding announces none.
  - **Screen share** (M6, desktop and web; §10) is one layer tuned for text by default: `ScreenSharePresets.detail` (up to 15 fps and 2.5 Mbps), captured at 15 fps (`ScreenShareOptions.frameRate`), with no simulcast hint. `ScreenSharePresets.motion` (30 fps, 4 Mbps) and `ScreenSharePresets.simulcast` (a thumbnail layer) are the options; §12, question 2 has the reasoning. It is VP8 like every video track (§4.2, §6). With `captureAudio`, the audio is published too, as a `screenAudio` track.
    - **Ending.** When the share ends outside the app (`ScreenShareEndReason.userStopped`: the browser's "Stop sharing"; `sourceClosed`: the shared window or display went away), the room unpublishes it and its audio, re-announces the local state, and emits `LocalTrackUnpublishedEvent` with that `endReason` (`null` when the app unpublished). A share that ends while it is still being pushed is caught too and unpublished right after. Muting ends the capture but keeps the track published; unmuting shares the same source again.
    - **No frames.** While a share captures, the room reads `getStats()` once a second and reports `LocalScreenShareStalledEvent` once per capture when neither the track's video `media-source` (`frames`) nor the publication's `outbound-rtp` (`framesEncoded`) has counted a frame for `RoomOptions.screenShareStallTimeout` (8 s, counted only while the room is connected; `null` turns it off). On macOS its error is a `ScreenCapturePermissionException` (the missing Screen Recording permission, §10); elsewhere a `MediaCaptureException` (a minimized window, for example). The share stays published; the app decides. Platforms without those stats never report it.
  - Capture failures throw the source's `MediaException` (a cancelled browser picker throws `MediaCaptureException`), and the source is disposed. Nothing is announced then.
- **Diffing** (`participant_diff.dart`, internal, unit-tested): successive `Signaling.participants` lists are diffed by `participantId` into joined, left and updated participants, and per participant into added, removed and changed tracks (a changed `muted` or `simulcast`; a changed kind or source counts as removed plus added), a session change and a metadata change (deep). **Participants without a `sessionId` are ignored** as if absent, so losing a session is a leave. Entries with the local `participantId` or `sessionId` are dropped. `Room.participants` emits once per signaling change.
- **Pull only what's subscribed.** Each remote track is a `RemoteTrackPublication`, pulled while it is wanted:
  - `RoomOptions.autoSubscribe` (default: audio yes, video no),
  - `subscribe()` / `unsubscribe()` (an explicit switch), or
  - a `RemoteTrackLease` from `retain()`; `ParticipantVideoView` holds one while mounted, so several views of a track share one pull.

  Video is pulled with `preferredRid` only when the publisher advertises simulcast layers (or the app picked a layer), with the `ridNotAvailable`/`priorityOrdering` of `RoomOptions.layerSelection`. The layer comes from the views' sizes (§6.1); before any view reports, it is `RoomOptions.defaultVideoLayer` (default `b`). `setPreferredLayer(SimulcastLayer.high/medium/low)` overrides it with `a`/`b`/`c`, or picks by rank among the advertised rids.
  - **Lease grace (M4).** A released lease keeps the pull for `RoomOptions.leaseReleaseGrace` (500 ms), so a view that is unmounted and mounted again (a layout change, a rebuild with a new key) doesn't close and re-pull. `Duration.zero` releases at once.
- **Following publishers.**
  - A track that disappears from the publisher's state is closed (`tracks/close`) and removed; a participant that leaves has all its pulls closed.
  - **Session change** (they reconnected): every wanted track is pulled from the new session. A pull that is live on the old session is closed first and pulled afresh, because a live `RemoteTrackSubscription` can't be moved (`resubscribe` requires it to be off its session); a failed or interrupted one is moved with `resubscribe(remoteSessionId: new)`. **Deviation:** the task sketch said "resubscribe every active subscription"; the session API only allows that for detached subscriptions.
  - **Retries.** A failed pull is retried with `RoomOptions.pullRetry` (full-jitter backoff; default 250 ms to 4 s, 8 attempts), and again at once whenever the publisher's state for it changes (unmute, new session). Failures are reported as `TrackSubscriptionFailedEvent` with `willRetry`.
- **Rendering.** A pulled track is wrapped in a `MediaStream` (`createLocalMediaStream('local')` plus `addTrack`) so `RTCVideoRenderer.srcObject` can show it: `RemoteTrackPublication.track` is a replaying `Stream<RenderableTrack?>` (track + stream). The label `local` matters: native `flutter_webrtc` uses it as the stream's `ownerTag`, and renderers look up `local`-tagged streams among the local streams, where this one lives. Each replaced or unsubscribed wrapper is disposed.
  - **Disposing the wrapper is safe for the remote track** (checked in the `flutter_webrtc` 1.6.2+hotfix.3 sources, M4). `streamDispose` never stops or disposes a track: Android removes the tracks from the Java stream and drops their IDs from `localTracks` and the capturer map (a pulled track is in neither); Darwin drops the stream from `localStreams`; Windows removes the tracks from the stream and erases their IDs from `local_tracks_`. The receiver keeps the track alive, so a later re-pull or re-render works. On the web, `dispose()` does nothing.
  - **Don't remove the track first.** `mediaStreamRemoveTrack` looks the track up among local tracks only on Android and Darwin, so it fails for a pulled track (Darwin even answers the call twice). Unwrapping therefore only calls `dispose()`; a unit test pins that.
  - **One Darwin side effect.** `streamDispose` also detaches the first renderer showing each of the stream's video track IDs. A new pull has a new receiver and so a new track ID, but if a pulled track ever reappears under a new Dart object with the same ID, the room keeps the existing wrapper instead of disposing it, so the renderer isn't blanked.
- **`ParticipantVideoView`**: `.remote(publication, subscribe: true)` or `.local(mediaSource)`, with `fit` (`VideoViewFit.cover`/`contain`), `mirror` (default: local cameras), a `placeholder` (shown while not pulled, muted or not capturing), and `filterQuality`. Native calls sit behind `VideoRenderer` (`FlutterWebrtcVideoRenderer` by default; `rendererFactory` or the static `defaultRendererFactory` swap in a fake for widget tests), and the renderer is created only once there is video. **Layer selection** (M4): a remote video view wraps itself in `SimulcastLayerReporter` keyed by `RemoteTrackPublication.id` (`participantId/trackName`, stable across the publisher's sessions) and reports to `Room.layerReporter` by default (§6.1), with `visible`. `automaticLayers: false` opts out; `layerReporter` reports elsewhere.
- **Connection state** (`RoomConnectionState`), from the session: `initial` (nothing negotiated yet) and `connected` → `connected`; `connecting` → `connecting`; `disconnected` → `reconnecting`. A failure emits `RoomSessionFailedEvent` (`Room.failure`) and starts a re-session (§8): `reconnecting` until the new peer connection is connected (or nothing is negotiated on it; §8.1 step 6), then `connected`, or, when it gives up, `disconnected`. With `ReconnectOptions.enabled: false` a failure goes straight to `disconnected`. The room stays in signaling either way, so `Room.reconnect()` can recover in place.
- **`leave()`**: stops listening, leaves signaling (so others stop pulling), unpublishes every local track in one `tracks/close`, closes the session, disposes the sources and device list the Room created, releases remote wrappers, disposes the broker client, ends `disconnected` and completes its streams. Idempotent; failures along the way are ignored.
- **Events** (`Room.events`, sealed `RoomEvent`): participant joined/left/updated, track published/unpublished/muted/subscribed/subscription-failed, local track published/unpublished (with a screen share's `endReason`), local screen share stalled (M6), connection-state changed, session failed, reconnecting/reconnected/reconnect-failed (§8), and non-fatal `RoomErrorEvent`s.
- **`data`** (`RoomData`, §9): `publish(name, profile:)` returns the session's `LocalDataChannel`; `subscribe(participant, name, profile:, canReply:)` returns a `RemoteDataSubscription` whose `messages` carry `RoomDataMessage.participantId`. The sender is the participant that announced the channel's session in signaling (the Room remembers every session a participant announced, and a session claimed by two participants maps to none), **never the payload**. The subscription follows the publisher to a new session: a detached channel moves with `resubscribeDataChannel`, a live one is closed and subscribed afresh; `messages` carries on.
- **Layer selection and active speaker** (M4): §6.1 and §7.
- **Re-sessioning:** §8.
- **Remote audio** (hardening, after M5). Native platforms play a pulled audio track by themselves; browsers only play media attached to a media element. So the Room feeds every pulled audio track (microphone and screen audio) to an internal `RemoteAudioSink` (`lib/src/audio/`, picked by a conditional import on `dart.library.js_interop`), keyed by `RemoteTrackPublication.id`:
  - **Web:** one hidden `<audio autoplay playsinline>` element per track (`package:web`; the JS track comes from `dart_webrtc`'s `MediaStreamTrackWeb.jsTrack`), in one hidden container. A re-pull swaps the element's `srcObject`; unsubscribing, unpublishing and `leave()` remove it.
  - **Native:** does nothing.
  - **Autoplay policy.** A `play()` refused with `NotAllowedError` marks playback blocked: `Room.audioPlaybackBlocked` (`bool`) and `Room.audioPlaybackBlockedChanges` (replaying stream). The app shows a prompt whose tap calls `Room.startAudio()`, which calls `play()` on every refused element synchronously inside the gesture and completes with whether audio plays. Any later successful `play()` (the page got a gesture elsewhere) retries the refused ones too, and removing the last refused track clears the flag. Always `false` on native.
  - **Output device.** `Room.setAudioOutputDevice(deviceId)` (with `canSelectAudioOutput`) uses `HTMLMediaElement.setSinkId` on the web, for current and later elements (not every browser has it), and `flutter_webrtc`'s `Helper.selectAudioOutput` on native (app-wide).
  - Tests swap the sink through `debugRemoteAudioSinkFactory` (internal) and check the bookkeeping; the web element code needs a browser run.

### 4.4 `Signaling` (app-provided)

A small interface. Roughly:

```dart
abstract interface class Signaling {
  Future<void> join(String roomId, ParticipantState self);
  Future<void> update(ParticipantState self);
  Stream<List<ParticipantState>> get participants; // excludes self
  Future<void> leave();
}
```

- `ParticipantState` is `{participantId, sessionId?, tracks: {trackName → {kind, source, muted?, simulcast?}}, metadata?}`. Its `toJson`/`fromJson` define the JSON that adapters put into presence payloads; the shape is documented on the class.
  - **`muted`** (M3, optional): `true` while the publisher sends nothing for the track; omitted when `false`, and anything but `true` reads as `false`, so older peers interoperate.
  - **`simulcast`** (M3, optional): `{"rids": ["a","b","c"], "width": 1280, "height": 720, "scaleDownBy": [1,2,4]}` (`SimulcastInfo`), the layers a video track sends, highest first. Only `rids` is required. It is a hint, so it is parsed tolerantly: malformed input reads as "no hint" rather than failing the participant. Subscribers send a `preferredRid` only for tracks that carry it, and layer selection builds the publisher's ladder from it (§6.1).
- `participants` replays the current list to new listeners, emits `[]` while not in a room, and never includes the caller's own entry.
- **Ship an in-memory implementation** for tests and the example app: `InMemorySignaling`, where participants share an `InMemorySignalingHub` (several rooms per hub).
- **Keep backend adapters out of the core package.** For example, a Supabase Realtime presence adapter would be a separate package, such as `cloudflare_realtime_supabase`, or it lives in the app.
- **Dev signaling is an example, not core.** For multi-device testing there is a DEV ONLY local stack in [`tools/dev-server/`](../tools/dev-server/README.md). It mounts the broker core with a shared dev token, and adds a WebSocket presence endpoint whose protocol maps 1:1 to `Signaling`. Its Dart client, `WsSignaling`, lives in `example/lib/ws_signaling.dart`, and `web_socket_channel` is an example-only dependency. The core package gains no WebSocket or backend dependency from it.
- The core must not depend on any backend SDK.

### 4.5 Media

**Implemented** in `lib/src/media/`. It ports partytracks' `getDevices.ts`, `deviceManager.ts`, `resilientTrack$.ts`, `makeBroadcastTrack.ts` and `getScreenshare.ts` to Dart streams. Publishing is not part of it: M2's `SfuSession` consumes the tracks.

- **`MediaBackend`** wraps the `flutter_webrtc` APIs: `getUserMedia`, `getDisplayMedia`, `enumerateDevices`, `ondevicechange`, and `desktopCapturer` (`getSources`, `updateSources` and the `onAdded`/`onRemoved`/`onNameChanged`/`onThumbnailChanged` events).
  - Everything above it is unit-tested with fakes. `FlutterWebrtcMediaBackend` is the production implementation.
  - `desktopCapturer` is `null` on web and mobile.
- **`MediaDeviceList`** holds cameras, microphones and audio outputs.
  - It enumerates once, then again on every `devicechange`, and emits only real changes. This is partytracks' `devices$`.
  - Camera and microphone sources can share one list.
  - Choosing the audio output device isn't wrapped yet. Apps can call `Helper.selectAudioOutput`.
- **`CameraSource` and `MicrophoneSource`** (both `DeviceMediaSource`) handle device selection:
  - A **preferred device** sorts first. The priority order is: preferred, then the rest, then virtual devices and the "iPhone Microphone", then devices that recently failed.
  - **Capture tries devices in that order** until one yields a track. A permission error stops the search at once (`MediaPermissionDeniedException`). If every device fails, the source reports `DevicesExhaustedException` and turns off.
  - **Fallback:** when the active device is unplugged (a device-list change, or the track's `onEnded` on web), the source captures from the next device.
  - **Return:** when the preferred device comes back, the source switches back to it.
  - **Deviation from partytracks:** partytracks restarts capture on *any* device-list change. Here, capture restarts only when:
    - the active device went away,
    - the preferred device became available,
    - the options changed, or
    - the track ended.
  - **Deviation from partytracks:** it persists the preference and the failed-device list in `localStorage`. Here the app persists the preference (`currentPreferredDevice` / the `preferredDevice:` argument). A failed device is tried last only until it is unplugged or chosen again.
  - Consumers never re-subscribe. `track` emits the replacement track. When switching to a different device, the new track is captured before the old one is stopped, so there's no `null` gap.
  - **Options:**
    - Camera: `VideoPreset` (`h1080`, `h720`, `h540`, `h360`, `h180`; ideal width, height and frame rate) and facing mode. `h720` scaled by ½ and ¼ gives `h360` and `h180`, which are the simulcast layers in §6.
    - Microphone: echo cancellation, noise suppression and AGC, all on by default.
    - `setOptions` recaptures.
- **The mute model.** `LocalMediaSource` has two switches, as in partytracks:
  - **enabled** means capturing. `track` is the live track, or `null`.
  - **broadcasting** means sending. `broadcastTrack` is the track while it is both enabled and broadcasting, else `null`.
  - The two are linked: `startBroadcasting` enables the source, and `disable` stops broadcasting.
  - **Mute policy.** `MutePolicy` decides what `stopBroadcasting` does. It is partytracks' `retainIdleTrack`, made explicit:
    - `keepCapture` (default for the microphone): stay capturing. Unmute is instant, and "talking while muted" is possible. The OS mic indicator stays on.
    - `releaseCapture` (default for the camera and screen): also disable, so the camera light goes off.
  - `flutter_webrtc` can't synthesize partytracks' fallback tracks (the black canvas and inaudible tone). So "not broadcasting" is a `null` `broadcastTrack`. **M2 should `replaceTrack(null)` on the sender** (or send a disabled clone) and keep the SFU track published.
  - **Failures** go to `errors` and turn the source off. The methods return whether capture is running; they don't throw for capture failures. All capture work runs through one coalescing reconcile loop per source, so concurrent calls can't race.
  - The source owns its tracks: it stops them and disposes their streams when it replaces or releases them.
- **`flutter_webrtc` realities** (checked against 1.6.2+hotfix.3, the version in `pubspec.lock`):
  - **Native `getUserMedia` ignores the W3C `deviceId: {exact: id}`.**
    - Windows and Linux read only `optional: [{sourceId: id}]`, and treat a string `deviceId` on audio as the *output* device.
    - Android and Darwin read `deviceId` as a plain string.
    - So native platforms get `optional.sourceId`, and the web gets `deviceId.exact`.
  - **Windows silently opens the first camera** when the requested one is missing. The source trusts the track's `deviceId` setting over what it asked for.
  - **Native tracks never fire `onEnded`.** Device loss on native platforms is detected from the device list, and a desktop share ending from the capturer's source list (§10).
  - `ondevicechange` is a single callback slot. The backend multiplexes it and chains any previous handler.
  - Native errors are plain strings (`"Unable to getUserMedia: ..."`). Errors are classified by text.

## 5. Broker contract

The broker is a small HTTPS endpoint **the app operates**. It holds the App ID and App Secret and forwards requests to `https://rtc.live.cloudflare.com/v1/apps/{appId}`.

**Paths.** They mirror the SFU API with `/apps/{appId}` replaced by the broker's base path. This matches partytracks' `routePartyTracksRequest`, so an existing partytracks Worker proxy works with only an auth change.

| Client calls | Broker forwards to |
|---|---|
| `POST {base}/sessions/new` | `POST /apps/{appId}/sessions/new` |
| `POST {base}/sessions/{id}/tracks/new` | same path under `/apps/{appId}` |
| `PUT {base}/sessions/{id}/tracks/update` | 〃 |
| `PUT {base}/sessions/{id}/renegotiate` | 〃 |
| `PUT {base}/sessions/{id}/tracks/close` | 〃 |
| `GET {base}/sessions/{id}` | 〃 |
| `POST {base}/sessions/{id}/datachannels/establish` | 〃 |
| `POST {base}/sessions/{id}/datachannels/new` | 〃 |
| `PUT {base}/sessions/{id}/datachannels/update` | 〃 |
| `PUT {base}/sessions/{id}/datachannels/close` | 〃 |
| `POST {base}/generate-ice-servers` | TURN credentials: `POST /turn/keys/{turnKeyId}/credentials/generate-ice-servers`. Without TURN, it returns Cloudflare STUN only. |

**Wire details.** Both the Dart `BrokerClient` and the reference brokers follow these exactly.

- **Headers on every request**, including `generate-ice-servers` (so TURN credentials only go to room members):
  - the app's own auth headers, from the `headers` provider;
  - `X-Realtime-Room: <roomId>`, the room the caller is acting in.
- **Session token (optional).**
  - On `POST sessions/new`, the broker MAY return a response header `X-Realtime-Session-Token`.
  - If it does, the client sends it back as the request header `X-Realtime-Session-Token` on every later call for that session. The client keeps one token per session ID, because reconnection creates new sessions.
  - A broker may instead bind sessions server-side and never send a token. The client works either way.
  - The client never lets the app's headers set `X-Realtime-Room` or `X-Realtime-Session-Token`.
  - Browsers can only read the header if the broker lists it in `Access-Control-Expose-Headers`.
- **`sessions/new` body:** none, unless the client has an initial offer. `correlationId` travels as a query parameter, which the broker passes through.
- **Broker errors:**
  - `401`: the caller isn't authenticated. The body is unspecified.
  - `403` with `{"errorCode": "forbidden", "errorDescription": "..."}`: the caller isn't in the room, doesn't own the session, or names a session from another room.
  - The reference brokers also use `400` (missing room header, malformed body), `404`/`405` (unknown path or method), `413` (body over 1 MiB) and `502` (Cloudflare unreachable).
  - Otherwise the SFU's status and body pass through unchanged, including `410` with `errorCode: session_error` for an expired session.
- **`generate-ice-servers`** responds `200` with `{"iceServers": [{"urls": ["..."], "username"?: "...", "credential"?: "..."}]}`. Without TURN configured, it returns Cloudflare STUN only: `{"iceServers": [{"urls": ["stun:stun.cloudflare.com:3478"]}]}`. The reference brokers drop TURN URLs on port 53, which browsers block, and also accept `GET`, as partytracks clients use it.

**The broker must enforce these security requirements.** Document them in the README, and follow them in any reference broker:

1. **Authenticate the caller** with the app's own credential.
   - partytracks uses cookies, but native Flutter clients don't keep cookies. So the package sends whatever headers the app's `headers` provider returns.
   - The broker then replaces `Authorization` with the App Secret before forwarding.
2. **Authorize the room.** The client names the room it's joining in the `X-Realtime-Room` header. The broker checks that the caller is a member of it.
3. **Bind sessions to their creator.** After `sessions/new`, only the same caller, in the same room, may use that session (every `sessions/{id}` route, including `GET`).
   - partytracks does this with a JWT cookie. Here, the broker either keeps a server-side map, or returns a signed session token in `X-Realtime-Session-Token` that the client echoes on later calls.
   - The package supports echoing such a token (see the wire details above).
4. **Restrict pulls to the same room.** A `tracks/new` pull names another participant's `sessionId`. The broker must check that the session belongs to the same room. **Otherwise anyone with a valid login could subscribe to any room's media by guessing or learning a session ID.**
   - The same applies to every body that names a `sessionId`: `tracks/update` (reusing a transceiver for another publisher's track), `datachannels/new` and `datachannels/update` (subscriptions and `canReply`). The reference brokers check each `sessionId` found anywhere in any request body.
   - So the broker needs a **session store** (session → room, owner) even when it uses signed tokens: only the store knows another participant's room. The store must be readable from every broker instance within seconds of a write, because peers pull new sessions quickly.
5. Strip client-supplied headers that shouldn't reach Cloudflare: forward only `Authorization: Bearer <App Secret>` and `Content-Type`. Never log the App Secret, SDP bodies or tokens.

**Reference brokers** live in [`broker/`](../broker/README.md): a Cloudflare Worker (Durable Object session store, `jose` JWT auth) and a Supabase Edge Function (Postgres session store, Supabase JWT auth). They share a dependency-free TypeScript core in `broker/supabase/functions/_shared/broker-core/`, which is where the Supabase CLI can bundle it and where wrangler can import it too. Both ship a room-membership stub that fails closed; the app implements it.

## 6. Simulcast

- **Why it's mandatory.** Assume a 4-person call with a 720p camera at about 1.5 Mbps, and a 20% share of time spent screen sharing at about 2.5 Mbps.
  - Egress is about **2.25 GB per participant-hour** without simulcast.
  - It's about **0.75 GB** when receivers pull 360p in the gallery and 180p thumbnails during screen share.
- **Publish:** three encodings named so that **`a` is the highest**:
  - `a` = full resolution,
  - `b` = ½ (`scaleResolutionDownBy: 2`),
  - `c` = ¼.

  This lets subscribers use the SFU's `asciibetical` ordering, where 'a' is the most desirable.
- **Subscribe** (implemented in M4, §6.1):
  - Pick `preferredRid` from the rendered tile size: the stage gets `a`, a gallery tile `b`, a thumbnail `c`.
  - Change it with `tracks/update`.
  - Set `ridNotAvailable: "asciibetical"` so a subscriber falls back when a layer stops, for example when the publisher's CPU throttles. Every Room pull sends it (`LayerSelectionConfig.ridNotAvailable`), and `tracks/update` keeps it.
  - **`priorityOrdering` is left at the SFU default (`none`)**, so a subscriber gets exactly the layer the client chose. That keeps layer switching predictable for the week-6 checkpoint. `LayerSelectionConfig.priorityOrdering` opts in to `asciibetical` (the SFU may step down under bandwidth pressure). Revisit after measuring on constrained links.
- **Screen share:** **one layer by default** (decided for the week-6 checkpoint, §12 question 2): `ScreenSharePresets.detail`, the captured resolution at up to 15 fps and 2.5 Mbps, which is the 2.5 Mbps the egress estimate above assumes. `ScreenSharePresets.simulcast` adds a `b` layer (¼ size, 5 fps, 250 kbps) for apps that show shares as thumbnails; subscribers then pick by tile size as for cameras. Measure both on devices before 1.0.
- **Codec:** **default to VP8 on every platform**, for every video track including screen shares, via `setCodecPreferences` on the transceiver (`defaultVideoCodecPreferences()`, §4.2).
  - **Why everywhere, not only on Windows.** H.264 has crashed `flutter_webrtc` on Windows (flutter-webrtc #982). The SFU forwards what each publisher encodes, so in a mixed room a Windows subscriber would have to decode H.264 from a macOS or Android publisher whose platform prefers it. VP8 decodes on every platform, and its simulcast is well-trodden. The cost is giving up hardware H.264 encoding on some mobile devices.
  - Apps can opt out with `SfuSessionDefaults.videoCodecPreferences: const []` (the platform's order), or choose per publication. Revisit after the checkpoint's device runs show whether Windows decodes H.264 safely.

### 6.1 Layer selection

The building blocks are in `lib/src/quality/`; the Room wires them (M4, `lib/src/room/remote_track_layers.dart`). The Room owns one `LayerSelectionController` and hands it to the views as `Room.layerReporter`.

- **Publisher ladder** (`SimulcastLadder`, internal): the layers a publisher sends, highest first. `SimulcastLadder.fromPreset(VideoPreset.h720)` is `a`=1280×720, `b`=640×360, `c`=320×180.
  - **Encoder layer limit.** libwebrtc's legacy simulcast limit sends 3 layers from 960×540 up, 2 from 480×270 up, and otherwise 1. It drops the **lowest** layers, so a 360p publisher sends only `a` and `b`. The ladder applies this limit by default, so the policy never asks for a layer the publisher doesn't send.
  - This is an expectation, not a guarantee: capture can come out smaller than requested, and libwebrtc versions differ. `ridNotAvailable: asciibetical` covers the remaining mismatch. **Check it on devices.**
  - Publishers announce their layers in `TrackInfo.simulcast` (§4.4). The internal `simulcastLadderFor(info)` (`lib/src/room/simulcast_hint.dart`) turns that into a ladder (16:9 and 1/2/4 when not stated, with the encoder limit). A hint without a size is read as a 720p capture with the hint's rids. The Room sets each publication's ladder when it appears and again whenever its hint changes. Video without a hint gets no rid: only the hidden-view release below applies to it.
- **Demand** (`TileDemand`, public): the tile's size in **physical** pixels (logical size × device-pixel ratio), plus whether it is visible.
- **Policy** (`SimulcastLayerPolicy`, internal), for a visible `w×h` tile:
  1. **Required lines:** `max(h, w × layerHeight / layerWidth)`. This assumes the video fills the tile ("cover"), which errs towards quality.
  2. **Up:** the lowest layer with `height × maxUpscale ≥ required`, or the highest layer if none is big enough.
  3. **Down:** the same with `height × maxUpscale × (1 − downgradeHysteresis)`, which is stricter.
  4. With no current layer, take "up". Otherwise upgrade at once if "up" is higher, downgrade only if "down" is lower, and stay put in between.
  5. A hidden or empty tile is **paused**. The SFU has no pause for a pulled track, so the Room decides what paused means: switch to the lowest layer, or close the pull after it has stayed paused for a while.
- **Defaults** (`LayerSelectionConfig`, public): `maxUpscale` 1.5, `downgradeHysteresis` 0.15, `debounce` 300 ms, `ridNotAvailable` `asciibetical`, `priorityOrdering` unset.
  - With a 720p publisher, a tile up to 270 physical lines gets `c`, up to 540 gets `b`, and anything bigger gets `a`. So a 2×2 gallery on a 1080p screen pulls `b`, which is what the egress estimate above assumes.
  - Once on `a`, a tile drops to `b` only at 459 lines or fewer (540 × 0.85).
- **Aggregation and debounce** (`LayerSelectionController`, internal): one per Room, keyed by a subscription ID.
  - Several views of one track each report under their own key. Each view goes through the policy (with the subscription's current layer, for hysteresis), and the **highest** layer wins. With no visible view, the subscription is paused.
  - The **first** choice for a subscription (after its first view reports) is emitted at once, so a new pull starts with the right layer. So is a change from **paused to visible**, so video appears as soon as a tile scrolls into view.
  - Every other change waits until the new choice has stood for the debounce. A choice that reverts before then emits nothing.
- **Widget** (`SimulcastLayerReporter`, public): wraps a video view.
  - After each frame, it reports the child's laid-out size × `MediaQuery.devicePixelRatioOf`, and only when the demand changed.
  - The view counts as hidden when `visible` is `false` (the app knows about scrolling and tabs) or when `TickerMode` is off (a covered route).
  - It removes its view on dispose, and when its subscription ID or reporter changes.
  - It talks only to the `LayerDemandReporter` interface. `ParticipantVideoView.remote` uses it with `Room.layerReporter` by default.
- **In the Room** (M4):
  - **Target layer**, per remote video publication: the manual `setPreferredLayer` if set; else the controller's choice; else, while every view is hidden (paused), the ladder's lowest layer; else, before any view reported, `RoomOptions.defaultVideoLayer`. A new pull starts with it; a live pull is switched with `tracks/update` (failures are reported as `RoomErrorEvent('tracks/update')` and retried on the next change); a pull that is off its session only remembers it. After every (re)pull the target is applied again, so a change made while the pull was in flight is not lost.
  - **Hidden or paused tiles:** the track drops to its lowest layer as soon as the controller reports paused (after the debounce), and after `RoomOptions.hiddenVideoLinger` (default 5 s; `null` never) the pull is released: leases stop counting (`RemoteTrackLayerState.released`) and the pull is closed. A view that becomes visible again sooner just gets its layer back; one that does so later is pulled again at once, at its layer. This avoids pull/close churn when scrolling. An explicit `subscribe()` (or `AutoSubscribe.video`) keeps a hidden track pulled at its lowest layer.
  - **Lease grace:** see §4.3 (`RoomOptions.leaseReleaseGrace`, 500 ms).
  - **Manual override:** `RemoteTrackPublication.setPreferredLayer(layer)` wins until `clearPreferredLayer()` (or `setPreferredLayer(null)`); the automatic choice then applies again.
  - **Debug UIs:** `RemoteTrackPublication.currentRid` (the rid the live pull asks for), `layerState` and the replaying `layerChanges` (`RemoteTrackLayerState`: current and target rid, automatic rid, manual layer, hidden, released). The received resolution is in `Room.session.getStats()` (`inbound-rtp` `frameWidth`/`frameHeight` for the pull's `mid`), as the example's tile overlay shows.
  - Reports for tracks the room doesn't show as video (closed, audio, unknown IDs) are ignored.

## 7. Active speaker

- Poll `getStats()` for audio `inbound-rtp` / receiver `audioLevel`, every 200–500 ms.
- Smooth with a short window, and apply a threshold plus hold time so the speaker doesn't flicker.
- Include the local microphone level, so "you are speaking while muted" hints are possible.
- Emit an ordered list of participant IDs.

The building blocks are in `lib/src/quality/`; the Room wires them (M4, `lib/src/room/room_speakers.dart` and `room_audio_levels.dart`). Only `ActiveSpeakerConfig` (as `RoomOptions.activeSpeaker`) and the Room's outputs are public.

- **API** (M4):
  - `Room.activeSpeakers` (`Stream<List<String>>`, replaying) and `currentActiveSpeakers`; `Room.dominantSpeaker` (`Stream<String?>`) and `currentDominantSpeaker`.
  - `RemoteParticipant.isSpeaking`/`speakingChanges`, and `audioLevel`/`audioLevels` (smoothed, `0..1`, for meters).
  - `LocalParticipant.isSpeaking`/`speakingChanges`, and `isSpeakingWhileMuted`/`speakingWhileMutedChanges` with `canDetectSpeakingWhileMuted` (see below).
  - `RoomOptions.activeSpeaker` (default `ActiveSpeakerConfig()`); `null` turns detection off (no stats polls, empty outputs).
- **Room wiring:**
  - One `ActiveSpeakerMonitor` per room, started when the room joins and disposed on `leave()` (the poll timer stops before anything else).
  - **It polls for as long as the room is joined, not only while someone listens.** The synchronous getters must be right without a listener, and the detector's smoothing and hold times need a continuous series of samples; a listener-driven start would make the first seconds after subscribing wrong. The cost is one `getStats()` per poll, and **none while there is no audio to measure** (no microphone pulled and no local microphone sending).
  - **Levels** come from `RoomAudioLevelSource` over `SfuSession.getStats()`: remote `inbound-rtp` reports map to participants by `mid`, then `trackIdentifier`, through the room's microphone publications whose pull is on the current session (screen-share audio doesn't count). The local level is the `media-source` of the microphone's current track; without one (no microphone, or muted), local audio never counts, so screen-share audio can't make the local participant "speak".
  - **Session replacement (§8):** the source reads `Room._session` on every poll and rebuilds its stats reader when the session object changed, so energy baselines never mix two peer connections. `Room._onSessionReplaced()` (a private extension in `room_speakers.dart`) forces that at once: `Room._replaceSession` calls it. Nothing else is needed.
  - A participant who leaves is removed from the detector at once.

- **Levels** (`AudioLevelSource`; `StatsAudioLevelSource` reads a peer connection's `getStats()`):
  - **Remote:** audio `inbound-rtp` reports. The Room maps each report's `trackIdentifier`/`mid` to a participant. It returns `null` for streams that shouldn't count, such as screen-share audio. When several streams map to one participant, the loudest wins.
  - **Local:** audio `media-source` reports, under the local participant's ID. The Room can name the microphone track, so other audio sources don't count.
  - **The level** is the report's `audioLevel`. When that's missing, it's `sqrt(ΔtotalAudioEnergy / ΔtotalSamplesDuration)` between polls, which is the RMS of `audioLevel` per the W3C stats spec. A stream's first poll then has no reading, and a duration that didn't grow reads as 0.
  - **What `flutter_webrtc` 1.6.2 reports:**
    - Every platform returns W3C stats. Native platforms copy libwebrtc's members as they are.
    - Native libwebrtc has `audioLevel`, `totalAudioEnergy` and `totalSamplesDuration` on audio `inbound-rtp` and `media-source`, and `trackIdentifier` and `mid` on `inbound-rtp`. The legacy `track` stats type is gone.
    - Browsers vary (Firefox has lacked `audioLevel` on some types), which is what the energy fallback is for.
    - Report timestamps are µs on native and ms on the web, so they are never used.
- **Poller** (`ActiveSpeakerMonitor`):
  - It polls every `pollInterval`. Polls never overlap: a tick during a running poll is skipped.
  - A failed poll is skipped silently, since `getStats` can fail briefly during renegotiation.
  - It exposes `speakers`, `dominantSpeaker`, `localSpeakingWhileMuted` and `snapshots` (with smoothed levels, for meters). Each replays its current value.
- **Detector** (`ActiveSpeakerDetector`, pure Dart), per participant and per sample:
  1. **Smooth:** an exponential moving average with time constant τ: `level += (1 − e^(−Δt/τ)) × (raw − level)`. A participant missing from a sample counts as 0.
  2. **Start speaking** once the smoothed level has stayed ≥ `speakingThreshold` for `activationTime`.
  3. **Stop speaking** once it has stayed < `silenceThreshold` for `releaseTime`. The gap between the thresholds is the hysteresis; the release time bridges pauses between words.
  4. **Order** loudest first. Speakers keep their previous order and newcomers are appended by level. Then neighbours swap only when the lower one is louder by more than `reorderMargin`.
  5. **Dominant speaker:** the first speaker is dominant at once. A new loudest speaker takes over after staying loudest for `dominantSwitchTime`. A dominant speaker who falls silent stays dominant until someone else takes over, or leaves. The local participant can't be dominant unless `localCanBeDominant` is set.
  6. **Muted local participant:** left out of `speakers`, because nobody hears them. The same state machine, with `mutedActivationTime`, drives `localSpeakingWhileMuted` instead. Muting or unmuting restarts the local speaking state, so the hint doesn't pop up the moment someone mutes mid-sentence.
- **Defaults** (`ActiveSpeakerConfig`): poll every 250 ms, τ 300 ms, speaking threshold 0.04 (about −28 dBFS), silence threshold 0.02, activation 200 ms (two loud polls in a row), release 800 ms, reorder margin 0.02, dominant switch 1.5 s, local not dominant, muted-hint activation 500 ms.
- **The muted microphone's level: not supported yet** (`LocalParticipant.canDetectSpeakingWhileMuted` is `false`, and `isSpeakingWhileMuted` stays `false`).
  - With `MutePolicy.keepCapture` the mic keeps capturing, but muting is `replaceTrack(null)` on the sender (§4.2), and a sender without a track has no `media-source` report.
  - **`flutter_webrtc` 1.6.x has no other way to read a local track's level** (checked in 1.6.2+hotfix.3): `getStats(track)` only finds tracks attached to a sender or receiver, and the native audio sinks and processing hooks (`AudioProcessingAdapter`, `FlutterRTCAudioSink`) have no Dart API.
  - Options for later, each needing device checks: mute a `keepCapture` microphone with `track.enabled = false` and keep it on the sender (native libwebrtc appears to measure the `media-source` level before the send-side mute, but that changes the mute model of §4.5); a second, local-only peer connection that sends the captured track (costly); on the web, a Web Audio `AnalyserNode` on the track.

## 8. Reconnection

Cloudflare's guidance is to **replace the connection**: create a new session and re-push and re-pull. ICE restart isn't documented for the SFU.

- **Triggers:**
  - `RTCPeerConnectionState.failed`, or `disconnected` for more than N seconds;
  - network-change events;
  - the mobile app returning to the foreground after the OS killed sockets;
  - broker errors that mean the session is gone. The SFU returns HTTP `410` with `session_error` for an expired session. An unconnected session can expire before its first track or DataChannel operation.
- **Procedure:**
  1. Create a new session.
  2. Re-push the current local tracks with the same `trackName`s.
  3. Update signaling with the new `sessionId`.
  4. Remote peers see the `sessionId` change and re-pull.
  5. Re-pull our own subscriptions from peers' current sessions.
- **Backoff:** exponential with jitter. Expose `reconnecting` and `reconnected` states.
- **Don't lose local capture.** Keep the `MediaStreamTrack`s and only replace the transport.

The building blocks are in `lib/src/reconnect/`. They are pure decision logic, with no timers or I/O; the Room wires them up (below). `BackoffConfig`, `ReconnectTriggerConfig` and `ReconnectReason` are public.

- **`Backoff`** (internal) covers one reconnection episode.
  - The delay before attempt `n` (0-based) is uniform in `[0, min(maxDelay, initialDelay × multiplier^n)]`. This is exponential backoff with **full jitter**, so clients that dropped together don't come back together.
  - `nextDelay()` returns `null` once `maxAttempts` delays have been handed out, or once `maxElapsed` has passed since the episode's first attempt.
  - `reset()` after a successful reconnection starts a fresh episode.
  - The random source and the clock are injectable. The default clock is `package:clock`'s stopwatch, so `fake_async` drives it; `Backoff.debugDefaultRandom` (tests only) makes the jitter deterministic.
  - **Defaults** (`BackoffConfig`): initial 500 ms, ×2, cap 10 s, no attempt limit, give up after 2 minutes.
- **`ReconnectTrigger`** (internal) decides *when* to re-session. The caller feeds it events with a monotonic timestamp, schedules a timer for `nextCheckAt`, and calls `check` when it fires. Every input returns a `ReconnectReason` when it decides to reconnect.
  - `failed` triggers at once.
  - `disconnected` triggers after `disconnectedTimeout`, or at once if a network change happened within `networkChangeWindow` before it.
  - A network change **while disconnected** triggers at once. While connected, it only arms that window, because platforms report changes that don't break the connection (a second interface coming up).
  - `new`/`connecting` for longer than `connectTimeout` triggers.
  - Resuming after at least `backgroundThreshold` in the background triggers, because the OS may have killed the sockets while the peer connection still says `connected`. Resuming also runs `check`, since timers may not have run while suspended.
  - `sessionGone` (a `SessionGoneException`: 410 or `session_error`) triggers at once.
  - `closed` clears the timers, because the package closed the connection itself.
  - Once triggered, it ignores input until `reset()`, so one outage causes one re-session. `reset()` keeps the background state.
  - **Defaults** (`ReconnectTriggerConfig`): disconnected timeout 5 s, connect timeout 15 s, network-change window 10 s, background threshold 30 s.

### 8.1 The Room's re-session (M5)

Implemented in `lib/src/room/room_reconnection.dart` (`_Reconnection`, a part of the room library). On by default; `RoomOptions.reconnect` (`ReconnectOptions`) tunes it and `ReconnectOptions.disabled` turns the automatic part off.

- **Inputs** feed one `ReconnectTrigger` per room:
  - the current session's `connectionState` (`initial` is left out, so an idle session with nothing negotiated never hits the connect timeout; `failed` comes from `failures` instead, which knows the reason) and its `failures`: `SfuSessionGone` → `sessionGone`, `SfuPeerConnectionFailed` → `peerConnectionFailed`. The session's own ICE timeout (7 s) and the trigger's `disconnected` timeout (5 s) overlap; whichever fires first wins.
  - **Network changes** from a `NetworkChangeSource` passed to `CloudflareRealtime(networkChanges:)`. **None by default:** the core package takes no connectivity plugin. The example app polls `NetworkInterface.list()` every 2 s and reports a change when the set of addresses changes (no native plugin to break the checkpoint builds on Windows, macOS and Android); apps that use `connectivity_plus` can wrap `onConnectivityChanged` in a few lines.
  - **The app lifecycle** from an `AppLifecycleSource` (`CloudflareRealtime(appLifecycle:)`), by default `FlutterAppLifecycleSource`: one `AppLifecycleListener` per room; `paused` and `resumed` count. Without a Flutter binding it emits nothing.
  - Time comes from `package:clock`, so tests drive it with `fake_async`.
- **Episodes.** A trigger starts an episode: `reconnecting` plus `RoomReconnectingEvent(reason)`. Each attempt waits its backoff delay first (full jitter, so clients that dropped together spread out; `Room.reconnect()` skips the first wait), then:
  1. connects a new session through the room's connector (`CloudflareRealtime(connectSession:)`, the same one `join` used), while the old one carries on if it still works;
  2. **switches** to it in one operation, `Room._replaceSession` (below), and closes the old session quietly. **Deviation from the task order** (close the old session last): a `LocalTrackPublication` lives on one session at a time and `republish` needs it detached, so the old session is closed right after the new one exists; for a failed session that only releases its peer connection;
  3. republishes every local track (`SfuSession.republish`: same `trackName`, the same `MediaStreamTrack`, current encodings; capture is never touched) and every DataChannel published through `room.data` (`republishDataChannel`). The DataChannels go here rather than with the subscriptions, so peers that follow the new session find them;
  4. announces the local state with the new `sessionId` (announcements are held from the start of the attempt, so the old ID with half-moved tracks is never announced). A failing `Signaling.update` is reported as `RoomErrorEvent('signaling.update')` and retried with the same backoff schedule; if that runs out, the attempt fails;
  5. pulls every wanted remote track again from the publisher's *current* session (each `RemoteTrackPublication` reconciles: an interrupted subscription moves with `resubscribe`), and moves every `RemoteDataSubscription` (`resubscribeDataChannel`, or a fresh subscribe);
  6. waits while the new peer connection is `connecting`, until it connects or a trigger fires (the connect timeout, 15 s). If tracks or DataChannels were negotiated on it, a peer connection still `new` is waited for too (its states arrive asynchronously, so right after the negotiation it often is), with the connect timeout armed for it; otherwise the room would show `connected`, then `connecting`, then `connected` again. With nothing negotiated, `new` is final and the room is `connected` at once.

  Then `connected` and `RoomReconnectedEvent(reason, duration, attempts)`.
- **Failures inside an attempt.** A new session that can't be created, fails, is reported gone, or doesn't connect makes the attempt fail: it is closed, a `RoomErrorEvent('reconnect')` is emitted, and the next attempt follows its backoff delay. A per-track (`SfuTrackException`) or per-channel rejection doesn't fail the attempt: it is reported, the track stays `failed` and isn't announced (`LocalParticipant.state` leaves it out), and the next re-session tries it again. Remote pulls that fail keep their own retries (`RoomOptions.pullRetry`).
- **Giving up.** When the backoff runs out (default: after 2 minutes), the room is `disconnected` with `RoomReconnectFailedEvent(reason, attempts, error)`. It stays in signaling (with its last session ID) and usable: `leave()` works, `Room.reconnect()` starts again with a fresh budget, and a network change or a return to the foreground also starts again. Automatic triggers don't, so a dead network doesn't loop.
- **One at a time.** Triggers during an episode coalesce into it: one about the attempt's own new session fails that attempt; a network change or a return to the foreground cuts a backoff wait short; `Room.reconnect()` returns the running episode (skipping its current wait).
- **Flapping.** The backoff starts over only after the new session has lasted `ReconnectOptions.stablePeriod` (10 s). A session that breaks sooner continues the schedule, so a connection that keeps dropping backs off and eventually gives up instead of re-sessioning in a tight loop.
- **`leave()` during an episode** stops it at the next step: a backoff wait ends at once, a session still connecting is closed when it arrives and never becomes the room's, and nothing is announced.
- **While reconnecting**, `LocalParticipant.publish*` and `room.data.publish`/`subscribe` wait for the episode and then run on the new session. A publish already in flight when the session fails throws.
- **Other participants' reconnections** are M3's path (§4.3): their new `sessionId` in signaling closes the pull on the old session and pulls from the new one at once. Pulls that fail meanwhile back off (`pullRetry`, 8 attempts in 1 minute), and pulls are never attempted on our own dead session (no retry timers while it is unusable; the re-session pulls everything once).
- **Session-bound components.** `Room._replaceSession(next)` is the only place `Room.session` changes: it stops following the old session, follows `next`, and calls `_onSessionReplaced()` (active speaker re-binds its stats reader). It runs when the new session exists, before tracks move onto it. Layer selection needs nothing: the chosen rid is re-applied after every pull.
- **Defaults** (`ReconnectOptions`): enabled; `backoff` = `BackoffConfig()` (≤ 500 ms, ×2, cap 10 s, give up after 2 minutes); `trigger` = `ReconnectTriggerConfig()` (disconnected 5 s, connect 15 s, network-change window 10 s, background 30 s); `stablePeriod` 10 s.
- **Demo and tests.** `Room.debugSimulateConnectionFailure()` fails the current session as a network drop would (`PeerConnectionFailureKind.simulated`, peer connection closed), so the whole path above runs; the example app's call screen has a "simulate network drop" button. `example/integration_test/reconnect_test.dart` drops the publisher, then the subscriber, against a real broker and checks the track is received again each time.
- **Open:**
  - **A pull from a publisher's session that is gone.** Handled since the post-M5 hardening: a `SessionGoneException` from a pull (or a remote DataChannel subscribe) is checked against our own session (`GET sessions/{ownId}`) before failing it (§4.2), so a peer's stale session in signaling makes that pull back off instead of re-sessioning the subscriber again and again. What the real SFU returns in that case (a request-level `session_error` or a per-track error) is still to be confirmed against it; both paths now end in a per-track error.
  - **Mobile background.** The trigger re-sessions after a long background, but keeping a call alive in the background (iOS audio background mode, `beginBackgroundTask`/CallKit, an Android foreground service) is platform setup for M6/M8.
  - The first attempt after a failure waits up to `initialDelay` (jitter). A shorter first delay would recover faster from a lone drop; keep the jitter for synchronized drops.

## 9. DataChannels

Implemented (M7) at the session level in `lib/src/data/`, with the operations on `SfuSession`. `Room` exposes it as `room.data`, which maps senders to participants (§4.3). partytracks has no DataChannel support to port; the negotiation follows Cloudflare's DataChannels docs, the OpenAPI schema and Cloudflare's `echo-datachannels` example, and the queueing and lifecycle mirror the track code.

- The SFU forwards DataChannels **from a publisher to its subscribers**.
  - `datachannels/establish` sets up the SCTP transport.
  - `datachannels/new` with `location: "local"` publishes a named channel. With `location: "remote"` plus the publisher's `sessionId`, it subscribes.
  - A subscriber created with `canReply: true` can send back on the publisher's channel. **Only one subscriber can do this**; granting it to another replaces the previous one. For general two-way traffic, both sides publish.
  - Channels are **negotiated**. The SFU returns a channel `id`, and the client calls `createDataChannel(name, negotiated: true, id: id)`. The publisher's and subscriber's IDs can differ.
- **Offer two profiles** (`DataChannelProfile`):
  - **reliable**: ordered, retransmitted (omit `maxRetransmits` and `maxPacketLifeTime`). For keys, clicks, chat and control messages.
  - **unreliable**: `ordered: false`, `maxRetransmits: 0`. For high-rate data such as mouse moves.
  - The SFU requires every subscriber to **mirror the publisher's policy**, in its request and its own channel, so `subscribeDataChannel` takes the profile too. `maxPacketLifeTime` isn't offered: `flutter_webrtc`'s native plugins ignore it.
- **Sender identity comes from the channel's `sessionId`, never from the payload.**
  - The app maps `sessionId` → user through its (server-verified) signaling.
  - The package exposes the remote `sessionId` for each channel, so apps can do this. Remote control depends on it.

**API** (exported from the barrel):

```dart
final input = await session.publishDataChannel('input', profile: DataChannelProfile.unreliable);
await input.whenOpen();
await input.send(bytes);                  // or sendText; StateError unless open
input.bufferedAmount;                     // backpressure
input.bufferedAmountLowThreshold = 64 * 1024;
input.bufferedAmountLow.listen((_) => resume());

final sub = await session.subscribeDataChannel(remoteSessionId, 'input',
    profile: DataChannelProfile.unreliable, canReply: false);
sub.messages.listen((m) { m.fromSessionId; m.isBinary ? m.binary : m.text; });
await sub.setCanReply(true);              // datachannels/update

sub.state; sub.states;                    // SfuDataChannelState: pending/connecting/open/interrupted/failed/closed
await sub.close();                        // datachannels/close
await session.republishDataChannel(input); await session.resubscribeDataChannel(sub, remoteSessionId: newId);
```

- **Negotiation sequence**, run lazily inside the first DataChannel operation on a session, through the session's op queue:
  1. `POST datachannels/establish` with `{"dataChannel": {"location": "remote", "dataChannelName": "server-events"}}` and **no offer**. No local channel has to exist first (the alternative, sending our own offer, needs one to get an `application` m-line).
  2. The SFU answers with `requiresImmediateRenegotiation` and an offer carrying the `application` m-line. Its `server-events` channel (ID 0) is opened in-band by the SFU; the package ignores it.
  3. `setRemoteDescription(offer)`, `createAnswer`, `setLocalDescription`, `PUT renegotiate` (the same path a pull uses).
  4. Then `datachannels/new`; each result's `id` becomes `createDataChannel(name, negotiated: true, id, ordered, maxRetransmits)`. There is no wait for the connection: the channel opens when the SCTP association is up (`connecting` → `open`).

  A failed establish fails that batch and is retried by the next publish or subscribe. Later offers (pushes, closes) carry the `application` m-line automatically.
- **Batching and errors.** As with tracks: publishes and subscribes in one event-loop turn become one `datachannels/new` each (local and remote kept apart, like `tracks/new`); `canReply` updates one `datachannels/update` (the last value per channel wins); closes one `datachannels/close` by `id`. A per-channel error or a missing `id` fails only that channel with `SfuDataChannelException`; a request-level `errorCode` fails the batch with `SfuRequestException`; `SessionGoneException` fails the session (for a subscribe, only after `GET sessions/{ownId}` confirms our session is gone; otherwise just the batch's channels fail, §4.2). If creating the local channel fails, or the channel was closed while its request was in flight, the SFU's `id` is released again with `datachannels/close`, best effort. Names are unique per session, and `server-events` is reserved.
- **Messages.** `DataChannelMessage` carries `binary` or `text`, and `fromSessionId`: the publisher's session for a `RemoteDataChannel`, captured when that underlying channel was opened (so late messages from an old session keep the old ID after a resubscribe). On a `LocalDataChannel`, received messages are replies from the one `canReply` subscriber, which the SFU doesn't identify, so `fromSessionId` is null. `messages` is a broadcast stream that survives moves between sessions.
- **Lifecycle.** A channel outlives its session, like a track publication. When the session fails or closes, channels become `interrupted` and their underlying channels are closed; the Room's re-session moves them with `republishDataChannel` / `resubscribeDataChannel` (§8) (which re-establish on the new session). If the underlying channel closes without `close()` (the SFU or the other end dropped it), the channel becomes `interrupted` too, and its SFU `id` is released. `close()` is immediate and terminal locally; on a dead session it makes no SFU call.
- **Backpressure.** `bufferedAmount` plus an edge-triggered `bufferedAmountLow` stream. Native `flutter_webrtc` reports every buffered-amount change (and fires its low callback on each change below the threshold), so the wrapper detects the crossing itself; on the web the browser's `bufferedamountlow` is used. On native platforms `bufferedAmount` is the last value reported, so it lags slightly.
- **`flutter_webrtc` realities** (1.6.2+hotfix.3):
  - `RTCDataChannelInit.toMap()` drops `maxRetransmits: 0` (it only sends positive values), which would silently make the unreliable profile reliable on native platforms. The wrapper overrides `toMap()`; Android, Darwin and the C++ desktop plugin all apply the key when present.
  - **Web:** `dart_webrtc` drops `maxRetransmits: 0` too and doesn't use `toMap()`, so a browser endpoint of an unreliable channel sends unordered but retransmitted. Needs an upstream fix.
  - Binary messages are requested as `ArrayBuffer` on the web (`binaryType: 'binary'`); the default `Blob` is decoded asynchronously and can reorder messages.
  - **Windows and Android never report a negotiated channel as open.** The Dart channel's state stays null although the channel works (messages flow both ways). The likely cause: the plugin registers its observer only after libwebrtc has created the channel, and a negotiated channel on an already connected SCTP transport opens during creation, so the `open` event is never sent. `getStats()` does report it (`data-channel` with `dataChannelIdentifier` and `state: open`). So on native platforms the wrapper polls the stats while the state is unknown or `connecting` (20 ms doubling to 1 s) and reports `open` once they say so; a platform state event always wins and stops the polling. Found against the real SFU on Windows, where every channel stayed `connecting` and `whenOpen()` never completed. Android (a Pixel on Android 16) behaves the same: its plugin also registers the observer after creation, and the Dart side subscribes to the channel's event stream later still. No platform `open` event arrived there in any run; the first stats probe (20 ms) reported each channel open.
  - **Closing order.** On Windows, `RTCPeerConnection.close()` makes the plugin forget the connection, and `dispose()` then fails to close the channels (`dataChannelClose() peerConnection is null`), leaking their native observers. The wrapper closes its channels (including the SFU's `server-events`) before closing the connection.
- **Not done:** `waitForAck` (hold delivery until the subscriber acks) and a reply-sender identity for `canReply` traffic; neither is needed by the first consumer.

## 10. Screen share by platform

| | Full display | Single window | Covered window | Minimized window | Cursor | System audio |
|---|---|---|---|---|---|---|
| **Windows** | Yes: `desktopCapturer.getSources([screen, window])` with thumbnails (DXGI Desktop Duplication) | Yes | Crops the screen while the window is on top. Falls back to GDI when covered, which may show the covering content, or black for GPU-rendered apps | No frames | Composited (no toggle) | **No** (#1952) |
| **macOS** | Yes (ScreenCaptureKit) | Yes | Still captured | No frames | Composited | **No** |
| **Web** | The browser's picker decides | Yes | Browser-dependent | Chrome: no frames | `cursor` constraint | Tab audio only |
| **iOS** | Needs a Broadcast Upload Extension **in the host app** | n/a | | | | |
| **Android** | MediaProjection plus a foreground service of type `mediaProjection` **in the host app** | n/a | | | | |

- Document the iOS and Android host-app setup in the README, and show it in the example app. **Not done yet** (M6): on Android and iOS, `ScreenShareSource.start` throws `UnsupportedError` and says what's missing.
- **Implemented (desktop and web), end to end (M6):** `ScreenSourcePicker` and `ScreenShareSource` in `lib/src/media/`; publishing, ending and the no-frames check in the Room (§4.3); encoding in §6 and §12, question 2. The example app's call screen has "Share screen" / "Stop sharing" with a picker dialog (text, motion or text + thumbnail layer; audio where the platform captures it), and puts a remote share on the stage with `contain` fit.
  - **The picker** lists screens and windows with thumbnails through `desktopCapturer.getSources`, screens first.
    - The plugin reports changes only while someone calls `updateSources`. So the picker re-scans every 3 s (configurable), like the `flutter_webrtc` example, and applies added, removed, renamed and new-thumbnail events.
    - On Windows the first listing has no thumbnails; the first re-scan, which runs immediately, brings them. On macOS they arrive as source events *during* the listing, and the listing's result (without thumbnails) would replace them, so the picker keeps each source's last thumbnail across listings. An empty thumbnail (macOS sends one when it can't capture) reads as none. macOS thumbnails are TIFF, which Flutter's image codecs may not decode, so UIs need an `errorBuilder` (the example has one).
    - The plugin keeps a single global source list, so run one picker at a time.
  - **Desktop capture** uses `getDisplayMedia({video: {deviceId: {exact: id}, mandatory: {frameRate}}, audio})`, as in the `flutter_webrtc` desktop example. The default frame rate is 15 (M6; it was 30): enough for text, see §12 question 2.
  - **Web capture** uses `getDisplayMedia` and the browser's picker. A cancelled picker returns `false`; it isn't an error.
  - **Ending a share** is surfaced on `ended` with a `ScreenShareEndReason`:
    - `stopped`: the app stopped it.
    - `userStopped`: the browser's "Stop sharing" button fired the track's `onEnded`.
    - `sourceClosed`: the shared window or display went away. Native tracks never fire `onEnded`, so while sharing, the desktop source re-scans the source list and ends the share on `onRemoved` for its source.
  - **Switching sources** releases the old capture before starting the new one. On Windows, stopping any desktop capturer also stops the single loopback-audio capturer.
  - **Windows listing failures** (#1539, #1085) are data, not crashes:
    - `getSources` errors, or a list with no screens, become `ScreenPickerState.error` (`ScreenSourcesException`). The picker retries once at once, and `refresh()` retries again.
    - "source not found!" from `getDisplayMedia` means the plugin's list was stale. The share rebuilds it with `getSources` and retries once, then reports `ScreenSourceNotFoundException`. macOS answers `{error: "No source found for id: …"}` instead of throwing, which `flutter_webrtc` 1.6 misreads as a `TypeError` (a null `streamId`); on macOS that `TypeError` takes the same path.
- **macOS Screen Recording permission (TCC).** Capturing needs the user's permission (System Settings → Privacy & Security → Screen & System Audio Recording; "Screen Recording" before macOS 15). There is no entitlement or `Info.plist` key for it (the sandboxed example needs nothing beyond its camera, microphone and network entitlements); macOS prompts on the first capture, and a newly granted permission applies only after the app restarts. A rebuilt, ad-hoc-signed debug app can count as a new app and be asked again. `flutter_webrtc` 1.6 neither asks for it nor reports it: `getDisplayMedia` still returns a live track, and ScreenCaptureKit fails to start in the background (it only logs). So the package watches for symptoms and reports a `ScreenCapturePermissionException` (a `MediaPermissionDeniedException`, `suspected: true`, with `guidance` to show):
  - **in the picker:** `ScreenPickerState.permissionProblem` when a listing has no screens, or every screen's thumbnail is empty or black (`thumbnailLooksBlank`, internal: it reads uncompressed 8-bit TIFF; other formats count as unknown). It clears once a listing looks normal. macOS only.
  - **after sharing:** `LocalScreenShareStalledEvent` when the share sends no frames (§4.3).
  - Which symptom a denied permission shows (empty, black or wallpaper-only thumbnails; no windows) depends on the macOS version and needs checking on devices; the no-frames check is the reliable one. A native `CGPreflightScreenCaptureAccess()` call would be exact, but the core package has no native code.
- **Correction to the table:** since `flutter_webrtc` 1.5.0 (#2060), Windows can capture system audio via loopback, with `ScreenShareOptions(captureAudio: true)`. It arrives as `ScreenShareSource.audioTrack`. Whether it's good enough to replace the "No (#1952)" cell needs device testing.
- **Known `flutter_webrtc` issues to plan around:**
  - Windows HDR screens look washed out; WGC capture is requested (#2205).
  - Windows sometimes fails to list sources (#1539, #1085); handled as above.
  - There's no hardware-encoder selection on Windows (#2200).
  - The macOS 14+ system picker exists only in Stream's fork.

## 11. Public API sketch

The room API is implemented (M3, §4.3), with layer selection and active speaker (M4, §6.1, §7) and automatic re-sessioning (M5, §8). Not a frozen contract before M8.

```dart
final rt = CloudflareRealtime(
  broker: BrokerConfig(
    baseUrl: Uri.parse('https://api.example.com/realtime'),
    headers: () async => {'Authorization': 'Bearer ${await getAppJwt()}'},
  ),
);

final room = await rt.join(
  'room-123',
  signaling: mySignaling,             // app-provided Signaling
  participantId: currentUserId,
  metadata: {'displayName': 'Ada'},
  options: const RoomOptions(
    autoSubscribe: AutoSubscribe(audio: true, video: false),
    // Defaults: hide-to-release after 5 s, 500 ms lease grace, 250 ms speaker polls.
    hiddenVideoLinger: Duration(seconds: 5),
    leaseReleaseGrace: Duration(milliseconds: 500),
    activeSpeaker: ActiveSpeakerConfig(),
    reconnect: ReconnectOptions(),     // the default: re-session automatically (§8)
  ),
);

final local = room.localParticipant;
final mic = await local.publishMicrophone();
final cam = await local.publishCamera(encodings: SimulcastPresets.h720);   // the default; [] = no simulcast
final share = await local.publishScreen(source: pickedSource);  // a ScreenSource from ScreenSourcePicker; none on web
                                       // one 15 fps layer (ScreenSharePresets.detail); .motion / .simulcast
await mic.mute(); await mic.unmute();  // announced as TrackInfo.muted
await cam.unpublish();

room.participants;                     // Stream<List<RemoteParticipant>> (+ currentParticipants)
room.events;                           // Stream<RoomEvent>: joined/left/updated, track published/muted/subscribed, ...
room.connectionState;                  // Stream<RoomConnectionState>: connecting/connected/reconnecting/disconnected
room.activeSpeakers;                   // Stream<List<String>>, loudest first (+ currentActiveSpeakers)
room.dominantSpeaker;                  // Stream<String?>: who goes on the stage (+ currentDominantSpeaker)
room.layerReporter;                    // LayerDemandReporter: views report their size here
room.session;                          // the current SfuSession: replaced by a re-session
room.audioPlaybackBlocked;             // web autoplay policy (+ audioPlaybackBlockedChanges); false on native
await room.startAudio();               // from a user gesture: play the blocked remote audio
await room.reconnect();                // re-session now (e.g. a "Reconnect" button after giving up)

final remote = room.currentParticipants.first;
remote.microphone?.muted;              // camera / microphone / screen / screenAudio, trackPublications
await remote.camera?.subscribe();      // pull on demand; or ParticipantVideoView.remote(remote.camera!)
await remote.camera?.setPreferredLayer(SimulcastLayer.low);   // overrides the automatic layer
await remote.camera?.clearPreferredLayer();                    // back to automatic
remote.camera?.currentRid;             // the rid asked for; layerState / layerChanges for debug UIs
remote.camera?.track;                  // Stream<RenderableTrack?>: track + MediaStream for RTCVideoRenderer
remote.isSpeaking; remote.speakingChanges; remote.audioLevel;
local.isSpeaking; local.speakingChanges;

ParticipantVideoView.remote(remote.camera!, visible: onScreen);  // subscribes while mounted, picks its layer
ParticipantVideoView.local(cam.mediaSource);                           // mirrored self-view

final input = await room.data.publish('input', profile: DataChannelProfile.unreliable);
await input.whenOpen();
await input.send(bytes);
final sub = await room.data.subscribe(remote, 'input', profile: DataChannelProfile.unreliable);
sub.messages.listen((msg) { /* msg.participantId, from signaling, never the payload */ });

await room.leave();
```

- **Style.** partytracks uses Observables deliberately: repair logic (a replaced device or connection) stays inside the library, and consumers just see the new track. **Mirror that with Dart `Stream`s.** No `rxdart` (§12, question 1): where partytracks needs `BehaviorSubject`-style replay of the latest value, the package uses its internal `StateStream<T>` helper (`lib/src/util/`).

## 12. Open questions

1. ~~`rxdart`, or plain `Stream`/`StreamController`?~~ **Resolved:** plain `Stream`s, plus an internal `StateStream<T>` helper for replay-latest state. This means fewer dependencies for pub.dev consumers, and the replay-latest semantics we need are small.
2. ~~Screen share: simulcast or a single layer?~~ **Decided for the checkpoint (M6): a single layer by default, simulcast as an option.** `publishScreen` sends `ScreenSharePresets.detail` (captured resolution, ≤ 15 fps, ≤ 2.5 Mbps; captured at 15 fps) unless given `encodings`; `ScreenSharePresets.motion` (≤ 30 fps, ≤ 4 Mbps) suits video, and `ScreenSharePresets.simulcast` adds a quarter-size 5 fps layer. Why: a share is usually what everyone watches, on the stage and at full size, so a thumbnail layer mostly costs the sharer's upload and encoder; text needs resolution more than frames, so the frame rate is low and the bits per frame high. The encoder can't be told "this is text": `flutter_webrtc` 1.6 has no `MediaStreamTrack.contentHint` on any platform (and doesn't expose `degradationPreference` through our session wrapper yet; `maintain-resolution` would be the setting for shares). macOS marks desktop capture as a screencast (`videoSourceForScreenCast:YES`), which libwebrtc treats as screen content. **Still to measure on devices:** legibility at 1080p and 4K, and what libwebrtc makes of the simulcast preset's low layer for screencast sources (it may shape screenshare simulcast its own way).
3. Package split: a core package plus separate adapter packages (Supabase, in-memory), or adapters as examples only?
4. Minimum Dart/Flutter SDK for pub.dev. The scaffold pins `^3.13.0`; widen it before publishing if `flutter_webrtc` allows.
5. Naming and trademark: the package is **unofficial**. Keep the disclaimer in the README and pubspec description.
