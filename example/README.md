# cloudflare_realtime example

A demo app for [`cloudflare_realtime`](../README.md).

For now it joins a room through `InMemorySignaling`: every participant lives in the same process and shares one `InMemorySignalingHub`. Add simulated participants to watch the list update. Video tiles will replace the placeholder once the SFU session and rooms land (roadmap M2 and M3).

The **Local media** button (camera-and-mic icon in the app bar) opens a local preview: camera and microphone toggles with device dropdowns, the mute model, and on desktop a screen and window picker with thumbnails that previews the chosen share. On the web, the browser shows its own picker. Nothing is published yet.

```sh
cd example
flutter run -d macos   # or windows, android, ios, chrome
```

The platform folders already declare what later milestones need: camera, microphone and network permissions on Android, iOS and macOS.
