# iOS setup

`cloudflare_realtime` has native code on iOS: call audio routing, background and interruption handling, the screen share's setup check, and CallKit with PushKit. Some things have to live in your app: `Info.plist` keys, background modes, a Broadcast Upload Extension for screen sharing, and the capabilities for VoIP pushes.

- [Requirements](#requirements)
- [Info.plist](#infoplist)
- [Calls in the background](#calls-in-the-background)
- [Interruptions and the proximity sensor](#interruptions-and-the-proximity-sensor)
- [Screen share: the Broadcast Upload Extension](#screen-share-the-broadcast-upload-extension)
- [System calls: CallKit and VoIP pushes](#system-calls-callkit-and-voip-pushes)

## Requirements

- **iOS 15.0** or later (the plugin's deployment target).
- CocoaPods or Swift Package Manager. The plugin's `Package.swift` uses the `FlutterFramework` package of recent Flutter releases; with older Flutter versions, use CocoaPods.

## Info.plist

```xml
<key>NSCameraUsageDescription</key>
<string>The camera is used to send your video to the call.</string>
<key>NSMicrophoneUsageDescription</key>
<string>The microphone is used to send your audio to the call.</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
  <!-- Only with system calls and VoIP pushes (below). -->
  <string>voip</string>
</array>
```

iOS asks for the camera and microphone the first time a capture starts. Bluetooth and wired headsets need no permission. A development server on your local network also needs `NSLocalNetworkUsageDescription` (the example app has it); a broker on the internet doesn't.

## Calls in the background

With the `audio` background mode, iOS keeps the app running during a call: any call with a published or received audio track keeps the audio session active.

iOS stops the camera of a backgrounded app. The track stays published and sends no frames until the app is back, when the camera restarts by itself; `Room.cameraPause` and `LocalCameraPausedEvent` / `LocalCameraResumedEvent` report it (with a `CameraPauseReason`: `background`, `inUseByAnotherApp`, `multipleForegroundApps`, `systemPressure` or `other`). Keeping the camera running in the background needs picture-in-picture, which is planned ([roadmap, M14](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/roadmap.md#m14-notes-picture-in-picture-and-the-ios-camera-in-the-background)).

## Interruptions and the proximity sensor

- **Interruptions:** a phone call, Siri, an alarm or another app taking the audio pauses the call: `CallInterruptedEvent`, `Room.audioInterruption`, and the call is silent in both directions (nothing is announced as muted). iOS doesn't say what interrupted, so the reason is `unknown` (or `held` while a system call is on hold). The call resumes by itself when the system gives the audio back or the app returns to the foreground (`CallResumedEvent`); `Room.resumeAudio()` tries at once.
- **Proximity sensor:** during a voice call on the earpiece, the screen turns off when the phone is held to the ear. It's off on the speaker, on a headset and with video. Turn it off with `RoomOptions(proximitySensor: false)`; `Room.proximitySensorActive` says whether it's on.
- **The screen stays on during a video call** (`isIdleTimerDisabled`, restored afterwards): it doesn't dim or lock while the camera or a screen share is sent or a remote video is shown, and sleeps as usual in a voice call. If your app keeps the screen on itself, pass `RoomOptions(keepScreenAwake: KeepScreenAwake.never)`; `KeepScreenAwake.always` keeps it on for voice calls too (except at the ear). `Room.keepingScreenAwake` says whether it's on.

## Screen share: the Broadcast Upload Extension

On iOS, a screen share is captured by a **Broadcast Upload Extension**, a separate target in your app that iOS runs while the user shares. `publishScreen()` (or `ScreenShareSource.start()`) takes no source: the system's broadcast picker opens, and the call completes once the user taps **Start Broadcast**. This package ships the extension's code as templates in [`ios/broadcast_extension/`](https://github.com/kammcs/flutter-cloudflare-realtime/tree/main/ios/broadcast_extension) (MIT); you add the target once. The [example app](https://github.com/kammcs/flutter-cloudflare-realtime/tree/main/example/ios) is set up this way.

1. **Add the target.** In Xcode, File → New → Target → *Broadcast Upload Extension*, named for example `BroadcastExtension`, without a UI extension. Set its deployment target to iOS 15 or later, and its bundle identifier to your app's plus a suffix (`com.example.app.BroadcastExtension`). It must link **ReplayKit only**: never add Flutter or any plugin to it.
2. **Use the templates.** Replace the generated `SampleHandler.swift` with this package's `SampleHandler.swift` and add `BroadcastUploader.swift` (copy them from the package, or reference them). Use its `Info.plist` and `BroadcastExtension.entitlements`, or copy their keys: `NSExtension` (point `com.apple.broadcast-services-upload`, principal class `$(PRODUCT_MODULE_NAME).SampleHandler`, mode `RPBroadcastProcessModeSampleBuffer`) and `RTCAppGroupIdentifier`. To give the extension the app's version, base its configurations on `Flutter/Debug.xcconfig` and `Flutter/Release.xcconfig`, as the app's are.
3. **An App Group on both targets.** Add the *App Groups* capability to the app and to the extension, with the same group (`group.com.example.app`). The templates read it from a build setting, `CF_REALTIME_APP_GROUP`, which you can define in `Flutter/Debug.xcconfig` and `Flutter/Release.xcconfig` (before any `#include?` of your own); or write the group into the files directly.
4. **The app's `Info.plist`:**

   ```xml
   <key>RTCAppGroupIdentifier</key>
   <string>group.com.example.app</string>
   <key>RTCScreenSharingExtension</key>
   <string>com.example.app.BroadcastExtension</string>
   <key>UIBackgroundModes</key>
   <array>
     <string>audio</string>
   </array>
   ```

   The first two tell `flutter_webrtc` where the frames come from. `audio` keeps the app running while the user is in other apps, which is the point of sharing a screen; the app's call audio (a published microphone) keeps it active.
5. **Embed the extension before "Thin Binary".** Xcode adds an *Embed Foundation Extensions* (or *Embed App Extensions*) build phase to the app target. In the app target's *Build Phases*, drag it above Flutter's **Thin Binary** script, or the build fails with a dependency cycle.
6. **Signing:** both targets need the same development team (Signing & Capabilities, Team, on the `Runner` target and on the extension). With automatic signing, Xcode creates the extension's App ID, its profile and the App Group. The example app's project has no team set: pick yours before running it on a device.

**Checking the setup:** if something is missing, the share doesn't start: `start()` returns `false`, `publishScreen()` throws, and a `ScreenShareSetupException` says what's missing (`problems`, and `guidance` to log). It checks both `Info.plist` keys, the App Group container, an embedded broadcast extension with the bundle ID in `RTCScreenSharingExtension`, and the extension's `RTCAppGroupIdentifier`.

**Behaviour:** the picker can't report a cancel, so a dismissed picker makes `start()` return `false` (and `publishScreen()` throw a `MediaCaptureException`) after `ScreenShareOptions.broadcastStartTimeout` (60 s). A broadcast the user stops from the status bar or Control Center ends with `ScreenShareEndReason.userStopped`. The extension sends at most `ScreenShareOptions.frameRate` frames per second, scaled by `ScreenShareOptions.broadcastScale` (0.5 by default), and repeats a still screen once a second. Screen audio (`captureAudio`) isn't supported on iOS and is ignored.

See [design.md §10](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#10-screen-share-by-platform) for the details.

## System calls: CallKit and VoIP pushes

`SystemCalls.instance.configure()` sets up CallKit, and the app's calls then show in the system's call UI: the lock screen, Recents, a headset, a car or a watch (see [design.md §4.8](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#48-system-calls-callkit-and-android-telecom-native)). The iOS backend is unit-tested; its checks on devices are still under way ([roadmap, M11](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/roadmap.md)).

- **`Info.plist`:** add `voip` next to `audio` in `UIBackgroundModes` (above).
- **Call audio:** CallKit activates the audio session when a call starts or is answered. Once `configure` has run, the package switches WebRTC to manual audio, so a call's audio starts only after CallKit activated the session. Don't activate the session yourself during a system call.
- **Attach the call to the room** with `Room.attachSystemCall(call)`: the system's mute and the microphone stay in step, the room leaves when the call ends, and the call ends when the room is left.
- **Optional:** `SystemCallsConfig.iconTemplateImageName` (a 40×40 pt template image in your asset catalog) and `ringtoneSound` (a sound file in your bundle).
- **China mainland:** apps on the China mainland App Store must not use CallKit. There, don't call `configure`.

**VoIP pushes** wake the app for an incoming call (`SystemCalls.instance.voipPush`). They need the following:

- **The Push Notifications capability** (Xcode: Signing & Capabilities, + Capability; this adds the `aps-environment` entitlement). Your provisioning profile must include it. Without it, no VoIP token arrives.
- **An APNs key or certificate for your server:** a token-based key (`.p8`, from Certificates, Identifiers & Profiles, Keys, with APNs enabled), or a VoIP Services certificate. Keep it on your server, never in the app or the repository.
- **The token:** `await SystemCalls.instance.voipPush.register()` (remembered across launches) and `tokenChanges`. Send the token to your server. iOS only.
- **The push:** HTTP/2 to `api.push.apple.com` (`api.sandbox.push.apple.com` for development builds), `/3/device/<token>`, with the headers `apns-push-type: voip`, `apns-topic: <bundle id>.voip`, `apns-priority: 10` and `apns-expiration: 0`. The package reads these keys at the top level of the JSON payload:

  ```json
  {
    "id": "0f8fad5b-d9cb-469f-a165-70867728950e",
    "handle": "ada@example.com",
    "handleType": "emailAddress",
    "displayName": "Ada",
    "video": true,
    "room": "your-room-id"
  }
  ```

  - **Required:** `id`, a UUID that the call keeps (share it with your signaling), and `handle`.
  - **Optional:** `handleType` (`generic`, the default, `phoneNumber` or `emailAddress`), `displayName` and `video`.
  - **Everything else** except `aps` becomes `SystemCall.payload`, for finding the room.
  - **What the package does:** it reports the call to CallKit itself, before Dart runs, as iOS requires. The call then arrives as a `SystemCallAddedEvent`, or in `SystemCalls.instance.calls` after `configure`.
- **Push only for calls.** iOS terminates an app that receives a VoIP push and doesn't report a call. After repeated failures, iOS stops delivering VoIP pushes to it. A push without `id` or `handle` still rings for an instant and is ended as failed. A push for a call your signaling already reported is ignored.
