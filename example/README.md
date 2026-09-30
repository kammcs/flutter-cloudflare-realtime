# cloudflare_realtime example

A demo app for [`cloudflare_realtime`](../README.md).

For now it joins a room through `InMemorySignaling`: every participant lives in the same process and shares one `InMemorySignalingHub`. Add simulated participants to watch the list update. Video tiles will replace the placeholder once rooms land (roadmap M3).

If you fill in **Broker URL** (and, if your broker needs it, a bearer token), joining also creates a real SFU session through your broker, shows its ID and connection state, and publishes your camera (simulcast, following device changes). Once media flows, the camera track is listed in your signaling state. Pulling other participants' tracks comes with `Room` (roadmap M3).

The **Local media** button (camera-and-mic icon in the app bar) opens a local preview: camera and microphone toggles with device dropdowns, the mute model, and on desktop a screen and window picker with thumbnails that previews the chosen share. On the web, the browser shows its own picker. Nothing is published yet.

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

`CF_REALTIME_ROOM` sets the room (default `integration-test`). On desktop the same names can come from the environment instead. Keep credentials out of the repository and out of shell history you share.
