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

All devices must be on **the same LAN or Wi-Fi**, with internet access. Media flows between each device and Cloudflare, but broker calls and presence go to the dev server on your LAN. (An Android phone plugged into the server machine by USB can reach the dev server through `adb reverse` instead; see [step 3](#3-build-and-run-the-example-on-each-device).)

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

If your credentials live in a `.env` at the repository root instead (also gitignored), point the server at it: `npm start -- --host 0.0.0.0 --env-file ../../.env`. Real environment variables, such as `REALTIME_DEV_SERVER=1` set in the shell, take precedence over the file.

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

**Android over USB, without the LAN.** If the phone is connected by USB to the machine that runs the dev server, `adb reverse` forwards the phone's port 8787 to that machine, so the phone needs no LAN route, firewall rule or `--host 0.0.0.0`:

```sh
adb -s <android-id> reverse tcp:8787 tcp:8787
flutter run -d <android-id> --dart-define=DEV_SERVER_URL=http://127.0.0.1:8787 --dart-define=DEV_TOKEN=<TOKEN> --dart-define=DEV_USER=android
```

The forward lasts until the phone is unplugged or `adb reverse --remove tcp:8787`. Only the dev server's traffic goes over USB; media still goes from the phone to Cloudflare over its own network. For the [real network drop](#criterion-3-recovery-from-a-network-drop), the dev server stays reachable over USB while Wi-Fi is off, so presence stays up: the other devices see no *left* / *joined* messages for the phone. The media recovery is the same; to see the whole table there, use the LAN address instead.

**iOS** (physical device, connected by USB). Running on an iPhone needs your Apple signing team, which stays out of the repository: create `example/ios/Flutter/Signing.xcconfig` (git ignores it) with one line, `DEVELOPMENT_TEAM = <your team ID>` (Xcode → Settings → Accounts shows it). Then, with the ID from `flutter devices`:

```sh
flutter run -d <iphone-id> --dart-define=DEV_SERVER_URL=<SERVER> --dart-define=DEV_TOKEN=<TOKEN> --dart-define=DEV_USER=iphone
```

Allow the **Local Network** prompt (the app can't reach the dev server, and `flutter` can't find the app's Dart VM Service, until you do), then Camera and Microphone. iOS keeps the answers until the app is deleted. Debug builds can reach `http://` on the LAN without an App Transport Security exception: Dart's HTTP client doesn't go through Apple's URL loading.

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
- **Bottom bar:** microphone, camera, **Switch camera**, the **audio output** (on phones: a sheet of the speaker, the phone's earpiece and connected headsets; a voice call starts on the earpiece and moves to the speaker when there is video) (while the camera is on: front ↔ back on a phone, the next camera on a desktop), **Share screen** / **Stop sharing**, and the red **Leave call**.
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
5. **Mute:** mute the microphone on one side; the other side's tile shows the crossed-out microphone and hears nothing. Unmute. Turn the camera off and on; the other side sees the placeholder, then the video again. Press **Switch camera** on the phone; the other side sees the back camera within a second, and the phone's self-view stops being mirrored. Press it again to go back.
6. **Screen share** (Windows and macOS only; mobile screen share isn't part of the checkpoint): press **Share screen**, pick a screen, keep *Text* selected. The other side's stage layout puts the share on the stage, fitted inside the tile (`contain`), with text readable at full size. Press **Stop sharing**; the share disappears on the other side. On macOS, see [Screen Recording](#macos-permissions) if the share is empty.
7. Press **Leave call** on one device; the other shows *\<name\> left.* and the tile disappears.

**4-person call.** Join with all four participants (Windows, macOS, Android, plus the fourth from [Prerequisites](#every-device)):

1. Every device shows three remote tiles, each with live video, and hears every other participant.
2. Leave the call running for **at least 5 minutes**, talking in turns. Audio and video keep flowing; the speaking outline follows whoever talks.
3. Leave and rejoin one participant; everyone else sees it leave and come back.

**Pass:** every pair and the 4-person call meet all the steps above on every device.

### Criterion 2: simulcast layer switching

Use the 4-person call (or any call with at least two devices). Do this on each receiving platform (Windows, macOS, Android), watching one remote camera tile:

1. **Gallery.** In the gallery layout, the overlay shows `(auto)` with `rid b` or `rid c`, depending on the tile's size in physical pixels (display scaling counts): a tile up to 270 physical pixels high gets `c`, up to 540 gets `b`, anything bigger `a`. The received resolution matches within about 15 s (see the notes below): 640×360 for `b`, 320×180 for `c`.
2. **Stage.** Press the layout toggle (*Stage layout*). The stage tile goes to `rid a` and receives 1280×720 within about 15 s. The thumbnails go to `rid c` (320×180). On small screens (phones) the stage may stay at `b`: that's the tile size rule, not a failure.
3. **Resize** (desktop): shrink the window. The stage tile steps down to `b` or `c` about 0.3 s after its size settles (it drops from `a` only below 459 physical lines, to avoid flapping), and back up when you enlarge it.
4. **Manual override.** On the stage tile (or a gallery tile), open the layer menu and pick *Low (c)*. The overlay shows `rid c (low)` at once, and 320×180 within about 15 s. Pick *High (a)*: `rid a (high)`, then 1280×720. Pick *Medium (b)*: 640×360. Pick *Auto (from tile size)* to go back.
5. **Pin:** tap a thumbnail to pin it to the stage; the pinned participant's overlay goes to `a` and the one that left the stage to `c`.

**Pass:** on each receiving platform, the received resolution follows both the automatic choice and the manual picks, for publishers on each platform.

Notes:

- The SFU switches layers at a keyframe of the new layer, so the resolution follows the `rid` (which changes at once) after a delay. Against the real SFU (October 2026, Windows ↔ Android, Windows ↔ macOS, Android ↔ macOS and iOS ↔ macOS, `cross_device_test.dart`), a switch usually took **8–13 s**, sometimes 1–4 s. The delay was strikingly regular (about 8.3 s for the first two switches and 12.4 s for the third, in both directions and with either device publishing; macOS, Android and iOS receivers saw the same: 8.1–8.8 s, then 12.2–12.7 s), and the `tracks/update` call itself answers at once, which points at the SFU rather than either client. Wait about 15 s before failing a switch.
- A publisher only sends `a` when its uplink allows about 1.2 Mbps more than `b` and `c`. On a weak uplink the receiver can ask for `a` and get `b` (the SFU falls back to the next layer: `ridNotAvailable: asciibetical`). Check the publisher's network before failing this.
- A camera that captures below 960×540 (some Windows webcams give 640×480) sends only two layers, `a` and `b`; asking for `c` then gets the nearest layer that exists.
- Since M12 publishers announce the size they capture, so a phone held upright shows as portrait (720×1280 for `a`) and its layers are picked for portrait tiles.
- Sometimes the SFU never switches up: the overlay says `rid a` and the resolution stays at `b` (seen in M12 runs on a Pixel 10, with every layer on, [design.md §6.2](design.md#62-publisher-side-layer-pausing-m12)). Note it in the results. Switching to another layer and back didn't help in those runs; a new pull of the track (close the tile long enough to release it, then reopen it) got the layer.

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
| 15 s: network restored | The network change cuts the backoff wait short, or abandons an attempt still stuck on the old network (`[reconnect] attempt N (…): network changed, attempt N-1 abandoned, no backoff`); the room creates a new session and republishes the same tracks without restarting capture. *Reconnected in N s* (N ≈ the outage plus a few seconds). The same network change cuts the signaling's backoff short, so presence rejoins within a few seconds too; a connect that hangs (one started while offline) is abandoned after 10 s. The console's `[signaling]` lines give the timeline next to `[reconnect]`. | *\<name\> joined.*, and its video and audio return. |

**Pass:** within **30 s of restoring the network**, without touching the app, the dropped device sees and hears everyone, and everyone sees and hears it, on each of Windows, macOS and Android.

If the outage lasts more than 2 minutes, the room gives up: *Could not reconnect. Use "Reconnect" to try again.* and a **Disconnected from the call** strip with a **Reconnect** button. Restoring the network also retries by itself. This isn't part of the criterion, but it's worth seeing once.

## 6. Results

Record the date, the commit (`git rev-parse --short HEAD`), and the device models and OS versions. Mark each cell **Pass**, **Fail** (with a note) or **n/a**.

| # | Scenario | Win ↔ Mac | Win ↔ Android | Mac ↔ Android | 4-person |
|---|---|---|---|---|---|
| 1a | Join, see and hear each other | Pass (checked during the 4-person session, not as a pair alone) | Pass (Windows mic: wrong input picked among many devices; see notes) | Pass after a fix (the Mac's microphone sent silence at `16a5805`; see notes) | Pass (Windows, macOS, Pixel 10, iPhone) |
| 1b | Mute / camera off and on | Pass (checked during the 4-person session, not as a pair alone) | Pass (Android local preview flickers; see notes) | Pass | Pass |
| 1c | Screen share shown on the stage, stopped cleanly (desktop sharer) | Pass (checked during the 4-person session, not as a pair alone) | Pass | Pass (Mac sharer) | n/a |
| 1d | Leave and rejoin | Pass (checked during the 4-person session, not as a pair alone) | Pass (rejoin in ~6.5 s, fresh session) | Pass | Pass (the others saw it back 2.8 s after it left) |
| 1e | 5 minutes stable | n/a | n/a | n/a | Pass (5+ minutes, no re-session, no presence drop) |

| # | Layer switching, seen on | Windows | macOS | Android |
|---|---|---|---|---|
| 2a | Gallery: automatic `b`/`c`, resolution matches | Pass (Pixel camera at `b`, 360×640) | Pass | Pass |
| 2b | Stage `a` (1280×720), thumbnails `c` | Pass (Pixel thumbnail `c` 180×320; Pixel camera on stage `a`) | Pass | Pass (Windows on stage `a` 1280×720 30 fps) |
| 2c | Manual *Low* / *High* / *Medium* / *Auto* | Pass | Pass (`cross_device_test`: low / high / low in 8.7 / 8.6 / 12.7 s from the Pixel, 8.7 / 8.2 / 12.2 s from Chrome) | Pass (2026-10-03, 4-person session) |
| 2d | Publisher platforms received (list them) | Android (camera, front and back; screen 1080×2424) | Android (camera; see notes on its layer sizes), Chrome (fake camera) | Windows (camera, screen), macOS (camera) |

| # | Recovery, dropped device | Windows | macOS | Android |
|---|---|---|---|---|
| 3a | Simulated drop: reconnected in < 5 s | Pass (~1.1 s server-side, presence kept) | Pass | Pass (2026-10-03, 4-person session) |
| 3b | Real 10–20 s drop: back within 30 s of restoring | Pass, accepted by the owner (recovered 61 s after link-up; the setup was confounded because the dev server shared the dropped network) | Pass after a fix (Ethernet out for 18 s: presence back 0.5 s and media 6.9 s after link-up; see notes) | Pass (~1 s after LTE took over from Wi-Fi) |
| 3c | Capture not restarted (own tile stayed live) | Pass | Pass (simulated drop) | Pass |
| 3d | Integration tests ([section 7](#7-integration-tests-against-the-dev-server)) | Pass (2026-10-02, M13) | Pass (2026-10-03, every file; see notes) | Pass (Pixel 10, M2–M12 runs) |

The checkpoint passes when every applicable cell passes.

**Run notes.**

- **2026-10-03, Win ↔ Android** (commit `300ea41`; Windows 11 with the example in debug, Pixel 10 with Android 16 over `adb reverse`; dev server on Windows). Media and screen share worked both ways.
  - On a Windows machine with many audio inputs, the call used an input the user doesn't use, and there was no way to pick another from the call screen.
  - The Pixel's own camera preview flickered to the background every few seconds, like a rebuilt widget. Windows received the Pixel's video without gaps, so only the local preview was affected.
  - **Both fixed** (merge `634bf4e`):
    - The Windows backend now marks the system default communications devices through Core Audio, and the default ranks first. The call screen has a Devices sheet with mic, camera and speaker pickers that switch live.
    - The tiles keep the same widget tree when the speaking highlight changes, so renderers are no longer re-created. This fix is verified on the Pixel by hand.
- **2026-10-03, second pass** (example build `06ed94f`, room `cp-3`). The re-checks passed:
  - the Windows mic is the system default (SteelSeries Sonar) with a level meter;
  - the Pixel's self-view is steady;
  - the Pixel's app bar reaches the stage toggle;
  - the Pixel's screen stays on during video;
  - a remote screen share switches the viewer to the stage.
- **3b on Windows:**
  - The NIC was down from 09:55:55Z to 09:56:16Z. Every retry failed until 09:57:17Z, then the re-push and re-pull finished within 1.2 s.
  - The dev server (the broker) ran on the same PC, so the broker lost its network too. Production brokers don't.
  - Accepted as a pass by the project owner on 2026-10-03: the call recovered by itself, and the delay is attributed to the test setup. A cleaner re-run would drop the client's network alone.
- **3b on Android:** Wi-Fi was turned off at 09:59:12Z. The app re-sessioned at once (its broker path stayed up over USB). Media came back at 09:59:26Z, about 1 s after the phone moved to LTE.
- **2026-10-03, 4-person** (commit `c949bac`; Windows 11, MacBook Pro with macOS 27, Pixel 10 with Android 16, iPhone 16 Pro Max with iOS 27 as a profile build; dev server on Windows; room `demo`). All four joined by 16:47:33Z; every device showed three live remote tiles and heard the other three for more than 5 minutes, with no re-session and no presence drop in the Mac's or the Pixel's log. One participant left at 16:54:17Z and was back at 16:54:20Z. Layer switching, mute and camera off and on behaved as in the 1:1 runs. Windows ↔ Mac (rows 1a–1d) was checked by the owner in the same session rather than with the two alone in a room. The Pixel logged a `NullPointerException` from flutter_webrtc's `MethodCallHandlerImpl` at join (asking Android for a description that didn't exist yet); it is caught and the call connected 0.8 s later.
- **2026-10-03, Mac ↔ Android** (commit `16a5805`; MacBook Pro with macOS 27.0, built with Xcode 27.0; Pixel 10 with Android 16 on the LAN; dev server on Windows). By hand: everything but the Mac's microphone passed, the Mac's screen share included.
  - **The Mac's microphone sent silence.** The Mac's system default input is *BlackHole 16ch*, a virtual loopback device, and the call opened it (`CoreAudio ADM: Selected input device: BlackHole 16ch`). Choosing *MacBook Pro Microphone* in the Devices sheet, and muting and unmuting, changed nothing: the switch never reached flutter_webrtc's audio device module on macOS (no new *Selected input device* line). `audio_routing_test` didn't catch it, because it only counts packets, which silence sends too. **Fixed** (merge after `09bdc75`): flutter_webrtc's macOS plugin skips the selection (`#if !defined(TARGET_OS_IPHONE)` is never true on Apple platforms), so the package now selects the input itself, and again 1–8 s after each switch because the audio device module sometimes falls back to the default ([design.md §4.5](design.md)); `microphone_capture_test.dart` checks it. Re-checked by hand the same day: the Pixel heard the MacBook Pro Microphone.
  - **Automated, the same day:** every integration test passed on macOS at the first try, with the machine heavily loaded (load average 150–800); `cross_device_test` passed macOS ↔ Pixel and macOS ↔ Chrome (headless, fake devices). `late_publish`: kept session 482 ms; without early connect one re-session, 7.3 s. `stats`: three VP8 layers 1280×720 / 640×360 / 320×180 at 30 fps, RTT 2 ms, `excellent`, `lost` after 8.0 s. `camera_switch`: FaceTime HD (640×480) → OBSBOT Virtual Camera (1920×1080) → back, 30–48 ms each. `publish_quality`: paused after 2.5 s, resumed in 83 ms, the subscriber reached `a` in 6.2 s; H.264 through VideoToolbox, three layers. `screen_awake`: `pmset -g assertions` showed the app's `PreventUserIdleDisplaySleep` assertion ("cloudflare_realtime: video call") from the video's start, released on mute, taken again on unmute and released on leave; none during the voice-only part.
  - **3b on macOS** (the Mac's only network is wired Ethernet; Wi-Fi on but not joined). First drop, at `0418f3c`: the call's media reconnected by itself 3 s after the link came back (18.6 s in all), but the Pixel saw the Mac again only after a long delay: the example's signaling had started a reconnect while offline, and `WebSocketChannel.connect` has no timeout (a connect into a dead route hung 75 s on this Mac). **Fixed in the example** (`WsSignaling` drops a connect after 10 s, and a network change cuts its backoff short or restarts a pending connect; `[signaling]` log lines). Second drop, after the fix: unplugged 15:33:15Z, back 15:33:33.23Z; signaling rejoined 4 ms later, the Pixel listed the Mac at 15:33:33.77Z (0.5 s), and media reconnected at 15:33:40.16Z (6.9 s, 19.4 s in all). The media took longer than the signaling because its `sessions/new`, started while offline, ran to its 15 s timeout: a network change didn't abort a broker request already in flight. **Fixed in the package** (branch `fix/resession-network-change`): a network change now abandons an attempt still waiting for its new session or for that session to connect, and starts the next one at once ([design.md §8.1](design.md#81-the-rooms-re-session-m5)); to re-check on the next real drop. Third drop, after the re-session fix (a network change abandons an attempt stuck on the old network): this time the requests made while offline failed at once (`BrokerNetworkException`, no dead route appeared), so no attempt hung and none was abandoned; Ethernet back about 17:19:01.3Z, signaling rejoined at 01.29 and the Pixel listed the Mac at 01.85, the network change cut the backoff short at 01.75, and media reconnected at 17:19:05.50Z (about 4.2 s after link-up, 3.75 s of it the new session's own setup). The abandon path is covered by unit tests (`test/room/room_reconnect_test.dart`, "a network change during an attempt").
  - **The Pixel's layer sizes:** in `cross_device_test` the Pixel announced layer heights 1280 / 640 / 320 (portrait 720×1280) but sent, and the Mac received, 960 / 480 / 240. The test passed. Cause: the Pixel has no VP8 hardware encoder, and libwebrtc's CPU adaptation scaled the software encoder's input to ¾ about 20 s in (`qualityLimitationReason: cpu`; the camera's `media-source` stayed 720×1280); the test's heights are a snapshot from before it, and the room's announcement kept the `media-source` size. **Fixed:** the room now announces the size the layers are sent at ([design.md §6.3](design.md#63-the-announced-simulcast-size-m12)).

## 7. Integration tests against the dev server

The example has these integration tests in [`example/integration_test/`](../example/integration_test/), which run against a real broker:

- `sfu_loopback_test.dart`: publishes a camera (or microphone) track on one SFU session and pulls it on another, switching the pulled layer. Both sessions connect early (`establishConnection()`), so a slow first capture doesn't let the SFU expire them.
- `datachannel_echo_test.dart`: a DataChannel echoed both ways.
- `reconnect_test.dart`: two rooms in one process; the publisher's session is dropped and replaced, then the subscriber's, and the track must arrive again each time (criterion 3, automated).
- `late_publish_test.dart`: two rooms in one process; the publisher joins, stays idle for 30 s (longer than the SFU keeps an unconnected session), then publishes its camera (or microphone), and the subscriber must decode it. Run twice: with the default `connectEarly` the joined session must be kept; without it, the publish must complete after one re-session (roadmap M10).
- `stats_test.dart`: two rooms in one process ([design.md §7.1](design.md#71-typed-stats-and-connection-quality-m12), roadmap M12 part A). The publisher sends its camera (three simulcast layers) and microphone; the typed stats must show layers `a`, `b` and `c` with sizes that halve from layer to layer, bitrates, frame rates and VP8, a round-trip time on the connection, and on the subscriber the received video (frames, size, bitrate) and audio (Opus). Both sides must rate the connection `good` or `excellent`. Then the publisher's session is failed with reconnection off, so it stays in signaling with its media stopped: it must be `lost` to itself at once and to the subscriber within `lostAfter` (5 s). It first checks that the camera captures frames, and fails with a hint about the camera and microphone permissions if not.
- `audio_routing_test.dart`: on phones, a voice call starts on the earpiece (or a connected headset), publishing a camera moves it to the speaker, `selectAudioRoute` and `setSpeakerphone` move it as asked (compare the Android log with `adb shell dumpsys audio`, "Active communication device"); on desktops and in browsers, the room reports it has no audio routes. Then each microphone in turn, with the subscriber still receiving audio. In a browser it also checks that the subscriber's audio plays in the package's hidden `<audio>` element (not paused, its clock moving, not blocked by the autoplay policy) and, where the browser has `setSinkId`, that choosing each output device keeps it playing there.
- `camera_switch_test.dart`: two rooms in one process; the publisher switches its camera twice during the call (`switchCamera()`), and the subscriber must keep decoding frames each time. It also checks that a phone opens its front camera and that the capture is near the requested preset. With one camera, it only checks the call.
- `screen_share_test.dart` (phones, and browsers with `--dart-define=CF_REALTIME_SCREEN_SHARE_WEB=true`; skipped on desktops): two rooms in one process; the publisher shares its screen (`publishScreen()`), its outbound frames and the subscriber's decoded frames must rise, and stopping must unpublish it. The consent dialog needs a tap: "Share one app" → "Share entire screen" → "Share screen" on Android 14+, "Start now" before that. Grant `POST_NOTIFICATIONS` first (`adb shell pm grant <package> android.permission.POST_NOTIFICATIONS`) or answer its prompt. To automate the taps, poll `adb shell uiautomator dump` from a background loop and `adb shell input tap` the centre of each button. With `--dart-define=CF_REALTIME_SCREEN_SHARE_EXTERNAL_STOP=true` it shares a second time and waits up to 2 minutes for a stop from outside the app: the notification's **Stop sharing** or the red status-bar chip. It must end with `userStopped`. **On an iPhone** the example's `BroadcastExtension` must be signed (the same team as the app; automatic signing creates its App ID and the App Group). A first test, which needs no person (`--plain-name "set up"`), checks the setup from the app (the `Info.plist` keys, the App Group, the embedded extension). The share test publishes the microphone first, then logs `TAP "Start Broadcast" on the iPhone` and waits up to 2 minutes for the tap in the system's picker; with the external stop it logs `STOP the broadcast` (the red status-bar indicator, or Control Center). An accessibility client such as `uiautomator` running at the end of the test can fail it with "A SemanticsHandle was active"; that is the tool, not the share. **In a browser** the browser's own picker must accept by itself (see [In a browser](#in-a-browser)); the test then also shares with `captureAudio` and checks that the tab or system audio the browser gives is published and pulled.
- `screen_share_stress_test.dart` (desktops; [design.md §4.3](design.md#43-room), Releasing a native renderer, and §10): a screen share started, rendered locally and by a second room, and stopped while frames flow, 30 times by default (`CF_REALTIME_STRESS_ITERATIONS`), every second time switching to a window and back first; `CF_REALTIME_STRESS_BUSY_MS=40` keeps the UI thread busy after each stop, which made the old renderer release crash at once on macOS; `CF_REALTIME_STRESS_LONG_SECONDS=200` runs one long share instead. It logs the event loop's gaps over 300 ms.
- `join_timing_test.dart` ([design.md §4.2](design.md#42-sfusession), macOS: a slow first join): times a join and a first microphone publish on a cold app start, and logs the event loop's gaps (a frozen app on macOS) with the `flutter_webrtc` calls behind each (the package's platform call timing, `CloudflareRealtime.debugPlatformCallTiming`, through `integration_test/support/call_timing.dart`); `CF_REALTIME_TIMING_MIC=<label>` publishes a chosen microphone, `CF_REALTIME_TIMING_PREWARM=1` calls `CloudflareRealtime.prewarm()` first, `CF_REALTIME_TIMING_NATIVE_LOG=info` adds the audio device module's own lines.
- `first_publish_timing_test.dart` (two sides, like `cross_device_test.dart`: `CF_REALTIME_CROSS_DEVICE=1`, the same fresh `CF_REALTIME_ROOM`; [design.md §4.2](design.md#42-sfusession), Finding the blocking call): a first call as an app makes it, on a cold app start. The native side shows a call screen (its own camera and the other side's), joins through the dev server, publishes its camera and microphone (`CF_REALTIME_TIMING_ORDER`: `together`, the default, `microphone-first` or `camera-first`), waits for the other side's camera and watches for 10 s, then logs the event loop's gaps with the calls sent then and pending, every call of 100 ms or more on any channel, and `flutter_webrtc`'s calls by method. In a browser ([In a browser](#in-a-browser)) it plays the other side: camera and microphone, until the native side is done. `CF_REALTIME_TIMING_PREWARM=1` calls `CloudflareRealtime.prewarm()` at app start; `CF_REALTIME_TIMING_MIC` / `CF_REALTIME_TIMING_CAMERA` choose devices by label.
- `renderer_timing_test.dart` (desktops; [design.md §4.3](design.md#43-room), Fewer renderer calls): two rooms in one process; the publisher's self-view and the subscriber's view of its camera, in tiles laid out like the example's. It toggles the microphone and the camera, switches between gallery and stage with and without `GlobalKey`s, and unpublishes and republishes the camera, then prints, per action, the renderer's `flutter_webrtc` calls (`videoRendererSetSrcObject`, `createVideoRenderer`, `videoRendererDispose`, `streamDispose`) with their durations, the renderer operations with the action behind each, and the longest event-loop gap. `CF_REALTIME_TIMING_CAMERA` and `CF_REALTIME_TIMING_MIC` (environment) pick the devices by label (default: a "FaceTime" camera, the system default microphone).
- `background_test.dart` (phones only; [design.md §4.7](design.md#47-calls-outside-the-foreground-background-interruptions-proximity-native)): two rooms in one process.
  - **Background:** the publisher sends its microphone and camera, the test logs `BACKGROUND NOW` and waits up to 2 minutes for the app to leave the screen, then checks for 20 s that outbound audio packets, microphone energy and encoded frames (and the subscriber's received audio and decoded frames) keep rising; then `FOREGROUND NOW`, and it waits for the app to come back. On Android the package's `CallService` must be in the foreground while something is published, and gone once nothing is. Run it with the driver, from `example/`, which presses Home and brings the app back over adb, and prints `dumpsys activity services` (`CallService`, `isForeground`, `foregroundServiceType`: 0x80 microphone, 0x40 camera) and the proximity wake lock from `dumpsys power` at each `CHECK` line:

    ```bash
    ANDROID_SERIAL=<android-id> integration_test/background_test_driver.sh \
      --dart-define=CF_REALTIME_BROKER_URL=http://<dev server>:8787 \
      --dart-define=CF_REALTIME_BROKER_TOKEN=<dev token> \
      --dart-define=CF_REALTIME_BROKER_USER=it-android
    ```

    On an iPhone this test runs only with `--dart-define=CF_REALTIME_BACKGROUND_MANUAL=1`: swipe home at `BACKGROUND NOW` and reopen the app at `FOREGROUND NOW`. There the audio must keep flowing and the camera must be reported paused (`background`), then resumed.
  - **Interruptions (Android):** the example's `MainActivity` takes the audio focus as another app would (`example/test_support`), transiently and then for good; the call must report `CallInterruptedEvent` (`otherAudio`), resume when the focus comes back, and after the permanent loss resume with `Room.resumeAudio()`, with the subscriber hearing it again. `adb` has no reliable way to take the focus from another app (a media key starts whatever player was last used, if any), so the test does it in-process.
  - **Proximity sensor:** on for a voice call on the earpiece, off on the speaker and with video (skipped with a headset connected).
  - **By hand** (nothing automates these): hold the phone to your ear during a voice call on the earpiece and check that the screen goes dark, and comes back when you move it away; call the phone from another phone during a call, and invoke Siri or the assistant: the call must report the interruption (`phoneCall` on Android, `unknown` on iOS), go silent both ways, and resume after; and on Android, pull down the notification shade during a call: "Call in progress" is listed (with `POST_NOTIFICATIONS` granted).
- `system_call_test.dart` (phones only; [design.md §4.8](design.md#48-system-calls-callkit-and-android-telecom-native)): system calls through Android's Telecom (Core-Telecom) or CallKit, with two rooms in one process.
  - **Outgoing:** a call is started (`dialing`), reported connecting and connected (`active`) and attached to the publisher's room. The system's mute and the microphone publication must stay in step both ways: `SystemCall.setMuted` mutes the publication, muting the publication mutes the call, and on Android the global microphone mute (what Telecom, a car or a watch sets) is flipped behind the package's back and must reach both. Holding must interrupt the room's audio (`CallInterruptionReason.held`) and unholding resume it, with the subscriber hearing the publisher again. On Android the routes must be Telecom's endpoints (UUID IDs; the native `endpoints` method returns `null` on iOS), and the speaker and then the earpiece are selected through them. Ending the call must leave the room and, on Android, stop `CallService`.
  - **Incoming:** reported (`ringing`), answered in code (one `SystemCallAnsweredEvent`), the same room checks, then leaving the room must end the call (`local`). A second incoming call declined while ringing ends with `declined`.
  - **The notification (Android):** the incoming call's notification must be on the high-importance "Incoming calls" channel with a full-screen intent, Answer and Decline; the test presses them through the notification's own `PendingIntent`s (`example/test_support`), as a tap would: Answer must answer through the package's ring activity (`IncomingCallActivity`), which, the phone being unlocked, opens the app and leaves no task behind; the ongoing notification must then offer Hang up, which ends the call, and Decline must end a second one with `declined`.
  - **Forged intents (Android):** the ring activity must not be exported (and be `singleInstance`, out of Recents), and the package's Answer action with the call's ID, sent to the app's own launch activity, must leave the call ringing. With the driver, adb's shell sends the same intent (`am start` on `.MainActivity`) and tries to start the ring activity (refused: not exported) at `INJECT NOW`; the call must still ring.
  - **From the background (Android, driver only):** an incoming call reported while the app is in the background (as an FCM handler would) must still ring with its full-screen notification.
  - Run it with the driver, from `example/`; it passes `CF_REALTIME_SYSTEM_CALL_DRIVER=1`, presses Home and comes back at `BACKGROUND NOW` / `FOREGROUND NOW`, and at each `CHECK TELECOM` prints Telecom's calls (`dumpsys telecom`: `DIALING`, `RINGING`, `ACTIVE`, `ON_HOLD`, `self_mng`), the services (`CallService` with `types=0x4` phoneCall while ringing or dialing, `0x84` with the microphone; Telecom's own `PHONE_CALL` record) and the global microphone mute:

    ```bash
    ANDROID_SERIAL=<android-id> integration_test/system_call_test_driver.sh \
      --dart-define=CF_REALTIME_BROKER_URL=http://<dev server>:8787 \
      --dart-define=CF_REALTIME_BROKER_TOKEN=<dev token> \
      --dart-define=CF_REALTIME_BROKER_USER=it-android
    ```

    Plain `flutter test integration_test/system_call_test.dart` runs everything but the background case. On an iPhone the same Dart runs without the Android-only parts.
  - **By hand.** The example's **Simulate incoming call** rings 5 s after the tap, time to lock the phone. On iOS a UIKit background task (`example/background_task`, in the example's `AppDelegate.swift`) keeps the app running through those 5 s: a locked iPhone suspends an app that has no call yet, so without it the call only rang after unlocking. It stands in for the VoIP push that wakes a real app.
    - **Android:** with the phone locked (a PIN), the call must ring full screen over the lock screen in the package's ring screen (the caller, Answer, Decline), never the example's own screen, with the ringtone if the ringer is on. Answer there must answer and then ask for the PIN: cancelling must leave the answered call on the ring screen (Hang up, Open app) with the example still hidden; entering it must open the example in the call. Decline there must end the call and never ask for the PIN. Answer and Decline in the notification and in the heads-up banner; Hang up in the ongoing notification; the call chip in the status bar; a real phone call during the call must hold it (`held`, silent) and resume it after; a Bluetooth headset's button ends the call; a car or a watch where available. On Android 14+ the full-screen ring needs the "Full screen notifications" permission for the app (the example opens its settings page once).
    - **iOS:** with the phone locked, CallKit must ring full screen on the lock screen ("Demo caller"). Answered there, the app joins the room while still in the background, with two-way audio: the join screen attaches the call and publishes the microphone itself, because Flutter builds no widgets in the background; the call page, which adds the camera, appears when the app is opened. Declined there, the call ends with `declined` (the log has `[systemCall] … the incoming call ended: declined`) and no room is joined. Then the system's mute, a real phone call holding the call, End from the lock screen, Recents, and a headset's button.
- `publish_quality_test.dart` (M12; [design.md §6.2, §6.3](design.md#62-publisher-side-layer-pausing-m12)): two rooms in one process.
  - **Layer pausing** (turned on for the publisher): the subscriber pulls only `c`, so the publisher must pause `a` and `b` (`outbound-rtp` `active: false`) while `c` keeps sending; the subscriber then switches up to `a`: the publisher must resume at once and the subscriber keep decoding (whether the SFU moves it up within 20 s is logged, not asserted); then a new pull of the paused `a` must decode it within 10 s. `--dart-define=CF_QUALITY_PAUSING=false` runs the same without pausing, as a baseline.
  - **The announced size** must match what layer `a` sends (portrait on a phone held upright, smaller under libwebrtc's CPU adaptation), else the camera's `media-source` size in either orientation (an iPhone's is landscape when it sends portrait). Throughout the test, sampled every 500 ms, it must have the aspect of the layers being encoded (`framesEncoded` rising), apart from at most 5 s after a change, and again 4 s after `a` and `b` are paused.
  - **The codec:** with `RoomOptions.videoCodec`, the subscriber must decode that codec (VP8 where the platform lacks the encoder); the encoders and decoders in use are logged. `--dart-define=CF_QUALITY_CODECS=h264,vp9,av1` (default `h264`).
  - Pixel 10, October 2, 2026: paused after the 3 s delay, resumed 0.11–0.25 s after the request; switching up reached `a` in 6.5 s and 6.6 s and stayed on `b` once (2 of 3 runs; the baseline without pausing: 3 of 3, in 6.4–10.5 s); a new pull of the paused layer decoded it in 0.54–0.56 s; captured and announced 720×1280 (the camera's settings said 1280×720); H.264 on the hardware `c2.google.avc.encoder`, three layers, decoded by `c2.google.avc.decoder`; VP9 (libvpx) and AV1 (`c2.google.av1.encoder`) sent one layer.
- `cross_device_test.dart`: a call between **two devices**, such as Windows and an Android phone (criteria 1 and 2, automated). See [Cross-device test](#cross-device-test).

They are skipped unless a broker URL is set. Settings ([`broker_settings.dart`](../example/integration_test/broker_settings.dart)), as `--dart-define`s or, on desktop, environment variables:

| Name | Value for the dev server |
|---|---|
| `CF_REALTIME_BROKER_URL` | `<SERVER>` (required) |
| `CF_REALTIME_BROKER_TOKEN` | `<TOKEN>` (sent as `Authorization: Bearer`) |
| `CF_REALTIME_BROKER_USER` | a user name, such as `it-windows` (sent as `X-Dev-User`; the dev server rejects requests without it) |
| `CF_REALTIME_ROOM` | optional; default `integration-test` |
| `CF_REALTIME_CROSS_DEVICE` | `1` to run `cross_device_test.dart` (skipped otherwise) |
| `CF_REALTIME_CROSS_DEVICE_SCREEN` | `--dart-define` only: `true` makes a phone side of `cross_device_test.dart` publish its microphone, then share its screen instead of its camera (answer Android's consent dialog, or tap "Start Broadcast" on the iPhone within 2 minutes) |
| `CF_REALTIME_SYSTEM_CALL_DRIVER` | `--dart-define` only: `1` (set by `system_call_test_driver.sh`) runs `system_call_test.dart`'s background case, which needs Home pressed |
| `CF_REALTIME_SCREEN_SHARE_EXTERNAL_STOP` | `--dart-define` only: `true` makes `screen_share_test.dart` also wait for a stop from outside the app |
| `CF_REALTIME_SCREEN_SHARE_WEB` | `--dart-define` only: `true` runs `screen_share_test.dart` in a browser, whose picker must accept by itself ([In a browser](#in-a-browser)) |
| `CF_QUALITY_PAUSING` | `--dart-define` only: `false` runs `publish_quality_test.dart`'s layer test without pausing (a baseline) |
| `CF_QUALITY_CODECS` | `--dart-define` only: the codecs `publish_quality_test.dart` checks, comma-separated (`h264,vp9,av1`; default `h264`) |

Run them on each platform, from `example/`:

```sh
flutter test integration_test -d windows --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-windows
flutter test integration_test -d macos --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-macos
flutter test integration_test -d <android-id> --no-uninstall --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-android
flutter test integration_test -d <iphone-id> --no-uninstall --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-ios
```

**On phones, pass `--no-uninstall`.** Without it, `flutter test` deletes the app after every file, and the permissions go with it: the Local Network, Camera and Microphone prompts come back on every run, and a test that waits on an unanswered prompt times out. With it, the app (and what you allowed) stays installed between runs. On an iPhone, a run that prints *The Dart VM Service was not discovered after 60 seconds* is usually waiting on the Local Network prompt; it carries on once you allow it.

One file at a time: `flutter test integration_test/reconnect_test.dart -d windows ...`. Expect `All tests passed!` with no test reported as skipped; skipped tests mean `CF_REALTIME_BROKER_URL` didn't arrive. Accept the camera and microphone prompts on macOS and Android. The tests never print the settings; keep them out of shared shell history.

**Android over USB.** With `adb reverse tcp:8787 tcp:8787` ([step 3](#3-build-and-run-the-example-on-each-device)), use `CF_REALTIME_BROKER_URL=http://127.0.0.1:8787` on the phone. To skip the camera and microphone prompts on Android, grant both once the app is installed (with `--no-uninstall` the grant lasts until you delete the app):

```sh
adb -s <android-id> shell pm grant dev.kammcs.cloudflare_realtime_example android.permission.CAMERA
adb -s <android-id> shell pm grant dev.kammcs.cloudflare_realtime_example android.permission.RECORD_AUDIO
```

### Cross-device test

`cross_device_test.dart` runs on two devices **at the same time**, in the same room, against the dev server (it uses its WebSocket signaling). Each side joins as a `Room`, publishes its camera (its microphone if it has no camera) and pulls the other's. It checks that the inbound bytes and decoded frames rise in `getStats()`, then, as the other side's camera is simulcast, asks for the low, high and low layers and checks that the received frame height follows (the other side announces the height of each layer it sends). Both sides then wait for each other before leaving.

Pick a fresh room name for each run, give each device its own user, and start both within 5 minutes of each other (each waits that long for the other). From `example/`, in two shells:

```sh
# Shell 1: the phone (with adb reverse as above)
flutter test integration_test/cross_device_test.dart -d <android-id> --dart-define=CF_REALTIME_CROSS_DEVICE=1 --dart-define=CF_REALTIME_ROOM=cross-1 --dart-define=CF_REALTIME_BROKER_URL=http://127.0.0.1:8787 --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-android
# Shell 2: Windows
flutter test integration_test/cross_device_test.dart -d windows --dart-define=CF_REALTIME_CROSS_DEVICE=1 --dart-define=CF_REALTIME_ROOM=cross-1 --dart-define=CF_REALTIME_BROKER_URL=<SERVER> --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> --dart-define=CF_REALTIME_BROKER_USER=it-windows
```

Both must print `All tests passed!`. Each side logs `[cross-device]` lines: the layer heights each side sends, the inbound bytes and frames, and how long each layer switch took. Start the second shell once the first has built and installed, so the two builds don't compete; any two devices work (macOS, a second phone), as long as both reach the dev server.

### In a browser

The same tests run in a browser through `flutter drive`, with the example's [`test_driver/integration_test.dart`](../example/test_driver/integration_test.dart) and a WebDriver server. `flutter test -d chrome` doesn't run integration tests.

1. **Get the WebDriver** for the browser, into any folder (nothing system-wide):
   - Chrome: the chromedriver of the same version as the installed Chrome (`npx @puppeteer/browsers install chromedriver@<Chrome version>`), started as `chromedriver --port=4444`.
   - Firefox: [geckodriver](https://github.com/mozilla/geckodriver/releases), `geckodriver --port=4444`.
   - Safari: `safaridriver`, which comes with macOS. Once per Mac: `sudo safaridriver --enable`, and in Safari → Settings → Advanced, "Show features for web developers", then Develop → "Allow Remote Automation". Safari has no fake camera or microphone.
2. **Run one file at a time**, from `example/`:

   ```sh
   flutter drive --driver=test_driver/integration_test.dart \
     --target=integration_test/sfu_loopback_test.dart \
     -d web-server --browser-name=chrome --headless \
     --web-browser-flag=--use-fake-device-for-media-stream \
     --web-browser-flag=--use-fake-ui-for-media-stream \
     --dart-define=CF_REALTIME_BROKER_URL=<SERVER> \
     --dart-define=CF_REALTIME_BROKER_TOKEN=<TOKEN> \
     --dart-define=CF_REALTIME_BROKER_USER=it-web
   ```

   - **Fake devices.** `--use-fake-device-for-media-stream` gives Chrome a fake camera (`fake_device_0`, a moving pattern at the size asked for), three microphones, three audio outputs and, for `getDisplayMedia`, an 800×450 screen with an audio track. `--use-fake-ui-for-media-stream` accepts the camera, microphone and screen prompts. Firefox takes preferences instead, from a profile folder whose `user.js` sets `media.navigator.streams.fake` and `media.navigator.permission.disabled` to `true`: pass it with `--web-browser-flag=-profile --web-browser-flag=<folder>`.
   - **Autoplay.** Chrome plays the call audio without `--autoplay-policy=no-user-gesture-required`, because the page captures the microphone. A page that only receives would need a click first (`Room.audioPlaybackBlocked`, `Room.startAudio()`).
   - **Wasm.** Add `--wasm --profile` to run the same file compiled to WebAssembly.
   - **The output.** `flutter drive` prints only `All tests passed.` or the failure. The tests' own lines (and the `+N ~M` counts that show skipped tests) go to the browser's console. To see them in Chrome, start chromedriver with `--enable-chrome-logs` and add `--web-browser-flag=--enable-logging=stderr --web-browser-flag=--v=0`: they appear in chromedriver's output as `INFO:CONSOLE` lines. For Firefox, set `devtools.console.stdout.content` to `true` in the profile.
   - **The settings are compiled into the page.** `--dart-define` values end up in the web build (`build/web` for `--profile`). Delete `build/web` afterwards, and never publish or share it. If the Flutter tool crashes, its report (`flutter_01.log`) contains the command line, token included: delete it too.
3. **Cross-device:** run `cross_device_test.dart` this way with `--dart-define=CF_REALTIME_CROSS_DEVICE=1 --dart-define=CF_REALTIME_ROOM=<room>`, at the same time as the other device's `flutter test` (start both from one script).

The dev server answers browsers' CORS preflights for its broker routes, `X-Dev-User` included (`DEV_CORS_ORIGINS`, default `*`), and the signaling WebSocket takes the token in its query string, so nothing changes on the server for a browser.

#### Web results

October 2, 2026, Chrome 154 (headless, fake devices) on macOS 27, against the dev server. "JS" is the default debug build, "Wasm" `--wasm --profile`.

| Test | Chrome (JS) | Chrome (Wasm) | Firefox 137 | Safari 27 |
|---|---|---|---|---|
| `sfu_loopback_test` | Pass | Pass | not run | Pass (JS and Wasm) |
| `datachannel_echo_test` | Pass | Pass | not run | Pass (JS and Wasm) |
| `reconnect_test` | Pass | Pass | not run | Pass (JS and Wasm) |
| `camera_switch_test` | Pass (one camera, `fake_device_0`, no facing in its label: 640×360 as asked) | Pass | not run | Pass, JS and Wasm (two mock cameras at 640×360, 4 ms per switch) |
| `late_publish_test` | Pass (kept session: 108 ms; without early connect: one re-session, 6.1 s) | Pass | not run | Pass, JS and Wasm (kept session: 124 ms; without early connect: one re-session, 6.4 s) |
| `stats_test` | Pass (three layers 1280×720 / 640×360 / 320×180 at ~20 fps, RTT 2–6 ms, `excellent`; `lost` after 6–8 s) | Pass | not run | Pass, JS and Wasm (three VP8 layers at ~29 fps, RTT 2 ms, `excellent`; `lost` after 8.0 s) |
| `publish_quality_test` | Pass (paused after 2.3 s, resumed in 78–90 ms; switching up stayed on `b` for 20 s in both runs; a new pull of `a` decoded in 0.24–0.35 s; H.264 sent with OpenH264, decoded with VideoToolbox) | Pass | not run | Pass, JS and Wasm (paused after 2.3 s, resumed in 95 ms; switching up reached `a` in 6.2 s; a new pull of `a` decoded in 0.33 s; no encoder or decoder names reported) |
| `audio_routing_test` | Pass (no routes; the `<audio>` element plays; `setSinkId` to each of three outputs) | Pass | not run | Pass, JS and Wasm, at `0418f3c` (each output change refused as `AudioOutputException(needsUserGesture)`, the audio kept playing on the previous output). At `16a5805` it failed: the refused output was thrown raw and stuck |
| `screen_share_test` (`CF_REALTIME_SCREEN_SHARE_WEB`) | Pass (800×450; with `captureAudio`, the audio published and pulled) | Pass | not run | **Fail**, JS and Wasm: `getDisplayMedia must be called from a user gesture handler` (a `MediaCaptureException`); Safari can't run it unattended |
| `background_test`, `system_call_test` | Skipped (phones only), as expected | n/a | n/a | n/a |
| `cross_device_test` with a Pixel 10 | Pass both ways (the layer switches low / high / low in 8.6–12.7 s) | not run | not run | not run |
| `cross_device_test` with macOS (October 3) | Pass both ways (low / high / low in 8.1–12.7 s on each receiver) | not run | not run | not run |

Firefox didn't start under the sandbox of the tool that ran these; it was run on Windows instead (roadmap M13).

Safari 27.0 on macOS 27.0, October 3, 2026, at `16a5805`, through `safaridriver` (`--browser-name=safari`, no `--headless`). Notes:

- **Quit Safari first.** A Safari the user started refuses WebDriver sessions (`Safari was not launched for automation`); `safaridriver` then starts its own.
- **Mock devices.** An automation session uses WebKit's mock devices (*Mock video device 1/2*, *Mock audio device 1–4*, *Mock speaker device 1–3*); no permission prompt appears, and no real camera or microphone is used.
- **The output.** Safari's WebDriver can't read the console, so the tests' lines were forwarded from the page to a local collector by a temporary hook in `web/index.html` (not committed).
- **Wasm** needs a loader override: Flutter 3.47.3's default `wasmAllowList` allows Chromium only, so a `--wasm` build never starts in Safari. The runs used a temporary `web/flutter_bootstrap.js` that allows WebKit ([doc/web.md](../doc/web.md#webassembly-in-safari-and-firefox)).
- **User gestures.** Safari allows `setSinkId` (to any device, `default` included) and `getDisplayMedia` only from a user gesture, which `flutter drive` can't give. Apps call both from a button's `onPressed` ([doc/web.md](../doc/web.md)). A refused output used to stick and be retried on every later `<audio>` element; fixed after this run.
- Every call logs `screen wake lock refused: NotAllowedError`: Safari refuses the wake lock, and the call is unaffected.

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

### iOS

- **Signing:** `flutter` reports that no development team is set. Create `example/ios/Flutter/Signing.xcconfig` as in [step 3](#3-build-and-run-the-example-on-each-device). Automatic signing registers the example's bundle ID and the phone with that team.
- **Local Network:** the app needs it for the dev server, and `flutter run`/`flutter test` need it to find the app's Dart VM Service (over Bonjour). If you denied it, the screen stays white and `flutter` waits; allow the app in Settings → Privacy & Security → Local Network. The Mac side needs Bonjour too: a terminal or IDE that is sandboxed or lacks macOS's Local Network permission sees the same symptom.
- **Camera and microphone:** Settings → Privacy & Security → Camera / Microphone, or delete the app to be asked again.
- **The first publish fails with `SessionGoneException` (410, "Session appears to be disconnected"):** the SFU drops a session whose peer connection never connected (about ten seconds). Since M10 the room connects its session at join and retries a publish once on a new session, so this should no longer happen; if it does, check that `RoomOptions.connectEarly` isn't turned off and look for a `RoomReconnectFailedEvent`.

### Windows H.264 crash

`flutter_webrtc` on Windows has crashed with H.264 video (flutter-webrtc #982). The package sends VP8 from every platform by default (and so does the example: its `VIDEO_CODEC` define defaults to `video/VP8`), because the SFU forwards each publisher's codec unchanged, so a Windows receiver would otherwise decode a Mac's or phone's H.264. If a Windows device crashes when another participant joins, check that no device was started with `--dart-define=VIDEO_CODEC=default` or `video/H264`, and that no app joined with `RoomOptions.videoCodec: VideoCodec.h264` (M12). A Windows *publisher* asked for H.264 sends VP8 instead and reports `RoomErrorEvent('videoCodec', …)`; a Windows *subscriber* has no such protection, so keep rooms with Windows participants on VP8 ([design.md §6](design.md#6-simulcast), Codec).

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
