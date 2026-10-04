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
- **Privacy manifest:** the plugin ships a `PrivacyInfo.xcprivacy` (no tracking, no collected data) that declares its use of `UserDefaults` (reason `CA92.1` for the system-call settings, `1C8F.1` for the App Group the screen share uses). The Broadcast Upload Extension's template sources are compiled into your extension, not the plugin: they read `UserDefaults` from the App Group and `ProcessInfo.systemUptime`, so declare those in your extension's own manifest.

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

iOS stops the camera of a backgrounded app. The track stays published and sends no frames until the app is back, when the camera restarts by itself; `Room.cameraPause` and `RoomCameraPausedEvent` / `RoomCameraResumedEvent` report it (with a `CameraPauseReason`: `background`, `inUseByAnotherApp`, `multipleForegroundApps`, `systemPressure` or `other`). Keeping the camera running in the background needs picture-in-picture, which is planned ([roadmap, M14](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/roadmap.md#m14-notes-picture-in-picture-and-the-ios-camera-in-the-background)).

## Interruptions and the proximity sensor

- **Interruptions:** a phone call, Siri, an alarm or another app taking the audio pauses the call: `RoomAudioInterruptedEvent`, `Room.audioInterruption`, and the call is silent in both directions (nothing is announced as muted). iOS doesn't say what interrupted, so the reason is `unknown` (or `held` while a system call is on hold). The call resumes by itself when the system gives the audio back or the app returns to the foreground (`RoomAudioResumedEvent`); `Room.resumeAudio()` tries at once.
- **Proximity sensor:** during a voice call on the earpiece, the screen turns off when the phone is held to the ear. It's off on the speaker, on a headset and with video. Turn it off with `RoomOptions(proximitySensor: false)`; `Room.isProximitySensorActive` says whether it's on.
- **The screen stays on during a video call** (`isIdleTimerDisabled`, restored afterwards): it doesn't dim or lock while the camera or a screen share is sent or a remote video is shown, and sleeps as usual in a voice call. If your app keeps the screen on itself, pass `RoomOptions(keepScreenAwake: KeepScreenAwake.never)`; `KeepScreenAwake.always` keeps it on for voice calls too (except at the ear). `Room.isKeepingScreenAwake` says whether it's on.

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

`SystemCalls.instance.configure()` sets up CallKit, and the app's calls then show in the system's call UI: the lock screen, Recents, a headset, a car or a watch (see [design.md §4.8](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#48-system-calls-callkit-and-android-telecom-native)). The iOS backend is verified on an iPhone 16 Pro Max with iOS 27: the native tests on the device, `system_call_test.dart`, and by hand the ring on the lock screen, answering and declining from it, the system's mute, a real phone call holding the call and iOS resuming it, Recents, and outgoing calls. Still to check: VoIP pushes with the app killed, and headset buttons ([roadmap, M11](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/roadmap.md)).

- **`Info.plist`:** add `voip` next to `audio` in `UIBackgroundModes` (above).
- **Call audio:** CallKit activates the audio session when a call starts or is answered. Once `configure` has run, the package switches WebRTC to manual audio, so a call's audio starts only after CallKit activated the session. Don't activate the session yourself during a system call.
- **Attach the call to the room** with `Room.attachSystemCall(call)`: the system's mute and the microphone stay in step, the room leaves when the call ends, and the call ends when the room is left.
- **Answered from the lock screen,** the app stays in the background, where Flutter builds no widgets until the user opens it. So join the room, attach the call and publish the microphone from the answer itself (for example `SystemCall.stateChanges`), not from a widget's `initState` or a dialog, or the call has no audio until then. The camera can wait for the foreground. The example's join screen does this.
- **`declined` doesn't always mean the user declined.** A ringing call the app didn't end ends as `SystemCallEndReason.declined` when the user declines it (the lock screen, the banner, a headset or a watch). CallKit ending the ringing call by itself also ends as `declined`, for example when another call takes over, or at once on the Simulator, which has no call UI to show it. CallKit reports both as the same end action, so the package can't tell them apart. A decline made in your own UI (`SystemCall.end()` while ringing) is always the user's. If your server must never tell a caller "declined" for a call the user didn't see, it can treat a `declined` from the system's UI as "not answered on this device" instead. Do Not Disturb, Focus and the block list don't decline: they refuse the call, so `reportIncomingCall` throws a `SystemCallException` with `filtered` (a pushed call ends as `failed`). A call that CallKit resets ends as `failed`. Android can tell them apart ([android.md](android.md#system-calls-telecom)).
- **Optional:** `SystemCallsOptions.iconTemplateImageName` (a 40×40 pt template image in your asset catalog) and `ringtoneSound` (a sound file in your bundle).
- **China mainland:** apps on the China mainland App Store must not use CallKit. There, don't call `configure`.

**VoIP pushes** wake the app for an incoming call (`SystemCalls.instance.voipPush`). They need the following:

- **The Push Notifications capability** (Xcode: Signing & Capabilities, + Capability; this adds the `aps-environment` entitlement). Your provisioning profile must include it. Without it, no VoIP token arrives.
- **An APNs key or certificate for your server:** a token-based key (`.p8`, from Certificates, Identifiers & Profiles, Keys, with APNs enabled), or a VoIP Services certificate. Keep it on your server, never in the app or the repository.
- **The token:** `await SystemCalls.instance.voipPush.register()` (remembered across launches) and `tokenChanges`. Send the token to your server. iOS only.
- **The launch hook:** call `CloudflareRealtimePlugin.handleLaunch()` in `application(_:didFinishLaunchingWithOptions:)`, before `super`:

  ```swift
  import Flutter
  import UIKit
  import cloudflare_realtime

  @main
  @objc class AppDelegate: FlutterAppDelegate {
    override func application(
      _ application: UIApplication,
      didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
      CloudflareRealtimePlugin.handleLaunch()
      return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }
  }
  ```

  It restores the CallKit provider (from the last `configure`) and the PushKit registry (after `register()`), so a push that launches a killed app is reported to CallKit at once. Apple asks for the registry to exist by the end of `didFinishLaunching`. Without the hook, the package restores both when a Flutter engine registers its plugins. That can be later: in a UIScene app (Flutter's current iOS template), with an engine you start yourself, or in add-to-app; if the push isn't reported in time, iOS terminates the app and, after repeated failures, stops delivering its VoIP pushes. The hook works with Swift Package Manager and CocoaPods, does nothing until the app has called `configure` or `register()` once, and is safe to call again. From Objective-C: `@import cloudflare_realtime;` and `[CloudflareRealtimePlugin handleLaunch];`.
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
- **Stopping the ring: a cancel push.** When the caller hangs up, another of the user's devices answers or declines, or the ring times out, send a second VoIP push (same headers) with the call's `id` and the reserved key `ended`:

  ```json
  {
    "id": "0f8fad5b-d9cb-469f-a165-70867728950e",
    "ended": "answeredElsewhere"
  }
  ```

  - **`ended`** is a `SystemCallEndReason` name: `remoteEnded` (the caller hung up), `answeredElsewhere`, `declinedElsewhere`, `unanswered` (the ring timed out) or `failed`. Any other value (`local` and `declined` included: they happen on this device) is logged and taken as `remoteEnded`. `handle` isn't needed; `ended` never reaches `payload`.
  - **A call the app has** ends with that reason: `SystemCallEndedEvent`, with `SystemCall.endReason` set, as when your code calls `call.end(reason)`. Before Dart runs, the event waits for it, after the call's `SystemCallAddedEvent`.
  - **A call that already ended on this device,** whoever ended it and with any reason (your own ring timeout with `end(SystemCallEndReason.unanswered)`, the user declining, a hang-up, an earlier cancel), stays ended, for a cancel and for the call's own push alike: no ring and no event. The package remembers the last 64 calls that ended, while the app runs. iOS still requires a report, so the package reports the call's own ID again. CallKit refuses it while it remembers the call, and then nothing shows; but it forgets within a second or two (at once after a decline or a local end), and then the report is a call again that the package ends at once: it can flash for an instant and may show in Recents. To avoid that, don't send a cancel to the device that ended the call, and let your server's expiry end an unanswered ring rather than a shorter local timer: a cancel for a call that still rings just ends it.
  - **A call the app never had** (the cancel woke a killed app) doesn't ring: the package reports a stand-in and ends it at once with the reason. No event, and `calls` stays empty. It may flash for an instant, and may show in Recents. The package also remembers the cancelled ID, so the call's own push arriving after its cancel (APNs doesn't keep the order) doesn't ring either.
  - **A call this device already took** (answered, or outgoing) ends only for `remoteEnded` or `failed`. `answeredElsewhere`, `declinedElsewhere` and `unanswered` are ignored for it, so a cancel your server sends to all of the user's devices doesn't end the call on the one that answered.
  - **On Android** there are no VoIP pushes: your FCM handler ends the call itself, with the same reasons: `SystemCalls.instance.call(id)?.end(SystemCallEndReason.answeredElsewhere)`.
- **Push only for calls.** iOS terminates an app that receives a VoIP push and doesn't report a call. After repeated failures, iOS stops delivering VoIP pushes to it. A push without `id` or `handle` still rings for an instant and is ended as failed. A ringing push for a call your signaling already reported is ignored; a cancel push for it ends it (above).
