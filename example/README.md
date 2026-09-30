# cloudflare_realtime example

A demo app for [`cloudflare_realtime`](../README.md).

The join screen picks the **signaling** (`lib/main.dart`, `SignalingChoice`):

- **In-memory (this app):** `InMemorySignaling`, where every participant lives in this process. With a **Broker URL** (and a bearer token if your broker needs one), joining opens the call screen through `CloudflareRealtime.join`. Without one, it shows a presence-only list: add simulated participants to watch it update.
- **Dev server (multi-device):** the DEV ONLY stack below. Fill in its URL, the dev token and a user name (or pass `--dart-define`s `DEV_SERVER_URL`, `DEV_TOKEN`, `DEV_USER`).

The **call screen** (`lib/call_page.dart`) publishes your microphone and camera, and shows a grid of `ParticipantVideoView` tiles: you, your screen share, and each remote camera and screen share. Remote video is pulled only while its tile is on screen; audio is pulled automatically. The buttons mute and unmute the microphone and camera, share the screen and leave. **Share screen** opens a dialog (`lib/screen_share_dialog.dart`): the screens and windows on desktop (the browser's own picker follows on the web; not yet on mobile), what the share is for (*Text*: one 15 fps layer; *Motion*: 30 fps; *Text + thumbnail layer*: simulcast), and audio on Windows and the web. It shows how to grant macOS's Screen Recording permission when that looks missing, and the call screen offers to stop a share that sends no frames. Remote shares go on the stage with `contain` fit. The app bar shows the room's connection state and, for the dev server, the signaling status.

The **Local media** button (camera-and-mic icon on the join screen) opens a local preview: camera and microphone toggles with device dropdowns, the mute model, and on desktop a screen and window picker with thumbnails that previews the chosen share.

```sh
cd example
flutter run -d macos   # or windows, android, ios, chrome
```

## Multi-device calls with the dev server

[`tools/dev-server/`](../tools/dev-server/README.md) is a DEV ONLY local broker plus WebSocket presence signaling. `lib/ws_signaling.dart` (`WsSignaling`) is the `Signaling` client for it. `lib/dev_config.dart` (`DevServerConfig`) turns a server URL, the dev token and a user name into a `BrokerConfig` and a `WsSignaling`. Debug Android builds allow cleartext HTTP to reach the server on a LAN IP; release builds don't. See the dev server's README for the step-by-step setup.

The platform folders already declare what later milestones need: camera, microphone and network permissions on Android, iOS and macOS.

## Integration test

`integration_test/sfu_loopback_test.dart` publishes a local camera (or microphone) track on one SFU session and pulls it on another, through a real broker. It is skipped unless `CF_REALTIME_BROKER_URL` is set:

```sh
cd example
flutter test integration_test -d macos \
  --dart-define=CF_REALTIME_BROKER_URL=https://broker.example.test/realtime \
  --dart-define=CF_REALTIME_BROKER_TOKEN=<token>   # optional: Authorization: Bearer
```

`CF_REALTIME_ROOM` sets the room (default `integration-test`), and `CF_REALTIME_BROKER_USER` is sent as `X-Dev-User`, which the dev server requires (`integration_test/broker_settings.dart`). On desktop the same names can come from the environment instead. Keep credentials out of the repository and out of shell history you share. `integration_test/reconnect_test.dart` and `datachannel_echo_test.dart` take the same settings.

## Video codec

Every participant sends VP8 by default (`--dart-define=VIDEO_CODEC=video/VP8`): the SFU forwards each publisher's codec unchanged, and Windows has crashed on H.264 (flutter-webrtc #982). `--dart-define=VIDEO_CODEC=default` uses the platform's order (overriding the package default, which is VP8 everywhere).

## Week-6 checkpoint

[`docs/checkpoint.md`](../docs/checkpoint.md) is the step-by-step runbook for the multi-device checkpoint calls with this app and the dev server.
