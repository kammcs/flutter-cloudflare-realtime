# Web setup

On the web the package runs on `flutter_webrtc`'s browser implementation. Verified in Chrome and Firefox, compiled to JavaScript and to WebAssembly, and in part in Safari (see [Browsers](#browsers)).

## HTTPS

Browsers give the camera, the microphone and the screen only to a **secure context**: serve the app over HTTPS (`http://localhost` counts as secure during development). The broker must be HTTPS too, or the browser blocks the requests as mixed content.

## The broker's CORS origins

A browser calls the broker cross-origin. List your web app's origins in the broker's CORS configuration; the reference brokers refuse a request whose `Origin` isn't listed. The broker must expose the `X-Realtime-Session-Token` response header if it sends one. See [broker/README.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/broker/README.md).

## Autoplay

Browsers block audio that starts without a user gesture. The package plays pulled audio in its own `<audio>` elements; when the browser blocks them, `Room.isAudioPlaybackBlocked` is `true` (and `audioPlaybackBlockedChanges` emits). Show a "Tap to enable audio" button while it is, and call `Room.startAudio()` from its `onPressed`:

```dart
StreamBuilder<bool>(
  stream: room.audioPlaybackBlockedChanges,
  initialData: room.isAudioPlaybackBlocked,
  builder: (context, snapshot) => snapshot.data == true
      ? FilledButton(
          onPressed: room.startAudio,
          child: const Text('Tap to enable audio'),
        )
      : const SizedBox.shrink(),
)
```

Joining from a button press usually avoids the block. On native platforms `isAudioPlaybackBlocked` is always `false`.

## Devices and permissions

The browser asks for the camera and microphone when a capture starts. Before that, devices have no IDs or labels, so pick a device after the first capture.

`Room.setAudioOutputDevice` chooses the speaker where the browser supports `setSinkId` (`Room.canSelectAudioOutput`). **Call it from a user gesture** (a button's or menu item's `onPressed`, with nothing awaited before it): Safari refuses any device but the default outside one. A refused device throws an `AudioOutputException`, and the output stays as it was, for the audio playing now and for audio pulled later. Its `reason` is `AudioOutputFailure.needsUserGesture` for the browser's `NotAllowedError` (Safari outside a gesture: ask the user to choose again), `notFound` for `NotFoundError`, `permissionDenied` for `SecurityError` (Chrome, while the page has no microphone permission: ask the user to allow the microphone), and `other` for the rest; `cause` holds the browser's `DOMException`, for logs.

```dart
try {
  await room.setAudioOutputDevice(device.deviceId);
} on AudioOutputException catch (e) {
  showMessage(switch (e.reason) {
    // Safari: the next attempt must come from that tap.
    AudioOutputFailure.needsUserGesture => 'Choose the speaker again.',
    AudioOutputFailure.permissionDenied =>
      'Allow microphone access to choose a speaker.',
    AudioOutputFailure.notFound => 'That speaker is gone. Choose another one.',
    AudioOutputFailure.other => 'Could not change the speaker.',
  });
}
```

## Screen share

`LocalParticipant.publishScreen()` takes no source: the browser's own picker opens (`ScreenShareSource.usesBrowserPicker`). Safari opens it only from a user gesture, so start a screen share from a button's `onPressed` (which suits every browser). A cancelled picker makes `publishScreen()` throw a `MediaCaptureException` (and `ScreenShareSource.start()` return `false`); the browser's "Stop sharing" button ends the share with `ScreenShareEndReason.userStopped`. `ScreenShareOptions(captureAudio: true)` publishes the audio the browser offers (tab audio in Chrome).

## Browsers

- **Chrome:** every integration test passes, as JavaScript and as WebAssembly.
- **Firefox:** every test passes, as JavaScript and as WebAssembly. H.264 needs Firefox's OpenH264 plugin; VP8, the default, doesn't. Firefox reports fewer statistics (for example no `qualityLimitationReason`), so those fields are `null`.
- **Safari:** Safari 27 (October 3, 2026, WebDriver with mock devices): `datachannel_echo`, `sfu_loopback`, `reconnect`, `camera_switch`, `late_publish`, `stats` and `publish_quality` pass, as JavaScript and as WebAssembly. In `audio_routing`, the `<audio>` element plays and every microphone reaches the other side; switching to a non-default output needs a user gesture, which a test can't give, so that part is expected to be refused there. The other tests are not verified in Safari yet. Safari-specific behaviour:
  - `Room.setAudioOutputDevice` to any device but the default needs a user gesture ([Devices and permissions](#devices-and-permissions)).
  - The screen picker (`getDisplayMedia`) needs a user gesture: start a screen share from a button press.
  - Safari refuses the screen wake lock (`NotAllowedError`): the screen may dim during a video call, and the call itself works. The package logs the refusal, and `Room.isKeepingScreenAwake` is `false` while Safari refuses.

## WebAssembly in Safari and Firefox

Flutter 3.47.3's default loader runs the WebAssembly build only in Chromium browsers (its `wasmAllowList`), and falls back to JavaScript elsewhere. An app built with `--wasm` that wants WebAssembly in Safari or Firefox too sets `wasmAllowList` in its `web/flutter_bootstrap.js`:

```js
{{flutter_js}}
{{flutter_build_config}}

_flutter.loader.load({
  config: {
    wasmAllowList: { blink: true, webkit: true, gecko: true },
  },
});
```
