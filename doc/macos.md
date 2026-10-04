# macOS setup

On macOS the package runs its Dart code on `flutter_webrtc`; it has no native macOS code of its own. Your app needs the sandbox entitlements and usage descriptions for the camera and microphone, and the user has to allow Screen Recording before a screen share shows anything.

## Requirements

- macOS 10.15 or later (`flutter_webrtc`'s deployment target). The example app targets macOS 12.

## Entitlements

Add these to both `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
<key>com.apple.security.device.camera</key>
<true/>
<key>com.apple.security.device.audio-input</key>
<true/>
<key>com.apple.security.network.client</key>
<true/>
```

`network.client` lets the app reach the broker and the SFU. Without the camera and audio-input entitlements, a sandboxed app gets no frames and no sound, with no prompt.

## Info.plist

```xml
<key>NSCameraUsageDescription</key>
<string>The camera is used to send your video to the call.</string>
<key>NSMicrophoneUsageDescription</key>
<string>The microphone is used to send your audio to the call.</string>
```

macOS asks for the camera and microphone the first time a capture starts.

## Screen share and the Screen Recording permission

`ScreenSourcePicker` lists screens and windows with thumbnails, and `LocalParticipant.publishScreen(source: …)` shares the one the user picked. See [design.md §10](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#10-screen-share-by-platform).

Capturing the screen needs the user's permission: System Settings → Privacy & Security → **Screen & System Audio Recording** ("Screen Recording" before macOS 15). There is no entitlement or `Info.plist` key for it. macOS prompts on the first capture, and a newly granted permission applies only after the app restarts. A rebuilt, ad-hoc-signed debug app can count as a new app and be asked again.

`flutter_webrtc` neither asks for this permission nor reports it: without it, a share returns a live track that sends no frames. So the package watches for the symptoms and reports a `ScreenCapturePermissionException` (a `MediaPermissionDeniedException` with `suspected: true` and `guidance` you can show):

- **In the picker:** `ScreenPickerState.permissionProblem` is set when a listing has no screens, or every screen's thumbnail is empty or black. It clears once a listing looks normal.
- **After sharing:** `LocalTrackStalledEvent` when the share sends no frames.

The example app shows how to point the user to the setting (`example/lib/screen_share_dialog.dart`).

**Display and window geometry:** each listed `ScreenSource` has a `geometry` (`ScreenGeometry`): its `bounds` in points in Core Graphics' global display space (origin at the primary display's top-left, y down; displays left of or above it have negative coordinates; AppKit's `NSScreen` frames are the same with y flipped), its `scaleFactor` (2.0 on Retina) and, for a screen, `isPrimary`. A window's bounds include its title bar. While sharing, `ScreenShareSource.sourceGeometry` and `sourceGeometryChanges` follow the shared window as it moves. These are read from Core Graphics; they need no entitlement and no Screen Recording permission, and work in the App Sandbox.

**Limits:** screen audio isn't captured on macOS. macOS thumbnails are TIFF, which Flutter's image codecs may not decode, so give `Image.memory` an `errorBuilder`.

## Audio

Desktops have no call audio routes (`Room.canSelectAudioRoute` is `false`). Choose the speaker or headset with `Room.setAudioOutputDevice` and a device from the room's device list, and the microphone with `CameraSource` / `MicrophoneSource.setPreferredDevice` (or the `device:` argument of `publishMicrophone`).

## The first call is slow

The first call after the app starts can take 20–40 s on some Macs before your microphone is heard, while a browser on the same Mac joins in a few seconds. Most of it is the audio stack starting, in WebRTC-SDK's audio device module, AVFoundation and Core Audio: initializing the module at the first peer connection (up to 6 s measured) and AVFoundation's first device list (up to 9 s), both once per app process, and above all Apple's voice processing (echo cancellation), which starts with the first microphone publish (3–27 s measured). It is worst on a loaded Mac and with many audio devices (virtual devices such as BlackHole, aggregate and multi-output devices, a Continuity iPhone). Choosing a microphone other than the system default adds 9–11 s, because the module restarts its voice processing for the new input. The module starts the voice processing again whenever it restarts recording. [design.md §4.2](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#42-sfusession) has the measurements.

The package keeps the app responsive meanwhile: it doesn't call into the plugin in ways that would block the main thread while the voice processing starts. The first peer connection and the first device list still block it for a few seconds each; show the call screen (with its hang-up button) before joining, so the user sees progress.

If you put a time limit on joining or publishing, allow at least 30 s on macOS.
