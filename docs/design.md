# Design: `cloudflare_realtime`

This package is a Flutter client for the [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/). It is built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc) and targets **Android, iOS, macOS, Windows and Web**.

- **Status:** pre-release. The broker client (§4.1) is implemented; the rest is design.
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

One `RTCPeerConnection` maps to one SFU session. A participant normally has **one session** that carries everything they push and pull.

- **Push** (publish local tracks):
  1. Add a `sendonly` transceiver per track (with simulcast encodings for video).
  2. `createOffer`, then `setLocalDescription`.
  3. `POST tracks/new` with the offer, and `tracks: [{location: "local", mid, trackName}]`.
  4. `setRemoteDescription(answer)`.
- **Pull** (subscribe to remote tracks):
  1. `POST tracks/new` with `tracks: [{location: "remote", sessionId, trackName, simulcast?}]`.
  2. If the response has `requiresImmediateRenegotiation`, then `setRemoteDescription(offer)`, `createAnswer`, and `PUT renegotiate` with the answer.
  3. Map the returned `mid` to the transceiver, which gives you the remote track.
- **Update:** `PUT tracks/update`, used to change a pulled track's `preferredRid`.
- **Close:** `PUT tracks/close` with the `mid`s. Renegotiate if the response asks for it. Stop the transceivers.
- **All operations run through one serialized queue.** The SFU requires each SDP exchange to finish before the next mutation on the same session.
  - Batch pushes and pulls that arrive together into a single `tracks/new` call. partytracks does this; port its batching.
- **Per-track errors:** the API returns an error per track, not only per request. Surface them on the individual track.

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

- **Ship an in-memory implementation** for tests and the example app.
- **Keep backend adapters out of the core package.** For example, a Supabase Realtime presence adapter would be a separate package, such as `cloudflare_realtime_supabase`, or it lives in the app.
- The core must not depend on any backend SDK.

### 4.5 Media

This layer:
- wraps `flutter_webrtc` capture: `getUserMedia`, `getDisplayMedia`, and `desktopCapturer.getSources`;
- lists devices and tracks the preferred device. It recovers when a device is unplugged, which partytracks does with its `devices$`/`activeDevice$` streams;
- handles the mute model: "source enabled" is separate from "broadcasting", as in partytracks.

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

**Wire details.** Both the Dart client and the reference brokers follow these exactly.

- **Headers on every request:**
  - the app's own auth headers, from the `headers` provider;
  - `X-Realtime-Room: <roomId>`, the room the caller is acting in.
- **Session token (optional).**
  - On `POST sessions/new`, the broker MAY return a response header `X-Realtime-Session-Token`.
  - If it does, the client sends it back as the request header `X-Realtime-Session-Token` on every later call for that session. The client keeps one token per session ID, because reconnection creates new sessions.
  - A broker may instead bind sessions server-side and never send a token. The client works either way.
  - The client never lets the app's headers set `X-Realtime-Room` or `X-Realtime-Session-Token`.
- **`sessions/new` body:** none, unless the client has an initial offer. `correlationId` travels as a query parameter, which the broker passes through.
- **Broker errors:**
  - `401`: the caller isn't authenticated. The body is unspecified.
  - `403` with `{"errorCode": "forbidden", "errorDescription": "..."}`: the caller isn't in the room, doesn't own the session, or pulls from a session in another room.
  - Otherwise the SFU's status and body pass through unchanged, including `410` with `errorCode: session_error` for an expired session.
- **`generate-ice-servers` response:** `{"iceServers": [{"urls": ["..."], "username"?: "...", "credential"?: "..."}]}`. Without TURN configured, the broker returns Cloudflare STUN only: `{"iceServers": [{"urls": ["stun:stun.cloudflare.com:3478"]}]}`.

**The broker must enforce these security requirements.** Document them in the README, and follow them in any reference broker:

1. **Authenticate the caller** with the app's own credential.
   - partytracks uses cookies, but native Flutter clients don't keep cookies. So the package sends whatever headers the app's `headers` provider returns.
   - The broker then replaces `Authorization` with the App Secret before forwarding.
2. **Authorize the room.** The client names the room it's joining in the `X-Realtime-Room` header. The broker checks that the caller is a member of it.
3. **Bind sessions to their creator.** After `sessions/new`, only the same caller may mutate that session.
   - partytracks does this with a JWT cookie. Here, the broker either keeps a server-side map, or returns a signed session token in `X-Realtime-Session-Token` that the client echoes on later calls.
   - The package supports echoing such a token (see the wire details above).
4. **Restrict pulls to the same room.** A `tracks/new` pull names another participant's `sessionId`. The broker must check that the session belongs to the same room. **Otherwise anyone with a valid login could subscribe to any room's media by guessing or learning a session ID.**
5. Strip client-supplied headers that shouldn't reach Cloudflare. Never log the App Secret, SDP bodies or tokens.

