# Design: `cloudflare_realtime`

This package is a Flutter client for the [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/). It is built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) and targets **Android, iOS, macOS, Windows and Web**.

- **Status:** pre-release. Implemented so far: the broker client (§4.1), the SFU session (§4.2) with DataChannels (§9), the `Signaling` interface with its in-memory implementation (§4.4), the media layer: devices, local camera/microphone/screen capture and the desktop screen-source picker (§4.5, §10), and the pure-logic building blocks for layer selection (§6.1), active speaker (§7) and reconnection (§8), not yet wired to a room. The rest is design.
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
- **Errors.** A failed call throws a `BrokerException` carrying the status, `errorCode` and `errorDescription`. Subclasses: `BrokerUnauthorizedException` (401), `BrokerForbiddenException` (403), `SessionGoneException` (410, or `errorCode: session_error` at any status; M5 re-sessions on it), `BrokerNetworkException`, `BrokerTimeoutException` and `BrokerProtocolException` (an unparseable 2xx).
  - A 2xx response with a request-level `errorCode` is **returned**, not thrown, so per-track results aren't lost; check `hasError` on the response and on each track or DataChannel result.
  - The client never logs. Exception messages never contain SDP, header values or tokens.
- **ICE servers.** `getIceServers()` returns maps ready for `flutter_webrtc`'s `iceServers`, **one map per URL** with a string `urls`: `flutter_webrtc`'s Windows implementation keeps only the last entry of a `urls` array.
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

  **Mute and device changes.** partytracks keeps sending a black or silent placeholder track while muted; `flutter_webrtc` can't make those, so the media layer's `broadcastTrack` is null while muted. `replaceTrack(null)` therefore stops sending without renegotiating: the transceiver and `mid` stay, and unmuting is another `replaceTrack`. Replacements are applied in order and settle on the latest track. `publishTrackStream(tracks, kind:)` follows such a stream (partytracks' `push(track$)`): it pushes whatever the stream holds when the push goes out (possibly nothing: the transceiver is then created from `kind`), and applies every later value. The session code takes plain `MediaStreamTrack`s and doesn't import the media layer. **Deviation:** partytracks adds the transceiver when `push` is called; here it is added inside the queued operation, so an unrelated offer in flight never carries an undeclared m-line.

  partytracks emits a pushed track's metadata only once the sender reports `bytesSent > 0`, so peers don't pull too early. Here `publish` completes when the SFU accepts the track, and `whenSending()` ports the wait (stats polled from 1 ms, ×1.1, capped at 100 ms). Room (M3) should advertise a track only after it. A publication muted from the start sends no RTP, so `whenSending()` waits until it is unmuted; M3 must decide whether to advertise muted tracks earlier.
- **Encodings and codecs.**
  - Video defaults to `SimulcastPresets.h720`: rids `a` (full, 1.2 Mbps), `b` (`scaleResolutionDownBy: 2`, 400 kbps), `c` (4, 150 kbps). `h1080` and `h360` exist too; M4 tunes the numbers. `sendEncodings: []` publishes one default encoding. Audio has none.
  - Codec preferences are MIME types; set, they **restrict** the transceiver to those codecs plus rtx/red/ulpfec/flexfec, so the SFU can't pick another. The default is `['video/VP8']` on Windows (flutter-webrtc #982) and none elsewhere (`SfuSessionDefaults.videoCodecPreferences` overrides it). A platform that rejects `setCodecPreferences` keeps its default order.
- **Pull** (subscribe to remote tracks):
  1. `POST tracks/new` with `tracks: [{location: "remote", sessionId, trackName, simulcast?}]`. `simulcast` is sent only with a `preferredRid`; `ridNotAvailable` then defaults to `asciibetical`, and `priorityOrdering` is left to the SFU default (`none`) unless given (§6).
  2. If the response has `requiresImmediateRenegotiation`, then `setRemoteDescription(offer)`, `createAnswer`, `setLocalDescription`, and `PUT renegotiate` with the answer.
  3. Map the returned `mid` to the transceiver, which gives you the remote track. Results are matched by `trackName` + `sessionId`, as in partytracks. The transceiver is looked up after renegotiation, waiting up to 5 s for its `track` event (partytracks' `resolveTransceiver`).
- **Update:** `PUT tracks/update` with the pulled track's `mid` and its full `simulcast` object (keeping the orderings). Updates are batched too, and the last `rid` per subscription in a batch wins. On a subscription that isn't active, the rid is only remembered for the next pull. partytracks fires updates outside its queue; here they are queued.
- **Close:** stop the transceivers, `createOffer`, `setLocalDescription`, `PUT tracks/close` with the `mid`s and the offer (`force: false`), then apply the answer, or renegotiate if the response asks for it. `close_track_error` counts as closed. The publication or subscription is closed locally even if the request fails. On a failed or closed session, only local state changes (partytracks also skips negotiation on a dead connection). Local `MediaStreamTrack`s are never stopped: capture belongs to the app.
- **All operations run through one serialized queue** (`OpQueue`, a port of `FIFOScheduler`). The SFU requires each SDP exchange to finish before the next mutation on the same session.
  - Pushes, pulls, updates and closes that arrive in the same event-loop turn are each batched into one request (`BatchDispatcher`, a port of `BulkRequestDispatcher`: a zero-duration timer, at most 32 items per batch). A push batch and a pull batch in the same turn become two requests, run one after the other (one `tracks/new` is all local or all remote).
  - A failing operation fails only its own items; the queue moves on.
  - **The queue heals the signaling state.** A push or close that fails after `setLocalDescription(offer)` (broker error, request-level `errorCode`, no answer) would leave `have-local-offer`; a failure after applying an SFU offer leaves `have-remote-offer`. Either would make the next exchange fail. So after any failed operation, and before each one, the queue checks the signaling state and rolls back (`{type: rollback}` through `setLocalDescription` or `setRemoteDescription`) to `stable`. If the rollback fails or isn't supported on a platform, the session fails with `PeerConnectionFailureKind.signalingStuck`, so M5 replaces it instead of it staying wedged. partytracks doesn't do this; it relies on re-creating the whole session.
  - Cleanup runs inside the queue before an operation's futures complete: the transceivers of failed pushes (a whole-request failure, a per-track error or a missing `mid`) are stopped, so later offers leave them out (or reject them with port 0), and the publication drops them; a `republish` adds a fresh transceiver.
  - A `tracks/close` response that carries an SFU offer instead of an answer rolls back our close offer, then answers theirs.
- **Per-track errors:** an error on one track (or a missing result) fails only that publish, pull, update or close, with an `SfuTrackException` carrying the SFU's `errorCode`. The rest of the batch succeeds. A request-level `errorCode` in a 2xx fails the whole batch with an `SfuRequestException`; broker exceptions pass through unchanged.
- **Failures and replacement (for M5).** The session doesn't reconnect. It reports one `SfuSessionFailure` and then refuses operations (`SfuSessionFailedException`):
  - `SfuSessionGone` when any broker call throws `SessionGoneException`;
  - `SfuPeerConnectionFailed` when the connection state becomes `failed`, the ICE state `failed`, the connection closes unexpectedly, or ICE stays `disconnected` longer than `iceDisconnectedTimeout` (7 s, as in partytracks; null disables it).

  Its publications and subscriptions become `interrupted` and detach from it; they survive the session. M5 connects a new session and calls `republish` (same `trackName`, current track and encodings) and `resubscribe` (optionally with the publisher's new `sessionId`); `trackStream` then emits the new remote track. `close()` also leaves them `interrupted`, fails queued operations with `SfuSessionClosedException`, and calls `BrokerClient.forgetSession`. partytracks instead re-creates the session inside `session$` and re-pushes automatically; here that policy belongs to M5.
- **Peer-connection abstraction.** `SfuSession` talks to an internal `PeerConnection`/`PeerTransceiver` interface: `FlutterWebrtcPeerConnection` wraps `flutter_webrtc`, and tests use a scripted fake with opaque SDP (`test/support/`). Native `flutter_webrtc` transceivers cache their `mid` from creation, so the wrapper re-reads it through `getTransceivers()`. The interface also creates negotiated DataChannels (`PeerDataChannel`, §9); the DataChannel layer reaches the session's queue, broker and peer connection through an internal `SfuSessionPort`. The internal `connectSfuSession(createPeerConnection: ...)` injects a fake; M3 tests can use it with `test/support/session_harness.dart`.
- **Not done here:** rendering a remote track needs a `MediaStream` for `RTCVideoRenderer`; M3 will wrap the track (for example with `createLocalMediaStream`). Automatic retries (partytracks retries each push/pull with backoff) are left to M5.

### 4.3 `Room`

`Room` ties a session to signaling. It:

- joins the `Signaling` transport with the local participant's state: `{participantId, sessionId, tracks: {name → kind/source}}`;
- updates that state whenever the local participant publishes or unpublishes, or the session is replaced;
- diffs remote participants' states and **pulls or closes tracks to match**. Pull only what the UI subscribes to; a large gallery shouldn't pull every camera;
- exposes:
  - `participants`: `Stream<List<RemoteParticipant>>`,
  - `activeSpeakers`,
  - `connectionState`,
  - `data` (DataChannels).

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

- `ParticipantState` is `{participantId, sessionId?, tracks: {trackName → {kind, source}}, metadata?}`. Its `toJson`/`fromJson` define the JSON that adapters put into presence payloads; the shape is documented on the class.
- `participants` replays the current list to new listeners, emits `[]` while not in a room, and never includes the caller's own entry.
- **Ship an in-memory implementation** for tests and the example app: `InMemorySignaling`, where participants share an `InMemorySignalingHub` (several rooms per hub).
- **Keep backend adapters out of the core package.** For example, a Supabase Realtime presence adapter would be a separate package, such as `cloudflare_realtime_supabase`, or it lives in the app.
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
- **Subscribe:**
  - Pick `preferredRid` from the rendered tile size: the stage gets `a`, a gallery tile `b`, a thumbnail `c`.
  - Change it with `tracks/update`.
  - Set `ridNotAvailable: "asciibetical"` so a subscriber falls back when a layer stops, for example when the publisher's CPU throttles.
  - **`priorityOrdering` is left at the SFU default (`none`)**, so a subscriber gets exactly the layer the client chose. That keeps layer switching predictable for the week-6 checkpoint. `LayerSelectionConfig.priorityOrdering` opts in to `asciibetical` (the SFU may step down under bandwidth pressure). Revisit after measuring on constrained links.
- **Screen share:** open question. It could be a single high-quality layer, or simulcast with a low layer for thumbnails. Measure both.
- **Codec:** **default to VP8 on Windows.** H.264 crashes have been reported there (flutter-webrtc #982). Use `setCodecPreferences` on the transceiver.

### 6.1 Layer selection

The building blocks are implemented in `lib/src/quality/`, but not yet wired. The Room (M3/M4) will own a `LayerSelectionController`, send its changes with `tracks/update`, and hand the app a `LayerDemandReporter`.

- **Publisher ladder** (`SimulcastLadder`, internal): the layers a publisher sends, highest first. `SimulcastLadder.fromPreset(VideoPreset.h720)` is `a`=1280×720, `b`=640×360, `c`=320×180.
  - **Encoder layer limit.** libwebrtc's legacy simulcast limit sends 3 layers from 960×540 up, 2 from 480×270 up, and otherwise 1. It drops the **lowest** layers, so a 360p publisher sends only `a` and `b`. The ladder applies this limit by default, so the policy never asks for a layer the publisher doesn't send.
  - This is an expectation, not a guarantee: capture can come out smaller than requested, and libwebrtc versions differ. `ridNotAvailable: asciibetical` covers the remaining mismatch. **Check it on devices.**
  - `TrackInfo` doesn't carry the publisher's preset yet, so the Room assumes `h720` until it does (the controller's `defaultLadder`).
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
  - It talks only to the `LayerDemandReporter` interface, which the Room will implement.

## 7. Active speaker

- Poll `getStats()` for audio `inbound-rtp` / receiver `audioLevel`, every 200–500 ms.
- Smooth with a short window, and apply a threshold plus hold time so the speaker doesn't flicker.
- Include the local microphone level, so "you are speaking while muted" hints are possible.
- Emit an ordered list of participant IDs.

The building blocks are implemented in `lib/src/quality/`, but not yet wired. The Room will own an `ActiveSpeakerMonitor` and expose `activeSpeakers`. Only `ActiveSpeakerConfig` is public.

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
- **Open for M4: the muted microphone's level.**
  - With `MutePolicy.keepCapture` the mic keeps capturing, but M2 plans `replaceTrack(null)` on the sender (§4.5).
  - A sender without a track has no `media-source` report, and a disabled track reports silence. So `getStats` alone can't see a muted user talking.
  - M4 must pick a way: for example, a second, local-only level source for the captured track. Otherwise the hint only works where such a source exists.

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

The building blocks are implemented in `lib/src/reconnect/`. They are pure decision logic, with no timers or I/O; M5 wires them to `SfuSession` and the Room. `BackoffConfig`, `ReconnectTriggerConfig` and `ReconnectReason` are public.

- **`Backoff`** (internal) covers one reconnection episode.
  - The delay before attempt `n` (0-based) is uniform in `[0, min(maxDelay, initialDelay × multiplier^n)]`. This is exponential backoff with **full jitter**, so clients that dropped together don't come back together.
  - `nextDelay()` returns `null` once `maxAttempts` delays have been handed out, or once `maxElapsed` has passed since the episode's first attempt.
  - `reset()` after a successful reconnection starts a fresh episode.
  - The random source and the clock are injectable.
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

## 9. DataChannels

Implemented (M7) at the session level in `lib/src/data/`, with the operations on `SfuSession`. `Room` (M3) will expose `room.data` on top of it. partytracks has no DataChannel support to port; the negotiation follows Cloudflare's DataChannels docs, the OpenAPI schema and Cloudflare's `echo-datachannels` example, and the queueing and lifecycle mirror the track code.

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
- **Batching and errors.** As with tracks: publishes and subscribes in one event-loop turn become one `datachannels/new` each (local and remote kept apart, like `tracks/new`); `canReply` updates one `datachannels/update` (the last value per channel wins); closes one `datachannels/close` by `id`. A per-channel error or a missing `id` fails only that channel with `SfuDataChannelException`; a request-level `errorCode` fails the batch with `SfuRequestException`; `SessionGoneException` fails the session. If creating the local channel fails, or the channel was closed while its request was in flight, the SFU's `id` is released again with `datachannels/close`, best effort. Names are unique per session, and `server-events` is reserved.
- **Messages.** `DataChannelMessage` carries `binary` or `text`, and `fromSessionId`: the publisher's session for a `RemoteDataChannel`, captured when that underlying channel was opened (so late messages from an old session keep the old ID after a resubscribe). On a `LocalDataChannel`, received messages are replies from the one `canReply` subscriber, which the SFU doesn't identify, so `fromSessionId` is null. `messages` is a broadcast stream that survives moves between sessions.
- **Lifecycle.** A channel outlives its session, like a track publication. When the session fails or closes, channels become `interrupted` and their underlying channels are closed; M5 moves them with `republishDataChannel` / `resubscribeDataChannel` (which re-establish on the new session). If the underlying channel closes without `close()` (the SFU or the other end dropped it), the channel becomes `interrupted` too, and its SFU `id` is released. `close()` is immediate and terminal locally; on a dead session it makes no SFU call.
- **Backpressure.** `bufferedAmount` plus an edge-triggered `bufferedAmountLow` stream. Native `flutter_webrtc` reports every buffered-amount change (and fires its low callback on each change below the threshold), so the wrapper detects the crossing itself; on the web the browser's `bufferedamountlow` is used. On native platforms `bufferedAmount` is the last value reported, so it lags slightly.
- **`flutter_webrtc` realities** (1.6.2+hotfix.3):
  - `RTCDataChannelInit.toMap()` drops `maxRetransmits: 0` (it only sends positive values), which would silently make the unreliable profile reliable on native platforms. The wrapper overrides `toMap()`; Android, Darwin and the C++ desktop plugin all apply the key when present.
  - **Web:** `dart_webrtc` drops `maxRetransmits: 0` too and doesn't use `toMap()`, so a browser endpoint of an unreliable channel sends unordered but retransmitted. Needs an upstream fix.
  - Binary messages are requested as `ArrayBuffer` on the web (`binaryType: 'binary'`); the default `Blob` is decoded asynchronously and can reorder messages.
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
- **Implemented (desktop and web):** `ScreenSourcePicker` and `ScreenShareSource` in `lib/src/media/`.
  - **The picker** lists screens and windows with thumbnails through `desktopCapturer.getSources`, screens first.
    - The plugin reports changes only while someone calls `updateSources`. So the picker re-scans every 3 s (configurable), like the `flutter_webrtc` example, and applies added, removed, renamed and new-thumbnail events.
    - On Windows the first listing has no thumbnails; the first re-scan, which runs immediately, brings them.
    - The plugin keeps a single global source list, so run one picker at a time.
  - **Desktop capture** uses `getDisplayMedia({video: {deviceId: {exact: id}, mandatory: {frameRate}}, audio})`, as in the `flutter_webrtc` desktop example. The default frame rate is 30.
  - **Web capture** uses `getDisplayMedia` and the browser's picker. A cancelled picker returns `false`; it isn't an error.
  - **Ending a share** is surfaced on `ended` with a `ScreenShareEndReason`:
    - `stopped`: the app stopped it.
    - `userStopped`: the browser's "Stop sharing" button fired the track's `onEnded`.
    - `sourceClosed`: the shared window or display went away. Native tracks never fire `onEnded`, so while sharing, the desktop source re-scans the source list and ends the share on `onRemoved` for its source.
  - **Switching sources** releases the old capture before starting the new one. On Windows, stopping any desktop capturer also stops the single loopback-audio capturer.
  - **Windows listing failures** (#1539, #1085) are data, not crashes:
    - `getSources` errors, or a list with no screens, become `ScreenPickerState.error` (`ScreenSourcesException`). The picker retries once at once, and `refresh()` retries again.
    - "source not found!" from `getDisplayMedia` means the plugin's list was stale. The share rebuilds it with `getSources` and retries once, then reports `ScreenSourceNotFoundException`.
- **Correction to the table:** since `flutter_webrtc` 1.5.0 (#2060), Windows can capture system audio via loopback, with `ScreenShareOptions(captureAudio: true)`. It arrives as `ScreenShareSource.audioTrack`. Whether it's good enough to replace the "No (#1952)" cell needs device testing.
- **Known `flutter_webrtc` issues to plan around:**
  - Windows HDR screens look washed out; WGC capture is requested (#2205).
  - Windows sometimes fails to list sources (#1539, #1085); handled as above.
  - There's no hardware-encoder selection on Windows (#2200).
  - The macOS 14+ system picker exists only in Stream's fork.

## 11. Public API sketch

This is a starting point, not a contract.

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
);

await room.localParticipant.publishCamera(simulcast: SimulcastPreset.h720);
await room.localParticipant.publishMicrophone();
await room.localParticipant.publishScreen(source: pickedSource); // a ScreenSource from ScreenSourcePicker; none on web

room.participants;                     // Stream<List<RemoteParticipant>>
room.activeSpeakers;                   // Stream<List<String>>
room.connectionState;                  // Stream<RoomConnectionState> (auto re-session)
remote.videoTrack?.setPreferredLayer(SimulcastLayer.low);

final input = await room.data.publish('input', reliable: false);
input.send(bytes);
room.data.subscribe(remoteParticipant, 'input').listen((msg) { /* msg.fromSessionId */ });

await room.leave();
```

- **Style.** partytracks uses Observables deliberately: repair logic (a replaced device or connection) stays inside the library, and consumers just see the new track. **Mirror that with Dart `Stream`s.** No `rxdart` (§12, question 1): where partytracks needs `BehaviorSubject`-style replay of the latest value, the package uses its internal `StateStream<T>` helper (`lib/src/util/`).

## 12. Open questions

1. ~~`rxdart`, or plain `Stream`/`StreamController`?~~ **Resolved:** plain `Stream`s, plus an internal `StateStream<T>` helper for replay-latest state. This means fewer dependencies for pub.dev consumers, and the replay-latest semantics we need are small.
2. Screen share: simulcast or a single layer?
3. Package split: a core package plus separate adapter packages (Supabase, in-memory), or adapters as examples only?
4. Minimum Dart/Flutter SDK for pub.dev. The scaffold pins `^3.13.0`; widen it before publishing if `flutter_webrtc` allows.
5. Naming and trademark: the package is **unofficial**. Keep the disclaimer in the README and pubspec description.
