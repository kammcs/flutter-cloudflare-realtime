# cloudflare_realtime

An **unofficial** Flutter client for the [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/), built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc). One Dart API for calls, video conferences and screen sharing on Android, iOS, macOS, Windows and the web.

> **Unofficial.** This project isn't affiliated with, endorsed by or supported by Cloudflare. "Cloudflare" is a trademark of Cloudflare, Inc.

> **Pre-1.0.** The API can still change between minor versions. See the [changelog](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/CHANGELOG.md).

## Features

- **Rooms** on top of the SFU, with presence from your own signaling (Supabase Realtime, Firebase, your own WebSocket server…). The SFU has no rooms; the package diffs participants and pulls only what is subscribed.
- **Camera, microphone and screen** publishing, mute and unmute, and selective subscription.
- **The same call on every platform:** the front camera by default, `switchCamera()` that flips front and back on phones and cycles cameras on desktops, presets honoured, a self-view mirrored only when it should be, and one audio-route API on both phones.
- **Simulcast** with per-tile layer selection from the size of each video view, a manual layer override, and (opt-in) pausing layers that no one pulls.
- **VP8 by default**; H.264, VP9 or AV1 per room or per publication.
- **Active speaker** detection and per-participant audio levels.
- **Connection quality** per participant and **typed stats** (bitrate, resolution, frame rate, loss, jitter, RTT).
- **Automatic reconnection:** a failed or expired SFU session is replaced, tracks and DataChannels are republished under the same names and subscriptions pulled again, with backoff.
- **Calls on phones:** keep running in the background, pause for a phone call or Siri and resume after it, turn the screen off at the ear, and route audio to the speaker, earpiece, wired or Bluetooth headsets.
- **System calls:** CallKit and PushKit on iOS, Android Telecom (Core-Telecom), as primitives: report, answer, end, hold, mute.
- **Reliable and unreliable DataChannels** for app messages, with the sender's identity from signaling, never from the payload.

It doesn't include a signaling server, push delivery or a meeting UI: your app brings those.

## Platforms

| | Android | iOS | macOS | Windows | Web |
|---|---|---|---|---|---|
| Camera and microphone calls, simulcast | Yes | Yes | Yes | Yes | Yes |
| Screen share | Yes (no audio) | Yes, with a Broadcast Upload Extension in your app (no audio) | Yes (no audio) | Yes, with system audio | Yes, the browser's picker (tab audio) |
| Calls in the background | Yes (foreground service) | Audio yes; the camera pauses | n/a | n/a | n/a |
| Audio routes (speaker, earpiece, headsets) | Yes | Yes | Output device | Output device | Output device where the browser allows |
| System calls | Telecom | CallKit, PushKit | In Dart only | In Dart only | In Dart only |
| Verified against the real SFU | Pixel 10 (Android 16), emulator (API 34) | iPhone (iOS 27) | MacBook Pro (macOS 27) | Windows 11 | Chrome, Firefox, Safari (JS and Wasm) |

