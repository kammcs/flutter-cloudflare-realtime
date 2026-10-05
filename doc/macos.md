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

The package keeps the app responsive meanwhile: it doesn't call into the plugin in ways that would block the main thread while the voice processing starts, and a microphone publish captures from the system default, or from the microphone you pass by ID, without listing the devices, so the first device list doesn't freeze it either. The first microphone publish itself doesn't freeze the UI. What still blocks the main thread, and so your UI:

- **The first peer connection, for 3–8 s**, inside `join`. `CloudflareRealtime.prewarm()` does it earlier, at a moment your app chooses, so that the join itself doesn't freeze for it. But it **moves the freeze; it doesn't remove it**: the prewarm freezes the UI just as long (3–9 s measured; a consuming app measured 5.3 s and 8.9 s when it ran it right after sign-in), and it doesn't make joins faster (that app measured no gain on its joins). Use it only where a freeze is acceptable, such as behind a launch or splash screen, and measure your app with and without it:

  ```dart
  // Behind the launch screen, well before the user joins a call.
  await CloudflareRealtime.prewarm();
  ```

  It keeps one idle peer connection (nothing captured or sent, no permission asked) until the next join has its own. After leaving a room, the next join's peer connection blocks again for 2–3 s; call `prewarm()` again after leaving if another call may follow.
- **The first device list, for 2–9 s**, when something reads it: publishing the camera, or a device picker listing the devices. Once the first microphone publish has started sending, the list takes a fraction of a second, so publish the microphone before the camera where you can, and list the devices in your pre-call screen, if it has a picker, rather than during the join.
- **Starting the camera, for about 1 s** (`getUserMedia`; 3–4 s if nothing has listed the cameras yet).
- **Switching to a microphone other than the system default, for 4–12 s** once the first publish starts sending, while the audio module rebuilds its voice processing for the new input; it falls inside that first microphone publish. The default input avoids it: pass no `device:` when the user hasn't chosen another microphone.

Show the call screen (with its hang-up button) before joining, so the user sees progress.

If you put a time limit on joining or publishing, allow at least 30 s on macOS.

## Finding what freezes the UI

`flutter_webrtc` answers its platform calls on the main thread, which on macOS is also Flutter's UI thread, so a slow call freezes the app; calls your app makes through `flutter_webrtc` itself (stats, audio levels, device lists, renderers) can freeze it as well as the package's. To find which call it is, turn on the package's platform call timing, a debug aid, first thing in `main`:

```dart
void main() {
  PlatformCallTimingBinding.ensureInitialized(); // before any other binding
  CloudflareRealtime.debugPlatformCallTiming =
      const PlatformCallTimingOptions(); // channels: null times every plugin
  runApp(const MyApp());
}
```

Run the app (a profile build measures best) from a cold start, and the console shows each event-loop gap over 250 ms with the calls sent just before or during it, and every call slower than 100 ms:

```text
cloudflare_realtime: event loop stopped for 4213 ms (+12030..+16243 ms); sent then: createPeerConnection(4190 ms)
cloudflare_realtime: createPeerConnection took 4190 ms (+12031 ms); the event loop stopped for 4213 ms meanwhile
```

A call about as long as the gap it was sent in is the one that blocked. `CloudflareRealtime.debugPlatformCallTimingEvents` has the same as typed events. Only method names, argument keys and times are recorded, never argument values or replies. Calls are named only with `PlatformCallTimingBinding` created before any other binding (an app with its own binding class returns `PlatformCallTimingBinding.wrapMessenger(super.createBinaryMessenger())` from its `createBinaryMessenger`); without it, the gaps are still reported. A gap with no call sent came from something else on the main thread: your own Dart code, or native work no call started. Turn it off (`null`, the default) for release builds.

## Video views

Each time a video view's native renderer starts or stops showing a track, `flutter_webrtc` blocks the main thread while libwebrtc's worker thread adds or removes the renderer: a few milliseconds when that thread is idle, but as long as it is busy otherwise (a consuming app measured 0.5–0.8 s per call after mute and camera toggles; the call is `videoRendererSetSrcObject` in the platform call timing). `ParticipantVideoView` does it only when the track really changes:

- A publisher's mute, a rebuild and a layout change cost nothing: a remote view keeps its track while it is muted, and a view that Flutter re-creates for the same track takes over the renderer of the view it replaces.
- Turning your camera off and on costs one call each way on your self-view (the capture is released and a new track captured); unpublishing and republishing a track costs one call per view each way.

So give remote viewers a mute rather than an unpublish when the camera goes off for a while, and keep tiles in place (a `GlobalKey` per tile when they move between layouts). If your app drives `RTCVideoRenderer` itself, set `srcObject` only when the track changes, and never to the stream it already shows. [design.md §4.3](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#43-room) has the measurements.
