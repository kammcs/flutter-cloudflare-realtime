# Windows setup

On Windows the package runs its Dart code on `flutter_webrtc`; it has no native Windows code of its own, and there are no permissions to declare. Windows asks the user for the camera and microphone through its privacy settings (Settings → Privacy & security → Camera / Microphone, "Let desktop apps access…").

## Building

- **Visual Studio 2022 17.14 or later** with the "Desktop development with C++" workload **and the "C++ ATL for latest build tools" component**: `flutter_webrtc`'s Windows plugin needs ATL. Older Build Tools (17.12) fail to build it.
- Windows 10 or 11, 64-bit.

## What differs on Windows

The API is the same as on the other platforms; these are the places where Windows can't do something and the package says so instead of behaving differently:

- **Video codec:** Windows sends VP8 when a room asks for H.264 (`RoomOptions.videoCodec`), and reports a `RoomErrorEvent` with operation `videoCodec`: `flutter_webrtc` has crashed encoding H.264 there (flutter-webrtc #982). VP8 is the default everywhere.
- **Layer pausing** (`RoomOptions.layerPausing`) doesn't happen on Windows: `flutter_webrtc`'s Windows plugin ignores encoding changes. A Windows publisher keeps every layer and reports a `RoomErrorEvent` with operation `layerPausing` once. Windows participants still report what they pull, so publishers on other platforms can pause for them.
- **Camera facing:** desktop cameras have none, so `switchCamera()` cycles through the cameras. Virtual cameras (OBS, NVIDIA Broadcast, Snap Camera and others) come last.
- **Audio:** desktops have no call audio routes (`Room.canSelectAudioRoute` is `false`). Choose the output with `Room.setAudioOutputDevice`.

## Screen share

`ScreenSourcePicker` lists screens and windows with thumbnails (the first listing has none; the first re-scan, which runs at once, brings them), and `LocalParticipant.publishScreen(source: …)` shares the one the user picked. `ScreenShareOptions(captureAudio: true)` adds the system audio (loopback).

Each listed `ScreenSource` has a `geometry` (`ScreenGeometry`): its `bounds` in physical pixels of the virtual screen (as `GetMonitorInfo` and `SetCursorPos` use them in a per-monitor DPI-aware app, which Flutter's runner is; origin at the primary monitor's top-left, monitors left of or above it negative), its `scaleFactor` (effective DPI / 96: 1.5 at 150 %) and, for a screen, `isPrimary`. A window's bounds are its visible frame (`DWMWA_EXTENDED_FRAME_BOUNDS`); a minimized window has none. While sharing, `ScreenShareSource.sourceGeometry` and `sourceGeometryChanges` follow the shared window as it moves. **Not yet verified on a Windows device:** it is built from the Win32 documentation and libwebrtc's source, and unit-tested with fakes.

Known `flutter_webrtc` limits: a covered window may show what covers it, a minimized window sends no frames, HDR screens can look washed out, and listing sources sometimes fails (the package retries and reports `ScreenSourcesException` through `ScreenPickerState.error`). See [design.md §10](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#10-screen-share-by-platform).
