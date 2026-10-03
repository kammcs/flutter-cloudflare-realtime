# Android setup

`cloudflare_realtime` has native code on Android: call audio routing, the call's foreground service, screen share, and system calls through Jetpack Core-Telecom. Its manifest merges into your app, so most of this page is about what your app still declares, asks for, and tells Google Play.

- [Requirements](#requirements)
- [Permissions](#permissions)
- [Calls in the background](#calls-in-the-background)
- [Interruptions and the proximity sensor](#interruptions-and-the-proximity-sensor)
- [Screen share](#screen-share)
- [System calls (Telecom)](#system-calls-telecom)
- [Google Play declarations](#google-play-declarations)

## Requirements

- **`minSdk` 24** (Android 7.0). The plugin compiles against API 36 with Java 17.
- **Kotlin:** the plugin's Kotlin is compiled by AGP 9's built-in Kotlin, or by the Kotlin Gradle plugin that your app's Android project already declares (Flutter's app template does).

## Permissions

The package's manifest already declares, and the manifest merger brings into your app:

| Permission | What it's for |
|---|---|
| `MODIFY_AUDIO_SETTINGS` | Routing call audio (speaker, earpiece, headsets). |
| `WAKE_LOCK` | The proximity sensor turning the screen off at the ear. |
| `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MICROPHONE`, `FOREGROUND_SERVICE_CAMERA` | The call's foreground service (`CallService`), while a room publishes. |
| `FOREGROUND_SERVICE_MEDIA_PROJECTION` | The screen share's foreground service (`ScreenCaptureService`). |
| `FOREGROUND_SERVICE_PHONE_CALL`, `USE_FULL_SCREEN_INTENT` | System calls (Telecom). Core-Telecom adds `MANAGE_OWN_CALLS`. |
| `POST_NOTIFICATIONS` | The services' notifications (a runtime permission on Android 13+). |

**Your app declares** these in `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<!-- Bluetooth headsets as audio routes. -->
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<!-- Optional: don't require the hardware on Google Play. -->
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.microphone" android:required="false" />
```

**At runtime:**

- **Camera and microphone:** `flutter_webrtc` asks for `CAMERA` and `RECORD_AUDIO` when a capture starts. To ask at a better moment, request them yourself before joining (for example with `permission_handler`).
- **`BLUETOOTH_CONNECT`** (Android 12+): nothing in the package asks for it. Request it yourself, before or during a call. Without it, Bluetooth headsets are simply missing from `Room.audioRoutes`.
- **`POST_NOTIFICATIONS`** (Android 13+): see the services below. Without it, calls and shares still work; their notifications just aren't in the drawer.

## Calls in the background

While a room publishes a microphone or a camera, the package runs a foreground service so the call keeps its microphone, camera and connection when the user leaves the app. Android 11+ silences the microphone and stops the camera of a backgrounded app without one, and Android 14+ requires its types (`microphone`, plus `camera` while the camera captures) and starts it only while the app is in the foreground. The service starts with the first publish and stops when nothing is published or the room is left.

- **Manifest:** nothing to add. The package declares the service (`CallService`, types `microphone|camera|phoneCall`) and its permissions.
- **Notification:** the service shows a "Call in progress" notification that opens the app. It needs `POST_NOTIFICATIONS` on Android 13+, which the package doesn't ask for; without it the call still works in the background, the notification just isn't in the drawer. Override the strings `cloudflare_realtime_call_channel`, `…_title` and `…_text`, or the drawable `cloudflare_realtime_call`, in your app's resources.
- **Your own service:** pass `RoomOptions(foregroundService: false)`, and drop the package's with `tools:node="remove"` on `<service android:name="dev.kammcs.cloudflare_realtime.CallService">` (and its permissions, if nothing else needs them).
- **A start that fails** (for example a camera published while the app is in the background) is a `RoomErrorEvent` with operation `foregroundService`, retried when the app is back in the foreground.
- **A receive-only call** (nothing published) gets no service; Android may stop its playback once it freezes the backgrounded app.

## Interruptions and the proximity sensor

- **Interruptions:** a phone call, the assistant, an alarm or another app taking the audio focus pauses the call: `RoomAudioInterruptedEvent` (with a `CallInterruptionReason`: `phoneCall` or `otherAudio`), `Room.audioInterruption`, and the call is silent in both directions (nothing is announced as muted). It resumes by itself when the system gives the audio back or the app returns to the foreground (`RoomAudioResumedEvent`); `Room.resumeAudio()` tries at once. No `READ_PHONE_STATE` is needed.
- **Proximity sensor:** during a voice call on the earpiece, the screen turns off when the phone is held to the ear. It's off on the speaker, on a headset and with video. Turn it off with `RoomOptions(proximitySensor: false)`; `Room.isProximitySensorActive` says whether it's on.
- **The screen stays on during a video call** (`FLAG_KEEP_SCREEN_ON` on the activity's window; no permission): it doesn't dim or lock while the camera or a screen share is sent or a remote video is shown, and sleeps as usual in a voice call. If your app keeps the screen on itself, pass `RoomOptions(keepScreenAwake: KeepScreenAwake.never)`; `KeepScreenAwake.always` keeps it on for voice calls too (except at the ear). `Room.isKeepingScreenAwake` says whether it's on.

## Screen share

`LocalParticipant.publishScreen()` (or `ScreenShareSource.start()`) takes no source on Android: the system's consent dialog is the picker. The share runs under a foreground service of type `mediaProjection` that this package provides, which Android 14+ requires.

- **Manifest:** nothing to add. The package declares the service and the `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_MEDIA_PROJECTION` and `POST_NOTIFICATIONS` permissions. An app that never shares its screen can drop them with `tools:node="remove"`.
- **Notification permission (Android 13+):** the service shows a "Sharing your screen" notification with a **Stop sharing** action. If `POST_NOTIFICATIONS` isn't granted, the package asks for it once per app launch, before the consent dialog. If the user says no, the share still works; the notification just isn't shown in the drawer. To ask at a better moment, request it yourself first.
- **Customizing the notification:** override the strings `cloudflare_realtime_screen_share_channel`, `…_title`, `…_text` and `…_stop`, or the drawable `cloudflare_realtime_screen_share`, in your app's resources.
- **Behaviour:** a cancelled consent dialog makes `start()` return `false` (and `publishScreen` throw a `MediaCaptureException`), as a cancelled browser picker does. A share stopped from the system's status-bar chip or the notification ends with `ScreenShareEndReason.userStopped`. Every start asks for consent again (Android 14+ allows one projection per consent).
- **Limits:** screen audio (`ScreenShareOptions.captureAudio`) isn't supported on Android and is ignored. `ScreenShareOptions.frameRate` doesn't reach the capturer (it captures up to 30 fps); the published encoding (`ScreenSharePresets.detail`: 15 fps) limits what is sent.

## System calls (Telecom)

`SystemCalls` puts the app's calls in Android's Telecom through Jetpack Core-Telecom (Android 8+; `SystemCalls.instance.configure()` completes with `false` below), so a phone call holds them instead of cutting them off, and cars, watches and headsets answer, end and mute them. See [design.md §4.8](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/design.md#48-system-calls-callkit-and-android-telecom-native).

- **Manifest:** nothing to add. The package declares `FOREGROUND_SERVICE_PHONE_CALL`, `USE_FULL_SCREEN_INTENT`, the `phoneCall` type on `CallService` and the receiver for the notification's Decline and Hang up; Core-Telecom adds `MANAGE_OWN_CALLS` and its `ConnectionService`.
- **Notifications:** while a call exists, `CallService` runs with the type `phoneCall` and shows the call's `CallStyle` notification: ringing (the "Incoming calls" channel, with the ringtone, full screen, Answer and Decline) and then ongoing (Hang up). Ask for `POST_NOTIFICATIONS` (Android 13+). On Android 14+ check `NotificationManager.canUseFullScreenIntent()` and, if it's `false`, send the user to `Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`: Google Play grants it by default only to calling and alarm apps, and without it an incoming call is a heads-up notification instead of a full-screen ring. The example app does both (`example/lib/system_call_demo.dart` and its `MainActivity.kt`).
- **Answer** opens your launch activity (with the action `dev.kammcs.cloudflare_realtime.action.ANSWER_CALL`), which brings the app to the foreground and answers the call; listen to `SystemCalls.instance.events` for `SystemCallAnsweredEvent` and join the room. Answer and the full-screen ring show your activity over the lock screen until the last call ends. Your launch activity should be `singleTop` (Flutter's template is).
- **Report incoming calls from the foreground or a high-priority FCM message's handler:** Android lets the call's foreground service start from the background only then. Delivering the push is your app's job. There are no VoIP pushes on Android: `SystemCalls.instance.voipPush.isSupported` is `false` and `register()` does nothing, so send a high-priority FCM message and call `SystemCalls.instance.reportIncomingCall` from its handler.
- **Stopping the ring from a push** (the caller hung up, another device answered): there are no VoIP pushes on Android, so your FCM handler ends the call itself, after `configure` (which lists the calls the package already has): `SystemCalls.instance.call(id)?.end(SystemCallEndReason.answeredElsewhere)`. Use the reasons of the iOS cancel push ([ios.md](ios.md#system-calls-callkit-and-voip-pushes)): `remoteEnded`, `answeredElsewhere`, `declinedElsewhere`, `unanswered`, `failed`.
- **Texts and icon** are resources you can override: `cloudflare_realtime_call_incoming_channel`, `…_incoming`, `…_incoming_video`, `…_outgoing`, `…_ongoing`, `…_answer`, `…_decline`, `…_hang_up` (Android 12+ labels the `CallStyle` buttons itself), and the drawable `cloudflare_realtime_call`.
- **Mute** is the global microphone mute, as Telecom's own mute button sets it (Core-Telecom 1.0 has no per-call mute); it's cleared when the last call ends.
- **Attach the call to the room** with `Room.attachSystemCall(call)`: the system's mute and the microphone stay in step, the room leaves when the call ends, and the call ends when the room is left.

## Google Play declarations

Apps that use foreground service types must declare them in the Play Console (App content, Foreground service permissions):

- `microphone` and `camera`: calls in the background (unless you pass `RoomOptions(foregroundService: false)` and remove the service);
- `mediaProjection`: screen share;
- `phoneCall`: system calls.

`USE_FULL_SCREEN_INTENT` is granted by default only to calling and alarm apps.
