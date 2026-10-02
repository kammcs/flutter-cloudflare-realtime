# cloudflare_realtime

An **unofficial** Flutter client for the [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/), built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc). It targets Android, iOS, macOS, Windows and Web.

> **Status: pre-release.** The design is written and the implementation has started: so far, the broker client, the SFU session (`SfuSession`: publish, subscribe, simulcast layer switching), the `Signaling` interface with an in-memory implementation, the media layer (devices, local camera/microphone capture, screen share on desktop, web and Android), and an example app in [`example/`](example/). The package is not on pub.dev yet.

This project isn't affiliated with or endorsed by Cloudflare.

## What it will do

- Rooms on top of the SFU, with presence supplied by your own signaling (for example, Supabase Realtime, Firebase or your own WebSocket).
- Camera, microphone and screen publishing, and selective subscription.
- The same calls behave the same on every platform: the front camera by default, `switchCamera()` that flips front and back on phones and cycles cameras on desktops, presets honoured, and a self-view mirrored only when it should be.
- Simulcast with per-tile layer selection.
- Active-speaker detection.
- Automatic reconnection.
- Reliable and unreliable DataChannels.

## How it fits together

- The SFU API needs your **App Secret**, so the client never calls Cloudflare directly.
- Instead, you run a small **broker** that authenticates your users, checks room membership, and forwards requests to Cloudflare.
- The broker's paths are compatible with [partytracks](https://github.com/cloudflare/partykit/tree/main/packages/partytracks)' proxy.

See [docs/design.md](docs/design.md) for the architecture, the broker contract and its security rules.

To try a real call across devices from your laptop, use the DEV ONLY local broker and WebSocket signaling in [tools/dev-server/](tools/dev-server/README.md). It needs just your Cloudflare SFU credentials in environment variables. Reference brokers for deployment are in [broker/](broker/README.md).

## Platform setup

### Screen share on Android

`LocalParticipant.publishScreen()` (or `ScreenShareSource.start()`) takes no source on Android: the system's consent dialog is the picker. The share runs under a foreground service of type `mediaProjection` that this package provides, which Android 14+ requires.

- **Manifest:** nothing to add. The package's manifest declares the service and the `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` and `POST_NOTIFICATIONS` permissions, and the manifest merger brings them into your app. An app that never shares its screen can drop them with `tools:node="remove"`.
- **Notification permission (Android 13+):** the service shows a "Sharing your screen" notification with a **Stop sharing** action. If `POST_NOTIFICATIONS` isn't granted, the package asks for it once per app launch, before the consent dialog. If the user says no, the share still works; the notification just isn't shown in the drawer. To ask at a better moment, request it yourself first (for example with `permission_handler`).
- **Customizing the notification:** override the strings `cloudflare_realtime_screen_share_channel`, `…_title`, `…_text` and `…_stop`, or the drawable `cloudflare_realtime_screen_share`, in your app's resources.
- **Google Play:** apps that use the `mediaProjection` foreground service type must declare it in the Play Console.
- **Behaviour:** a cancelled consent dialog makes `start()` return `false` (and `publishScreen` throw a `MediaCaptureException`), as a cancelled browser picker does. A share stopped from the system's status-bar chip or the notification ends with `ScreenShareEndReason.userStopped`. Screen audio (`captureAudio`) isn't supported on Android and is ignored.

See [design.md §10](docs/design.md#10-screen-share-by-platform) for the details.

## Testing your app

Widget tests (`testWidgets`, or anything under `fake_async`) run in fake time, and a `Room` does real asynchronous work: it cancels stream subscriptions, closes streams and runs timers. In fake time, an awaited `StreamSubscription.cancel()` can hang the test. So:

- Advance time with a duration, `await tester.pump(const Duration(milliseconds: 100))`, rather than relying on `pumpAndSettle()`.
- Run calls that really wait, such as `join` and `room.leave()`, inside `await tester.runAsync(() => room.leave())`.
- `ParticipantVideoView.defaultRendererFactory` swaps in a fake renderer, since `flutter_webrtc`'s plugin doesn't run in `flutter test`.

## Docs

| | |
|---|---|
| [docs/design.md](docs/design.md) | Architecture, broker contract, simulcast, reconnection, DataChannels, platform notes |
| [docs/cloudflare-sfu.md](docs/cloudflare-sfu.md) | What the SFU API provides, and its rules |
| [docs/roadmap.md](docs/roadmap.md) | Milestones |
| [docs/checkpoint.md](docs/checkpoint.md) | Runbook: demonstrate the week-6 checkpoint (calls on Windows, macOS and Android, simulcast layer switching, recovery from a network drop) with the example app |

## License

MIT. See [LICENSE](LICENSE). Code ported from partytracks keeps its ISC notice; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