- **Minimums:** Flutter 3.41 (Dart 3.11); Android 7.0 (API 24); iOS 15; macOS 10.15.
- **Not verified yet:** screen share and speaker choice in Safari (both need a user gesture, which the tests can't give), 4-person calls, a real network drop, CallKit on a device (the iOS backend is unit-tested), and Bluetooth and wired headsets on every phone. Linux isn't supported.
- "In Dart only" means the `SystemCalls` API works and emits the same events, without a system call UI.

## How it fits together

```
your app ── Signaling (your presence transport) ──► other participants
   │
   │  cloudflare_realtime: Room, SfuSession, media, broker client
   │
   └── HTTPS + your auth ──► your broker ── App Secret ──► Cloudflare Realtime SFU
```

- The SFU API needs your Cloudflare **App Secret**, so the client never calls Cloudflare directly. You run a small **broker** that authenticates your users, checks room membership, and forwards the SFU calls ([below](#the-broker)).
- The SFU has no rooms or presence. Participants find each other through **signaling** you provide ([below](#signaling)).
- Media flows between each client and the SFU over WebRTC.

## Install

```sh
flutter pub add cloudflare_realtime
```

Then follow the setup for each platform you ship: [Android](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/android.md), [iOS](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/ios.md), [macOS](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/macos.md), [Windows](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/windows.md) and [web](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/web.md). At a minimum: camera and microphone permissions (Android) or usage descriptions (iOS, macOS), and the sandbox entitlements on macOS.

## Quick start

```dart
import 'package:cloudflare_realtime/cloudflare_realtime.dart';

// 1. Point the package at your broker. `headers` runs before every request,
//    so it can refresh an expiring token.
final realtime = CloudflareRealtime(
  broker: BrokerOptions(
    baseUrl: Uri.parse('https://api.example.com/realtime'),
    headers: () async => {'Authorization': 'Bearer ${await getAppJwt()}'},
  ),
);

// 2. Join a room. `signaling` is your Signaling implementation; for a local
//    demo, InMemorySignaling(InMemorySignalingHub()) from
//    package:cloudflare_realtime/testing.dart works in one process.
final room = await realtime.join(
  'room-123',
  signaling: mySignaling,
  participantId: '$userId:$deviceId', // unique in the room
  metadata: {'displayName': 'Ada'},
);

// 3. Publish. The camera is sent as three simulcast layers by default.
final microphone = await room.localParticipant.publishMicrophone();
final camera = await room.localParticipant.publishCamera();
await microphone.mute(); // announced to the others; unmute() to undo

// 4. Render. Remote audio plays by itself; remote video is pulled while its
//    view is on screen, at the layer that fits the view.
Widget build(BuildContext context) {
  return StreamBuilder<List<RemoteParticipant>>(
    stream: room.participantsChanges, // on joins, leaves and track changes
    initialData: room.participants,
    builder: (context, snapshot) => GridView.count(
      crossAxisCount: 2,
      children: [
        ParticipantVideoView.local(camera.mediaSource), // mirrored self-view
        for (final participant in snapshot.data!)
          if (participant.camera case final video?)
            ParticipantVideoView.remote(video),
      ],
    ),
  );
}

// 5. Leave: unpublishes, stops capture and closes the session.
await room.leave();
```

**Next:**

- Observable state is a getter for the value now and a `…Changes` stream that replays it, then emits each change: `room.participants` / `participantsChanges`, `room.connectionState` / `connectionStateChanges`, `publication.isMuted` / `mutedChanges`.
- `room.events` (a sealed `RoomEvent` stream: participants joining and leaving, tracks published and muted, reconnection, errors) and `room.connectionState`.
- `room.activeSpeakers` / `dominantSpeaker`, and `isSpeaking` and `connectionQuality` on each participant.
- `room.localParticipant.publishScreen()`: a `ScreenSourcePicker` source on desktops; the system or browser picker elsewhere.
- `room.localParticipant.switchCamera()`, `room.audioRoutes` / `selectAudioRoute()` on phones, `room.setAudioOutputDevice()` elsewhere.
- `room.data.publish()` and `room.data.subscribe()` for DataChannels.
- `RoomOptions` for what's subscribed automatically, reconnection, the video codec, stats and the phone behaviours.
- The [example app](https://github.com/kammcs/flutter-cloudflare-realtime/tree/main/example) puts all of it in a call screen.

## The broker

Every SFU call goes through a broker that **you** operate; the App Secret lives only there. Its paths mirror the SFU API under a base URL (`POST sessions/new`, `POST sessions/{id}/tracks/new`, `PUT …/renegotiate`, …, plus `POST generate-ice-servers`), so it is compatible with partytracks' proxy. Each request carries your app's auth headers and `X-Realtime-Room: <roomId>`.

A broker must enforce these rules, or one user can listen in on another room:

1. **Authenticate** every request with your app's credential (`401` otherwise).
2. **Authorize the room** named in `X-Realtime-Room`: the caller must be a member (`403`). Never trust a room list from the client.
3. **Bind sessions to their creator:** every call on `sessions/{id}` must come from the user who created that session, for the same room.
4. **Pull only from the same room:** every `sessionId` a request names (track pulls, DataChannel subscriptions) must be a session the broker created for the caller's room.
5. **Forward only what Cloudflare needs:** the App Secret as `Authorization: Bearer …`, and nothing from the client's headers.

The repository has two **reference brokers** that implement these rules, a Cloudflare Worker and a Supabase Edge Function, with tests: see [broker/README.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/broker/README.md) for the full contract, the session tokens and CORS. They are references, not drop-in products: their room-membership check rejects every room until you implement it. The DEV ONLY [tools/dev-server/](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/tools/dev-server/README.md) runs a local broker and WebSocket signaling for trying calls across devices from a laptop; never deploy it.

`HttpBrokerClient` is the default client. Implement `BrokerClient` yourself for a different transport: it, the wire models and the low-level `SfuSession` are in `package:cloudflare_realtime/broker.dart`, which most apps never import.

## Signaling

The SFU knows sessions and tracks, not people. Each participant announces a `ParticipantState` (its SFU session ID, the tracks it publishes with their mute and simulcast flags, and your metadata) and learns everyone else's through `Signaling`, a four-member interface you implement on any transport with presence:

```dart
class MySignaling implements Signaling {
  @override
  Future<void> join(String roomId, ParticipantState self) async {
    // Enter the room's presence channel and announce self.toJson().
  }

  @override
  Future<void> update(ParticipantState self) async {
    // Replace the announced state with self.toJson().
  }

  @override
  Stream<List<ParticipantState>> get participants => _others.stream;
  // Everyone else in the room (ParticipantState.fromJson), never this
  // participant; replay the current list to new listeners.

  @override
  Future<void> leave() async {
    // Withdraw the state; the list becomes empty.
  }
}
```

The contract is in the [`Signaling`](https://pub.dev/documentation/cloudflare_realtime/latest/cloudflare_realtime/Signaling-class.html) docs, and the JSON wire shape in [`ParticipantState`](https://pub.dev/documentation/cloudflare_realtime/latest/cloudflare_realtime/ParticipantState-class.html). `InMemorySignaling` (in `package:cloudflare_realtime/testing.dart`) is a ready-made implementation for tests and single-process demos, and the example app has a WebSocket one (`example/lib/ws_signaling.dart`).

Presence data is only as trustworthy as your transport: the broker, not signaling, decides who may pull what.

## Platform setup

| Platform | Guide | The short version |
|---|---|---|
| Android | [doc/android.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/android.md) | Declare `CAMERA`, `RECORD_AUDIO` and `BLUETOOTH_CONNECT` (and request the last yourself). The foreground services for calls (`microphone`, `camera`, `phoneCall`) and screen share (`mediaProjection`) come from the package's manifest; declare their types in the Play Console. |
| iOS | [doc/ios.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/ios.md) | Camera and microphone usage descriptions; the `audio` background mode (plus `voip` for CallKit and VoIP pushes); a Broadcast Upload Extension target, from the package's templates, for screen sharing, with an App Group and the same signing team on both targets. |
| macOS | [doc/macos.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/macos.md) | The camera, audio-input and network-client entitlements, the usage descriptions, and the user's Screen Recording permission for sharing. |
| Windows | [doc/windows.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/windows.md) | Visual Studio 2022 17.14+ with the C++ ATL component. Nothing to declare. |
| Web | [doc/web.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/web.md) | HTTPS, your web origins in the broker's CORS list, and a "tap to enable audio" button for the autoplay policy (`Room.isAudioPlaybackBlocked`, `Room.startAudio()`). |

## Testing your app

Widget tests (`testWidgets`, or anything under `fake_async`) run in fake time, and a `Room` does real asynchronous work: it cancels stream subscriptions, closes streams and runs timers. In fake time, an awaited `StreamSubscription.cancel()` can hang the test. So:

- Advance time with a duration, `await tester.pump(const Duration(milliseconds: 100))`, rather than relying on `pumpAndSettle()`.
- Run calls that really wait, such as `join` and `room.leave()`, inside `await tester.runAsync(() => room.leave())`.
- Import `package:cloudflare_realtime/testing.dart` for the seams below. `flutter_webrtc`'s plugin doesn't run in `flutter test`.
- `ParticipantVideoView.defaultRendererFactory` swaps in a fake `VideoRenderer`.
- `CloudflareRealtime`'s `mediaBackend` (a `MediaBackend`), `createBrokerClient` (a `BrokerClientFactory`) and `connectSession` (an `SfuSessionConnector`) parameters replace the capture, the broker client and the SFU session with fakes; `InMemorySignaling` stands in for your signaling.
- `Room`, `LocalParticipant`, `RemoteParticipant`, the publications and the other stateful classes can be mocked (`implements`); the options, value types, events and exceptions are `final` or `sealed`, so build them with their constructors.

## Docs

| | |
|---|---|
| [API reference](https://pub.dev/documentation/cloudflare_realtime/latest/) | Every public class and member |
| [doc/](https://github.com/kammcs/flutter-cloudflare-realtime/tree/main/doc) | Setup for each platform |
| [doc/migrating-to-0.1.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/doc/migrating-to-0.1.md) | The renames of the 0.1.0 API cleanup, for code written against the pre-release API |
| [docs/design.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md) | Architecture, the broker contract, simulcast, reconnection, DataChannels, platform notes |
| [docs/cloudflare-sfu.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/cloudflare-sfu.md) | What the SFU API provides, and its rules |
| [docs/roadmap.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/roadmap.md) | Milestones and what's verified |
| [example/](https://github.com/kammcs/flutter-cloudflare-realtime/tree/main/example) | The example app, and integration tests against a real broker |

## License

MIT. See [LICENSE](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/LICENSE). Code ported from [partytracks](https://github.com/cloudflare/partykit/tree/main/packages/partytracks) keeps its ISC notice; see [THIRD_PARTY_NOTICES.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/THIRD_PARTY_NOTICES.md).
