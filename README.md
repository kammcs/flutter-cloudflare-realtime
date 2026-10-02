# cloudflare_realtime

An **unofficial** Flutter client for the [Cloudflare Realtime SFU](https://developers.cloudflare.com/realtime/sfu/), built on [`flutter_webrtc`](https://pub.dev/packages/flutter_webrtc). It targets Android, iOS, macOS, Windows and Web.

> **Status: pre-release.** The design is written and the implementation has started: so far, the broker client, the SFU session (`SfuSession`: publish, subscribe, simulcast layer switching), the `Signaling` interface with an in-memory implementation, the media layer (devices, local camera/microphone capture, screen share on desktop, web, Android and iOS), and an example app in [`example/`](example/). The package is not on pub.dev yet.

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

### iOS screen share setup

On iOS, a screen share is captured by a **Broadcast Upload Extension**, a separate target in your app that iOS runs while the user shares. `publishScreen()` (or `ScreenShareSource.start()`) takes no source: the system's broadcast picker opens, and the call completes once the user taps **Start Broadcast**. This package ships the extension's code as templates in [`ios/broadcast_extension/`](ios/broadcast_extension/) (MIT); you add the target once. The [example app](example/ios/) is set up this way.

1. **Add the target.** In Xcode, File → New → Target → *Broadcast Upload Extension*, named for example `BroadcastExtension`, without a UI extension. Set its deployment target to iOS 15 or later, and its bundle identifier to your app's plus a suffix (`com.example.app.BroadcastExtension`). It must link **ReplayKit only**: never add Flutter or any plugin to it.
2. **Use the templates.** Replace the generated `SampleHandler.swift` with this package's `SampleHandler.swift` and add `BroadcastUploader.swift` (copy them, or reference them from the package). Use its `Info.plist` and `BroadcastExtension.entitlements`, or copy their keys: `NSExtension` (point `com.apple.broadcast-services-upload`, principal class `$(PRODUCT_MODULE_NAME).SampleHandler`, mode `RPBroadcastProcessModeSampleBuffer`) and `RTCAppGroupIdentifier`. To give the extension the app's version, base its configurations on `Flutter/Debug.xcconfig` and `Flutter/Release.xcconfig`, as the app's are.
3. **An App Group on both targets.** Add the *App Groups* capability to the app and to the extension, with the same group (`group.com.example.app`). The templates read it from a build setting, `CF_REALTIME_APP_GROUP`, which you can define in `Flutter/Debug.xcconfig` and `Flutter/Release.xcconfig` (before any `#include?` of your own); or write the group into the files directly.
4. **The app's `Info.plist`:**

   ```xml
   <key>RTCAppGroupIdentifier</key>
   <string>group.com.example.app</string>
   <key>RTCScreenSharingExtension</key>
   <string>com.example.app.BroadcastExtension</string>
   <key>UIBackgroundModes</key>
   <array>
     <string>audio</string>
   </array>
   ```

   The first two tell `flutter_webrtc` where the frames come from. `audio` keeps the app running while the user is in other apps, which is the point of sharing a screen; the app's call audio (a published microphone) keeps it active.
5. **Embed the extension before "Thin Binary".** Xcode adds an *Embed Foundation Extensions* (or *Embed App Extensions*) build phase to the app target. In the app target's *Build Phases*, drag it above Flutter's **Thin Binary** script, or the build fails with a dependency cycle.
6. **Signing:** both targets need the same team. With automatic signing, Xcode creates the extension's App ID, its profile and the App Group.

**Checking the setup:** if something is missing, the share doesn't start: `start()` returns `false`, `publishScreen()` throws, and a `ScreenShareSetupException` says what's missing (`problems`, and `guidance` to log). It checks both `Info.plist` keys, the App Group container, an embedded broadcast extension with the bundle ID in `RTCScreenSharingExtension`, and the extension's `RTCAppGroupIdentifier`.

**Behaviour:** the picker can't report a cancel, so a dismissed picker makes `start()` return `false` (and `publishScreen()` throw a `MediaCaptureException`) after `ScreenShareOptions.broadcastStartTimeout` (60 s). A broadcast the user stops from the status bar or Control Center ends with `ScreenShareEndReason.userStopped`. The extension sends at most `ScreenShareOptions.frameRate` frames per second, scaled by `ScreenShareOptions.broadcastScale` (0.5 by default), and repeats a still screen once a second. Screen audio (`captureAudio`) isn't supported on iOS and is ignored.

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
