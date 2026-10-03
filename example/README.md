# cloudflare_realtime example

A demo app for [`cloudflare_realtime`](https://pub.dev/packages/cloudflare_realtime): a call screen with camera, microphone and screen sharing, simulcast layer switching, active speaker, connection quality, reconnection, audio routes and system calls.

## Running it

1. **Get the app.** Clone the [repository](https://github.com/kammcs/flutter-cloudflare-realtime): the example uses the package from `../` and needs its platform folders (`flutter pub unpack` doesn't include the example's build setup).

   ```sh
   cd example
   flutter pub get
   flutter run -d macos   # or windows, android, ios, chrome
   ```

2. **Without a broker** the app starts, and the join screen offers a presence-only demo with in-memory signaling and the **Local media** preview (camera, microphone, devices and the screen picker). No Cloudflare account is needed for these.
3. **For real calls** you need a broker in front of a Cloudflare Realtime SFU app (its App ID and App Secret, from the Cloudflare dashboard):
   - **On one machine or a LAN:** the DEV ONLY [dev server](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/tools/dev-server/README.md) is a local broker plus WebSocket signaling. Start it with your SFU credentials in environment variables, then pick **Dev server** on the join screen and fill in its URL, the dev token and a user name (or pass `--dart-define=DEV_SERVER_URL=…`, `DEV_TOKEN` and `DEV_USER`). Run the app on two devices to call between them.
   - **Your own broker:** pick **In-memory**, fill in the **Broker URL** (and a bearer token if your broker needs one), and join. Every participant then lives in this one app, so this mode is for trying the broker, not for calls between devices.
4. **Platform notes:**
   - **iOS on a device:** set your development team on the `Runner` and `BroadcastExtension` targets in Xcode, and change the App Group (`CF_REALTIME_APP_GROUP` in `ios/Flutter/Debug.xcconfig` and `Release.xcconfig`) and the bundle IDs to ones your team owns.
   - **Android:** debug builds allow cleartext HTTP to reach a dev server on a LAN IP; release builds don't.
   - **Web:** serve over HTTPS (or `localhost`), and list the app's origin in the broker's CORS origins.

Never put an App Secret in the app; it stays in the broker's environment.

## What's in it

The join screen picks the **signaling** (`lib/main.dart`, `SignalingChoice`):

- **In-memory (this app):** `InMemorySignaling`, where every participant lives in this process. With a **Broker URL** (and a bearer token if your broker needs one), joining opens the call screen through `CloudflareRealtime.join`. Without one, it shows a presence-only list: add simulated participants to watch it update.
- **Dev server (multi-device):** the DEV ONLY stack below. Fill in its URL, the dev token and a user name (or pass `--dart-define`s `DEV_SERVER_URL`, `DEV_TOKEN`, `DEV_USER`).

The **call screen** (`lib/call_page.dart`) publishes your microphone and camera, and shows a grid of `ParticipantVideoView` tiles: you, your screen share, and each remote camera and screen share. Remote video is pulled only while its tile is on screen; audio is pulled automatically. The buttons mute and unmute the microphone and camera, share the screen and leave. **Share screen** opens a dialog (`lib/screen_share_dialog.dart`): the screens and windows on desktop (the browser's own picker on the web; the system's consent dialog or broadcast picker on phones), what the share is for (*Text*: one 15 fps layer; *Motion*: 30 fps; *Text + thumbnail layer*: simulcast), and audio on Windows and the web. It shows how to grant macOS's Screen Recording permission when that looks missing, and the call screen offers to stop a share that sends no frames. Remote shares go on the stage with `contain` fit, letterboxed inside their tile; a share that starts switches the call to the stage layout (switch back to the gallery and it stays there until another share starts). The app bar shows the room's connection state and, for the dev server, the signaling status: as a chip on wide screens, as an icon (tap it for details) on narrower ones. On phones the actions that don't fit (stats, hold, network drop, leave) are in the app bar's menu.

The **Local media** button (camera-and-mic icon on the join screen) opens a local preview: camera and microphone toggles with device dropdowns, the mute model, and on desktop a screen and window picker with thumbnails that previews the chosen share.

## Multi-device calls with the dev server

[`tools/dev-server/`](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/tools/dev-server/README.md) is a DEV ONLY local broker plus WebSocket presence signaling. `lib/ws_signaling.dart` (`WsSignaling`) is the `Signaling` client for it. `lib/dev_config.dart` (`DevServerConfig`) turns a server URL, the dev token and a user name into a `BrokerOptions` and a `WsSignaling`. Debug Android builds allow cleartext HTTP to reach the server on a LAN IP; release builds don't. See the dev server's README for the step-by-step setup.

The platform folders show the setup a host app needs ([setup guides](https://github.com/kammcs/flutter-cloudflare-realtime/tree/main/doc)): permissions and usage descriptions, the macOS entitlements, the iOS background modes and Broadcast Upload Extension, and the Android activity that answers system calls.

## Integration test

`integration_test/sfu_loopback_test.dart` publishes a local camera (or microphone) track on one SFU session and pulls it on another, through a real broker. It is skipped unless `CF_REALTIME_BROKER_URL` is set:

```sh
cd example
flutter test integration_test -d macos \
  --dart-define=CF_REALTIME_BROKER_URL=https://broker.example.test/realtime \
  --dart-define=CF_REALTIME_BROKER_TOKEN=<token>   # optional: Authorization: Bearer
```

`CF_REALTIME_ROOM` sets the room (default `integration-test`), and `CF_REALTIME_BROKER_USER` is sent as `X-Dev-User`, which the dev server requires (`integration_test/broker_settings.dart`). On desktop the same names can come from the environment instead. Keep credentials out of the repository and out of shell history you share. `integration_test/reconnect_test.dart` and `datachannel_echo_test.dart` take the same settings. `cross_device_test.dart` runs on two devices at once against the dev server, with `CF_REALTIME_CROSS_DEVICE=1`; see [the checkpoint runbook](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/checkpoint.md#cross-device-test).

## Video codec

Every participant sends VP8 by default (`--dart-define=VIDEO_CODEC=video/VP8`): the SFU forwards each publisher's codec unchanged, and Windows has crashed on H.264 (flutter-webrtc #982). `--dart-define=VIDEO_CODEC=default` uses the platform's order (overriding the package default, which is VP8 everywhere).

## Week-6 checkpoint

[`docs/checkpoint.md`](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/checkpoint.md) is the step-by-step runbook for the multi-device checkpoint calls with this app and the dev server.
