# Web setup

On the web the package runs on `flutter_webrtc`'s browser implementation. Verified in Chrome and Firefox, compiled to JavaScript and to WebAssembly; Safari is not verified yet.

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

The browser asks for the camera and microphone when a capture starts. Before that, devices have no IDs or labels, so pick a device after the first capture. `Room.setAudioOutputDevice` chooses the speaker where the browser supports `setSinkId` (`Room.canSelectAudioOutput`).

## Screen share

`LocalParticipant.publishScreen()` takes no source: the browser's own picker opens (`ScreenShareSource.usesBrowserPicker`). A cancelled picker makes `publishScreen()` throw a `MediaCaptureException` (and `ScreenShareSource.start()` return `false`); the browser's "Stop sharing" button ends the share with `ScreenShareEndReason.userStopped`. `ScreenShareOptions(captureAudio: true)` publishes the audio the browser offers (tab audio in Chrome).

## Browsers

- **Chrome:** every integration test passes, as JavaScript and as WebAssembly.
- **Firefox:** every test passes, as JavaScript and as WebAssembly. H.264 needs Firefox's OpenH264 plugin; VP8, the default, doesn't. Firefox reports fewer statistics (for example no `qualityLimitationReason`), so those fields are `null`.
- **Safari:** not verified yet.
