# Linux setup

On Linux the package runs its Dart code on `flutter_webrtc`; it has no native Linux code of its own, and there are no permissions to declare outside a sandbox. libwebrtc opens the cameras (V4L2) and the audio devices (PulseAudio, or PipeWire's PulseAudio layer) directly. Wayland and X11 are both supported; Wayland changes how screen share works (below).

## Building

- **Ubuntu 24.04 or later** (or a distribution with glibc 2.39 or later), x64. `flutter_webrtc` downloads a prebuilt libwebrtc for `linux-x64` (and `linux-arm64`).
- The Flutter Linux toolchain: `clang cmake ninja-build pkg-config libgtk-3-dev`, plus `libpulse-dev` for system audio in screen shares (without it the plugin still builds, and `captureAudio` gives no audio track).
- The app template's `-Wall -Werror` holds for this package and `flutter_webrtc`'s plugin.

## What differs on Linux

The API is the same as on the other platforms. Where Linux can't do something, the package says so instead of behaving differently:

- **Layer pausing** (`RoomOptions.layerPausing`) doesn't happen on Linux, as on Windows: `flutter_webrtc`'s desktop plugin ignores encoding changes. A Linux publisher keeps every layer and reports a `RoomErrorEvent` with operation `layerPausing` once.
- **ICE servers:** at most 8 URLs reach `flutter_webrtc` (its desktop plugin overflows a fixed array beyond that); the package drops port-53 and duplicate URLs first.
- **Camera facing:** desktop cameras have none, so `switchCamera()` cycles through the cameras.
- **Audio:** desktops have no call audio routes (`Room.canSelectAudioRoute` is `false`). Choose the output with `Room.setAudioOutputDevice`.

## Keeping the screen on

During a video call (`RoomOptions.keepScreenAwake`) the package holds an idle inhibitor on the session bus, through GLib's GDBus with `dart:ffi`:

- **The Inhibit portal** (`org.freedesktop.portal.Inhibit`, idle flag) when the portal can tell which app is asking: inside a Flatpak or a Snap, or a host app launched under its application ID. GNOME Shell and KDE start a `.desktop` app in a systemd scope named `app-<launcher>-<app ID>-<random>.scope`, and the portal reads the ID from there, so name your `.desktop` file after a reverse-DNS application ID (`com.example.App.desktop`).
- **`org.freedesktop.ScreenSaver.Inhibit`** otherwise (a host app started from a terminal, or with a desktop file whose name isn't a valid application ID). GNOME (through `gsd-screensaver-proxy`), KDE Plasma, Xfce and xscreensaver answer it, on Wayland and X11.

Each falls back to the other when its service doesn't answer. Why the order: GNOME's portal backend refuses an inhibitor for a host app without an application ID ("Application ID not specified") while the portal itself still answers, so the app couldn't tell it failed. On GNOME, `busctl --user call org.gnome.SessionManager /org/gnome/SessionManager org.gnome.SessionManager GetInhibitors` lists the inhibitor while it's held.

## Screen share

**On X11**, it works as on Windows: `ScreenSourcePicker` lists screens and windows with thumbnails, and `LocalParticipant.publishScreen(source: …)` shares the one the user picked.

**On Wayland**, applications can't read the screen; the system's **ScreenCast dialog** (the `xdg-desktop-portal` ScreenCast portal) is the picker, for screens and windows alike, and the frames come over PipeWire. The package follows libwebrtc's own rule for "Wayland": `XDG_SESSION_TYPE` is `wayland` and `WAYLAND_DISPLAY` is set, which includes an app on XWayland (`GDK_BACKEND=x11`) inside a Wayland session. There:

- `FlutterWebrtcMediaBackend().desktopCapturer` is `null`: the package never lists sources, `ScreenSourcePicker.isSupported` is `false`, and `ScreenShareSource.usesSystemPicker` is `true`. Show one "Share screen" button instead of a source list, as you would on the web.
- `publishScreen()` without a source opens the dialog. Cancelling it fails `publishScreen` with a `MediaException` (`ScreenShareSource.start()` returns `false` and reports nothing), as with a browser's picker.
- **Sharing the same thing again without the dialog:** `LocalParticipant.lastSystemScreenPick` is the room's last pick (a `SystemScreenPick`). `publishScreen(restore: lastSystemScreenPick)` shares it again with no dialog; a pick the system no longer knows opens the dialog. Offer both, "Share *the same* again" and "Choose something else…"; with no `restore`, the dialog always opens, so the user can always choose. Unmuting a share restores its pick by itself. Picks live in memory only.
- **Ending:** when the user stops the share from the system's sharing indicator, or the shared window closes, the share is unpublished with `ScreenShareEndReason.userStopped`.
- **A stream another component opened:** a remote-control session that combines the RemoteDesktop and ScreenCast portals in one dialog can hand its stream to the call, `publishScreen(pipewireStream: PipeWireScreenStream(fd: …, nodeId: …, geometry: …))`, with no second dialog. `ScreenShareSource.start(pipewireStream: …)` on a running share switches to it in place: the track stays published and the remote side sees no unpublish. The stream's `geometry` is its position and size in the compositor's **logical** coordinates (`ScreenShareSource.sourceGeometry`), and `updatePipeWireGeometry` replaces it (say, once the scale is known). The component that opened the portal session owns it: when it closes, the share ends as `userStopped`; when the share ends for another reason while the session is still open, close that session yourself, or the system keeps showing that the screen is shared.
- No `ScreenGeometry` for a pick from the dialog, and no system border to hide.

The Wayland flow needs the portal capture in the `flutter_webrtc` fork described in [design.md §10](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#10-screen-share-by-platform). With stock `flutter_webrtc`, a Wayland share fails with a `MediaCaptureException`.

## Diagnostics

`CloudflareRealtime.platformInfo` describes the platform for a support report: the distribution and kernel (`osVersion`), and `linux`: the display server the app's window uses (`wayland`, `xwayland` or `x11`), the session type and the desktop (`XDG_CURRENT_DESKTOP`). The package logs it once, at the `info` level, when the first room joins.

## Status

Built and unit-tested on Ubuntu 24.04 with GNOME 46, on Wayland and XWayland (November 2026). Keeping the screen on is verified there, through the portal and through `org.freedesktop.ScreenSaver`. Calls against the real SFU, the Wayland share with the fork's portal capture, KDE Plasma and a real Xorg session are still to verify.