**Reference brokers** are roadmap items: a Cloudflare Worker and a Supabase Edge Function (Deno). Keep them in `broker/` in this repo.

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
  - Decide deliberately whether to use `priorityOrdering: "asciibetical"`, which lets the SFU drop layers under bandwidth pressure.
- **Screen share:** open question. It could be a single high-quality layer, or simulcast with a low layer for thumbnails. Measure both.
- **Codec:** **default to VP8 on Windows.** H.264 crashes have been reported there (flutter-webrtc #982). Use `setCodecPreferences` on the transceiver.

## 7. Active speaker

- Poll `getStats()` for audio `inbound-rtp` / receiver `audioLevel`, every 200–500 ms.
- Smooth with a short window, and apply a threshold plus hold time so the speaker doesn't flicker.
- Include the local microphone level, so "you are speaking while muted" hints are possible.
- Emit an ordered list of participant IDs.

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

## 9. DataChannels

- The SFU forwards DataChannels **from a publisher to its subscribers**.
  - `datachannels/establish` sets up the SCTP transport.
  - `datachannels/new` with `location: "local"` publishes a named channel. With `location: "remote"` plus the publisher's `sessionId`, it subscribes.
  - A subscriber created with `canReply: true` can send back on the publisher's channel. **Only one subscriber can do this.** For general two-way traffic, both sides publish.
  - Channels are **negotiated**. The SFU returns a channel `id`, and the client calls `createDataChannel(name, negotiated: true, id: id)`. The publisher's and subscriber's IDs can differ.
- **Offer two profiles:**
  - **reliable**: ordered, retransmitted (omit `maxRetransmits` and `maxPacketLifeTime`). For keys, clicks, chat and control messages.
  - **unreliable**: `ordered: false`, `maxRetransmits: 0`. For high-rate data such as mouse moves.
- **Sender identity comes from the channel's `sessionId`, never from the payload.**
  - The app maps `sessionId` → user through its (server-verified) signaling.
  - The package exposes the remote `sessionId` for each channel, so apps can do this. Remote control depends on it.

## 10. Screen share by platform

| | Full display | Single window | Covered window | Minimized window | Cursor | System audio |
|---|---|---|---|---|---|---|
| **Windows** | Yes: `desktopCapturer.getSources([screen, window])` with thumbnails (DXGI Desktop Duplication) | Yes | Crops the screen while the window is on top. Falls back to GDI when covered, which may show the covering content, or black for GPU-rendered apps | No frames | Composited (no toggle) | **No** (#1952) |
| **macOS** | Yes (ScreenCaptureKit) | Yes | Still captured | No frames | Composited | **No** |
| **Web** | The browser's picker decides | Yes | Browser-dependent | Chrome: no frames | `cursor` constraint | Tab audio only |
| **iOS** | Needs a Broadcast Upload Extension **in the host app** | n/a | | | | |
| **Android** | MediaProjection plus a foreground service of type `mediaProjection` **in the host app** | n/a | | | | |

- Document the iOS and Android host-app setup in the README, and show it in the example app.
- **Known `flutter_webrtc` issues to plan around:**
  - Windows HDR screens look washed out; WGC capture is requested (#2205).
  - Windows sometimes fails to list sources (#1539, #1085).
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
await room.localParticipant.publishScreen(source: pickedSource); // desktopCapturer / getDisplayMedia

room.participants;                     // Stream<List<RemoteParticipant>>
room.activeSpeakers;                   // Stream<List<String>>
room.connectionState;                  // Stream<RoomConnectionState> (auto re-session)
remote.videoTrack?.setPreferredLayer(SimulcastLayer.low);

final input = await room.data.publish('input', reliable: false);
input.send(bytes);
room.data.subscribe(remoteParticipant, 'input').listen((msg) { /* msg.fromSessionId */ });

await room.leave();
```

- **Style.** partytracks uses Observables deliberately: repair logic (a replaced device or connection) stays inside the library, and consumers just see the new track. **Mirror that with Dart `Stream`s.** Decide early whether to take a dependency on `rxdart`.

## 12. Open questions

1. `rxdart`, or plain `Stream`/`StreamController`?
2. Screen share: simulcast or a single layer?
3. Package split: a core package plus separate adapter packages (Supabase, in-memory), or adapters as examples only?
4. Minimum Dart/Flutter SDK for pub.dev. The scaffold pins `^3.13.0`; widen it before publishing if `flutter_webrtc` allows.
5. Naming and trademark: the package is **unofficial**. Keep the disclaimer in the README and pubspec description.
