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
- **After sharing:** `LocalScreenShareStalledEvent` when the share sends no frames.

The example app shows how to point the user to the setting (`example/lib/screen_share_dialog.dart`).

**Limits:** screen audio isn't captured on macOS. macOS thumbnails are TIFF, which Flutter's image codecs may not decode, so give `Image.memory` an `errorBuilder`.

## Audio

Desktops have no call audio routes (`Room.canSelectAudioRoute` is `false`). Choose the speaker or headset with `Room.setAudioOutputDevice` and a device from the room's device list, and the microphone with `CameraSource` / `MicrophoneSource.setPreferredDevice` (or the `device:` argument of `publishMicrophone`).
