# Week-6 checkpoint runbook

This runbook demonstrates the three go/no-go criteria from the [roadmap](roadmap.md#consumer-checkpoint-week-6) with the example app ([`example/`](../example/)) and the DEV ONLY local server ([`tools/dev-server/`](../tools/dev-server/README.md)):

1. **Calls work:** a 1:1 and a 4-person call on Windows, macOS and Android.
2. **Simulcast layer switching** works.
3. **Recovery:** a call recovers from a network drop.

You don't need to know the codebase. Work through the sections in order, and fill in the [results table](#6-results) as you go.

> **Never paste real credentials** (the App Secret, TURN token or dev token) into issues, chat, screenshots or shared terminal logs. They live in `tools/dev-server/.env`, which git ignores. This repository is public.

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Start the dev server](#2-start-the-dev-server)
3. [Build and run the example on each device](#3-build-and-run-the-example-on-each-device)
4. [The call screen](#4-the-call-screen)
5. [The three criteria](#5-the-three-criteria)
6. [Results](#6-results)
7. [Integration tests against the dev server](#7-integration-tests-against-the-dev-server)
8. [Troubleshooting](#8-troubleshooting)

## 1. Prerequisites

### Cloudflare

- A **Cloudflare Realtime SFU app**: Cloudflare dashboard → Realtime → SFU. Note its **App ID** and **App Secret**.
- Optional: a **TURN key** (dashboard → Realtime → TURN): its **key ID** and an **API token**. You need TURN only when a device's network blocks UDP (some office or guest Wi-Fi). See [Troubleshooting](#turn-and-different-networks).

### The machine that runs the dev server

Any of the laptops below will do. The dev server must stay online during the whole run, so **don't run it on a device whose network you will drop** in criterion 3.

- **Node.js 22.12 or later** (`node --version`).
- A clone of this repository.

### Every device

All devices must be on **the same LAN or Wi-Fi**, with internet access. Media flows between each device and Cloudflare, but broker calls and presence go to the dev server on your LAN.

| Device | Needs |
|---|---|
| All build machines | **Flutter 3.47.3** (Dart 3.13.3): `flutter --version`. Run `flutter doctor` and fix what it reports for your target. |
| Windows 10/11 | **Visual Studio 2022 17.14 or later** with the **Desktop development with C++** workload and the **C++ ATL for latest build tools** component (Build Tools 17.12 are too old and lack ATL). **Developer Mode** on (Settings → System → For developers), because Flutter plugins need symlinks. A webcam and a microphone. |
| macOS | **Xcode** with its command-line tools, which `flutter doctor` must report as OK. A camera and a microphone (built in is fine). |
| Android | A physical phone or tablet with **USB debugging** on (Settings → About phone → tap *Build number* 7 times, then Developer options → USB debugging), connected by USB and authorized (`adb devices` lists it as `device`). The Android SDK, from Android Studio. |

For the **4-person call** you need four participants. Use Windows, macOS and Android, plus one of:

- a second Android device;
- Chrome on any computer (`flutter run -d chrome`; see [step 3](#3-build-and-run-the-example-on-each-device));
- a second copy of the app on a desktop that already runs one (see [step 3](#a-second-participant-on-the-same-desktop)).

## 2. Start the dev server

On the server machine, from the repository root:

```sh
cd tools/dev-server
npm ci
cp .env.example .env
```

Edit `.env`:

| Variable | Value |
|---|---|
| `REALTIME_DEV_SERVER` | `1` (required: the server refuses to start without it) |
| `CF_REALTIME_APP_ID` | your SFU App ID (required) |
| `CF_REALTIME_APP_SECRET` | your SFU App Secret (required) |
| `CF_TURN_KEY_ID`, `CF_TURN_API_TOKEN` | optional: your TURN key ID and API token. Without them, clients get Cloudflare STUN only. |
| `DEV_TOKEN` | recommended: a fixed random token of at least 16 characters, so the `--dart-define`s below stay valid across server restarts. Generate one with `node -e "console.log(require('crypto').randomBytes(24).toString('base64url'))"`. Without it, the server makes a new one at every start. |

Then start it so that the other devices can reach it:

```sh
npm start -- --host 0.0.0.0
```

It prints a DEV ONLY banner, which settings are set (never their values), the dev token if it generated one, and a **`Server URL`** for each LAN address, such as `http://192.168.1.10:8787`. Pick the one on the Wi-Fi or LAN the other devices use (not a VPN, WSL or VirtualBox adapter). Below, `<SERVER>` means that URL and `<TOKEN>` the dev token.

**Check reachability from every device** before building anything: open `<SERVER>/healthz` in a browser on each device (including the phone). It must show `{"ok":true}`. If it doesn't, see [Firewall](#firewall-and-reachability).

Leave the server running. Stop it with Ctrl+C when you're done. See the [dev server README](../tools/dev-server/README.md) for its other options (`--port`, `--env-file`, `--heartbeat-ms`).

## 3. Build and run the example on each device

On each build machine, from the repository root:

```sh
cd example
flutter pub get
```

Each device joins with its own user name. The example reads three `--dart-define`s ([`example/lib/dev_config.dart`](../example/lib/dev_config.dart)); with all three set, the join screen opens with **Dev server (multi-device)** selected and the fields filled in:

| Define | Value |
|---|---|
| `DEV_SERVER_URL` | `<SERVER>`, for example `http://192.168.1.10:8787`. Use the LAN address on every device, even on the server machine. |
| `DEV_TOKEN` | `<TOKEN>` |
| `DEV_USER` | a name for this device, such as `win`, `mac`, `android` (printable ASCII, up to 64 characters) |

One more define is optional: `VIDEO_CODEC` (default `video/VP8`) sets the video codec every participant sends. Keep the default for the checkpoint; `--dart-define=VIDEO_CODEC=default` uses the platform's own codec order instead (see [Windows H.264](#windows-h264-crash)).

**Windows:**

```sh
flutter run -d windows --dart-define=DEV_SERVER_URL=<SERVER> --dart-define=DEV_TOKEN=<TOKEN> --dart-define=DEV_USER=win
```

**macOS:**

```sh
flutter run -d macos --dart-define=DEV_SERVER_URL=<SERVER> --dart-define=DEV_TOKEN=<TOKEN> --dart-define=DEV_USER=mac
```

**Android** (physical device). Find its ID with `flutter devices` (the second column, such as `R58M12ABCDE`), then:

```sh
flutter run -d <android-id> --dart-define=DEV_SERVER_URL=<SERVER> --dart-define=DEV_TOKEN=<TOKEN> --dart-define=DEV_USER=android
```

Use the default debug mode (no `--release` or `--profile`): only debug builds allow the cleartext `http://` and `ws://` connections to the dev server (see [Android cleartext](#android-cleartext-http)).

**Chrome** (optional fourth participant):

```sh
flutter run -d chrome --dart-define=DEV_SERVER_URL=<SERVER> --dart-define=DEV_TOKEN=<TOKEN> --dart-define=DEV_USER=web
```

If Chrome blocks autoplay, the call screen shows **"Your browser blocked the call audio. Click to enable audio."**; click it.

### A second participant on the same desktop

Each copy needs its own user name. On Windows, while the first copy runs under `flutter run`, start the same build a second time from `example/`:

```sh
build\windows\x64\runner\Debug\cloudflare_realtime_example.exe
```

It opens with the first copy's defines filled in; change **User name** on the join screen before joining. The second copy may not get the camera (Windows cameras are usually exclusive); its microphone and presence still count, and a camera failure only shows a message. On macOS, a second copy of the same app doesn't start this way; use Chrome or a second Android device instead.

### Join

On every device, check the join screen: **Signaling** = *Dev server (multi-device)*, **Room ID** = `demo` (the default; use the same room everywhere), then press **Join**. macOS and Android ask for camera and microphone access the first time; allow both. macOS 15 and later may also ask for **Local Network** access; allow it.

Each device publishes its microphone and camera as soon as the call screen opens.

## 4. The call screen

What you'll use, from [`example/lib/call_page.dart`](../example/lib/call_page.dart):

- **App bar** (left to right): the room ID; a **status chip** `media: <state> · signaling: <state>` (green cloud when both are `connected`); the **layout toggle** (tooltip *Stage layout* / *Gallery layout*); **Simulate network drop (debug)** (Wi-Fi-off icon); **Leave**.
- **Bottom bar:** microphone, camera, **Share screen** / **Stop sharing**, and the red **Leave call**.
- **Tiles:** yours (labelled *(you)*), then each remote camera and screen share. A green outline means speaking; a star marks the dominant speaker.
- **Layer overlay** (top right of every remote video tile): `rid <rid> (<mode>) · <width>×<height> <fps>fps`, for example `rid b (auto) · 640×360 30fps`.
  - `rid` is the simulcast layer this device asks the SFU for: `a` = full (1280×720 for the default camera), `b` = half (640×360), `c` = quarter (320×180).
  - `mode` is `auto` (chosen from the tile's size on screen) or the layer you forced (`high`, `medium`, `low`).
  - The resolution and frame rate are what this device actually receives, read from `getStats()` once a second.
  - `hidden` appears while the tile is off screen.
- **Layer menu:** click or tap the overlay on a gallery tile or on the stage tile (not on the small stage thumbnails): *Auto (from tile size)*, *High (a)*, *Medium (b)*, *Low (c)*.
- **Stage layout:** one big tile (the one you pinned; else a remote screen share; else the dominant speaker; else the first remote) and a strip of small thumbnails. Tap a thumbnail to pin it to the stage; double-tap the stage to unpin.
- **Messages** (at the bottom): *X joined.*, *X left.*, *Connection lost (\<reason\>). Reconnecting…*, *Reconnected in N s*, and a **Reconnecting… your camera and microphone keep running.** banner under the app bar while the room replaces its connection.

## 5. The three criteria

### Criterion 1: calls work

**1:1 calls.** Run each pair on its own, with only those two devices in room `demo`: Windows ↔ macOS, Windows ↔ Android, macOS ↔ Android. For each pair:

1. Join on both devices.
2. Within about 5 s, each device shows *\<other\> joined.* and a tile with the other's camera. The status chip reads `media: connected · signaling: connected` on both.
3. **Video:** wave at each camera; the other side sees it with less than about a second of delay.
4. **Audio:** speak on one device; the other hears it, and the speaker's tile gets a green outline. Use headphones on at least one side, or keep the devices in separate rooms, to avoid echo.
5. **Mute:** mute the microphone on one side; the other side's tile shows the crossed-out microphone and hears nothing. Unmute. Turn the camera off and on; the other side sees the placeholder, then the video again.
6. **Screen share** (Windows and macOS only; mobile screen share isn't part of the checkpoint): press **Share screen**, pick a screen, keep *Text* selected. The other side's stage layout puts the share on the stage, fitted inside the tile (`contain`), with text readable at full size. Press **Stop sharing**; the share disappears on the other side. On macOS, see [Screen Recording](#macos-permissions) if the share is empty.
7. Press **Leave call** on one device; the other shows *\<name\> left.* and the tile disappears.

**4-person call.** Join with all four participants (Windows, macOS, Android, plus the fourth from [Prerequisites](#every-device)):

1. Every device shows three remote tiles, each with live video, and hears every other participant.
2. Leave the call running for **at least 5 minutes**, talking in turns. Audio and video keep flowing; the speaking outline follows whoever talks.
3. Leave and rejoin one participant; everyone else sees it leave and come back.

**Pass:** every pair and the 4-person call meet all the steps above on every device.

### Criterion 2: simulcast layer switching

Use the 4-person call (or any call with at least two devices). Do this on each receiving platform (Windows, macOS, Android), watching one remote camera tile:

1. **Gallery.** In the gallery layout, the overlay shows `(auto)` with `rid b` or `rid c`, depending on the tile's size in physical pixels (display scaling counts): a tile up to 270 physical pixels high gets `c`, up to 540 gets `b`, anything bigger `a`. The received resolution matches within about 3 s: 640×360 for `b`, 320×180 for `c`.
2. **Stage.** Press the layout toggle (*Stage layout*). The stage tile goes to `rid a` and receives 1280×720 within about 3 s. The thumbnails go to `rid c` (320×180). On small screens (phones) the stage may stay at `b`: that's the tile size rule, not a failure.
3. **Resize** (desktop): shrink the window. The stage tile steps down to `b` or `c` about 0.3 s after its size settles (it drops from `a` only below 459 physical lines, to avoid flapping), and back up when you enlarge it.
4. **Manual override.** On the stage tile (or a gallery tile), open the layer menu and pick *Low (c)*. The overlay shows `rid c (low)` at once, and 320×180 within about 3 s. Pick *High (a)*: `rid a (high)`, then 1280×720. Pick *Medium (b)*: 640×360. Pick *Auto (from tile size)* to go back.
5. **Pin:** tap a thumbnail to pin it to the stage; the pinned participant's overlay goes to `a` and the one that left the stage to `c`.

**Pass:** on each receiving platform, the received resolution follows both the automatic choice and the manual picks, for publishers on each platform.

Notes:

- The SFU switches layers at the next keyframe, so a switch takes 1–3 s to show in the resolution; the `rid` changes at once.
- A publisher only sends `a` when its uplink allows about 1.2 Mbps more than `b` and `c`. On a weak uplink the receiver can ask for `a` and get `b` (the SFU falls back to the next layer: `ridNotAvailable: asciibetical`). Check the publisher's network before failing this.
- A camera that captures below 960×540 (some Windows webcams give 640×480) sends only two layers, `a` and `b`; asking for `c` then gets the nearest layer that exists.

### Criterion 3: recovery from a network drop

Run both parts with at least three participants, and **never drop the network of the machine running the dev server**.

**Part A: simulated drop** (every platform). On one device, press **Simulate network drop (debug)**:

1. At once: *Connection lost (peerConnectionFailed). Reconnecting…*, the reconnecting banner, and `media: reconnecting` in the status chip. Camera and microphone keep capturing (your own tile stays live).
2. Within about 1–3 s: *Reconnected in N s* (typically N < 3), the banner goes away, and the chip is back to `media: connected`.
3. The other devices see this device's video freeze or show the placeholder for a moment, then continue, with no *left* / *joined* messages (presence stayed up). Audio returns both ways.
4. Repeat on each platform (Windows, macOS, Android).

**Part B: real drop, 10–20 s** (each of Windows, macOS, Android, one at a time). On the dropped device:

| Platform | Drop | Restore |
|---|---|---|
| Windows | Quick settings → Wi-Fi off (or airplane mode) | Wi-Fi on |
| macOS | Wi-Fi menu → turn Wi-Fi off | turn Wi-Fi on |
| Android | Quick settings → airplane mode on (**turn mobile data off first**, or the phone switches to it instead of dropping) | airplane mode off (Wi-Fi reconnects) |

If the device also has Ethernet, unplug it, or it won't lose the network. Time it with a stopwatch: drop at t = 0, restore at t = 15 s.

What to expect (the design is in [design.md §8](design.md#8-reconnection)):

| When | Dropped device | Other devices |
|---|---|---|
| 0–7 s | *Connection lost (…). Reconnecting…* and the banner; the reason is `networkChanged` or `disconnectedTooLong`. The example polls network interfaces every 2 s, and a network change while disconnected re-sessions at once. Retries fail quietly while offline, spaced by backoff (up to 10 s apart). | Its video freezes. |
| about 4–6 s | The chip may show `signaling: reconnecting` (up to 10 s of silence). | The dev server drops its socket (2 s heartbeat): *\<name\> left.* and its tiles disappear. |
| 15 s: network restored | The network change cuts the backoff wait short; the room creates a new session and republishes the same tracks without restarting capture. *Reconnected in N s* (N ≈ the outage plus a few seconds). Presence rejoins with backoff (within about 10 s). | *\<name\> joined.*, and its video and audio return. |

**Pass:** within **30 s of restoring the network**, without touching the app, the dropped device sees and hears everyone, and everyone sees and hears it, on each of Windows, macOS and Android.

If the outage lasts more than 2 minutes, the room gives up: *Could not reconnect. Use "Reconnect" to try again.* and a **Disconnected from the call** strip with a **Reconnect** button. Restoring the network also retries by itself. This isn't part of the criterion, but it's worth seeing once.

## 6. Results

Record the date, the commit (`git rev-parse --short HEAD`), and the device models and OS versions. Mark each cell **Pass**, **Fail** (with a note) or **n/a**.

| # | Scenario | Win ↔ Mac | Win ↔ Android | Mac ↔ Android | 4-person |
|---|---|---|---|---|---|
| 1a | Join, see and hear each other | | | | |
| 1b | Mute / camera off and on | | | | |
| 1c | Screen share shown on the stage, stopped cleanly (desktop sharer) | | | | n/a |
| 1d | Leave and rejoin | | | | |
| 1e | 5 minutes stable | n/a | n/a | n/a | |

| # | Layer switching, seen on | Windows | macOS | Android |
|---|---|---|---|---|
| 2a | Gallery: automatic `b`/`c`, resolution matches | | | |
| 2b | Stage `a` (1280×720), thumbnails `c` | | | |
| 2c | Manual *Low* / *High* / *Medium* / *Auto* | | | |
| 2d | Publisher platforms received (list them) | | | |

| # | Recovery, dropped device | Windows | macOS | Android |
|---|---|---|---|---|
| 3a | Simulated drop: reconnected in < 5 s | | | |
| 3b | Real 10–20 s drop: back within 30 s of restoring | | | |
| 3c | Capture not restarted (own tile stayed live) | | | |
| 3d | Integration tests ([section 7](#7-integration-tests-against-the-dev-server)) | | | |

The checkpoint passes when every applicable cell passes.

## 7. Integration tests against the dev server

The example has three integration tests in [`example/integration_test/`](../example/integration_test/), which run against a real broker:

- `sfu_loopback_test.dart`: publishes a camera (or microphone) track on one SFU session and pulls it on another, switching the pulled layer.
- `datachannel_echo_test.dart`: a DataChannel echoed both ways.
- `reconnect_test.dart`: two rooms in one process; the publisher's session is dropped and replaced, then the subscriber's, and the track must arrive again each time (criterion 3, automated).

They are skipped unless a broker URL is set. Settings ([`broker_settings.dart`](../example/integration_test/broker_settings.dart)), as `--dart-define`s or, on desktop, environment variables:

| Name | Value for the dev server |
|---|---|
| `CF_REALTIME_BROKER_URL` | `<SERVER>` (required) |
| `CF_REALTIME_BROKER_TOKEN` | `<TOKEN>` (sent as `Authorization: Bearer`) |
| `CF_REALTIME_BROKER_USER` | a user name, such as `it-windows` (sent as `X-Dev-User`; the dev server rejects requests without it) |
| `CF_REALTIME_ROOM` | optional; default `integration-test` |

Run them on each platform, from `example/`:

```sh
flutter test integration_test -d windows --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-windows
flutter test integration_test -d macos --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-macos
flutter test integration_test -d <android-id> --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-android
```

One file at a time: `flutter test integration_test/reconnect_test.dart -d windows ...`. Expect `All tests passed!` with no test reported as skipped; skipped tests mean `CF_REALTIME_BROKER_URL` didn't arrive. Accept the camera and microphone prompts on macOS and Android. The tests never print the settings; keep them out of shared shell history.

## 8. Troubleshooting

### Firewall and reachability

- `<SERVER>/healthz` must load on every device ([step 2](#2-start-the-dev-server)). If it doesn't, nothing else will work.
- **Windows (server machine):** the first `--host 0.0.0.0` start opens a Windows Defender Firewall prompt for `node.exe`; allow it on **Private** networks, and set the Wi-Fi profile to Private. Or add a rule from an elevated prompt, and remove it afterwards:

  ```sh
  netsh advfirewall firewall add rule name="cloudflare_realtime dev server" dir=in action=allow protocol=TCP localport=8787 profile=private
  ```

- **macOS (server machine):** with the firewall on, allow incoming connections for `node` when asked (System Settings → Network → Firewall).
- Guest Wi-Fi and many office networks isolate clients from each other. Use a home network, or a phone hotspot that every device (including the server machine) joins.
- Pick the right `Server URL`: not `127.0.0.1` on other devices, and not a VPN, WSL, Docker or VirtualBox address.

### Android cleartext HTTP

Android blocks cleartext `http://` and `ws://` by default. The example allows it in **debug builds only** ([`network_security_config.xml`](../example/android/app/src/debug/res/xml/network_security_config.xml)). Symptoms in release or profile builds: joining fails with a network error while `/healthz` loads in the phone's browser. Run with plain `flutter run` (debug). An Android **emulator** reaches the host through `http://10.0.2.2:8787`, but use a physical device for the checkpoint.

### macOS permissions

- **Camera and microphone:** macOS asks on first use. If you denied them, allow the app in System Settings → Privacy & Security → Camera / Microphone, then quit and restart it.
- **Local Network** (macOS 15 and later): allow the prompt on the first connection to `<SERVER>`; change it later in System Settings → Privacy & Security → Local Network.
- **Screen Recording:** needed to share the screen. There's no entitlement for it; macOS asks on the first share. If it was denied, the share dialog shows *This app may not have permission to record the screen…*, or after sharing the call screen shows **Your screen share is empty** (after about 8 s without frames). Open System Settings → Privacy & Security → **Screen & System Audio Recording** (*Screen Recording* on macOS 14 and earlier), turn on `cloudflare_realtime_example`, then **quit and reopen the app**: macOS applies it only after a restart. A rebuilt debug app can count as a new app and be asked again. To start over: `tccutil reset ScreenCapture dev.kammcs.cloudflareRealtimeExample`.
- The sandboxed example already has the entitlements it needs (`example/macos/Runner/*.entitlements`: network client, camera, audio input).

### Windows H.264 crash

`flutter_webrtc` on Windows has crashed with H.264 video (flutter-webrtc #982). The package sends VP8 from every platform by default (and so does the example: its `VIDEO_CODEC` define defaults to `video/VP8`), because the SFU forwards each publisher's codec unchanged, so a Windows receiver would otherwise decode a Mac's or phone's H.264. If a Windows device crashes when another participant joins, check that no device was started with `--dart-define=VIDEO_CODEC=default` or `video/H264`.

### TURN and different networks

- Media goes from each device to Cloudflare over UDP. If a network blocks UDP, video never connects (the status chip stays at `media: connecting`, and the room re-sessions after 15 s). Set `CF_TURN_KEY_ID` and `CF_TURN_API_TOKEN` in `.env` and restart the dev server; clients then also get TURN servers (TURN over TCP and TLS work where UDP doesn't).
- Devices on **different networks** (say, a phone on cellular) can't reach the dev server on your LAN. The dev server is DEV ONLY and not built to be exposed to the internet. Put every device on the same network instead (a phone hotspot works), and use TURN if that network blocks UDP.

### Other symptoms

| Symptom | Likely cause |
|---|---|
| Join fails with `401` | Wrong dev token, or `DEV_USER` isn't printable ASCII. The dev server makes a new token at every start unless `DEV_TOKEN` is set in `.env`. |
| Join fails with a network or timeout error | The server isn't reachable: see [Firewall](#firewall-and-reachability). |
| `signaling: reconnecting` that never settles | Same as above, for the WebSocket; or another device joined with the same participant ID (each run generates one, so this is rare). |
| A tile stays on the placeholder | The publisher's camera is off or failed (it shows a message), or the pull failed: wait a few seconds; pulls retry with backoff. |
| Windows build fails about ATL or the toolset | Install VS 2022 17.14+ with *C++ ATL for latest build tools*. |
| Windows build fails about symlinks | Turn on Developer Mode. |
| Echo or feedback | Two devices in the same room without headphones. |
