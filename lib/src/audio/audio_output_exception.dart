/// @docImport '../media/media_types.dart';
/// @docImport '../room/room.dart';
/// @docImport 'call_audio.dart';
library;

/// Why the platform refused an audio output device ([AudioOutputException]).
enum AudioOutputFailure {
  /// The browser didn't allow the switch (`NotAllowedError`). Safari
  /// accepts any device but the default only from a user gesture: call
  /// [Room.setAudioOutputDevice] again from a button's or menu item's
  /// `onPressed`, with nothing awaited before it. A permissions policy that
  /// forbids choosing the speaker is refused with the same name, and there
  /// a gesture doesn't help.
  needsUserGesture,

  /// The device isn't there (any more): a browser's `NotFoundError`, or on
  /// native platforms a device that isn't in the device list. List the
  /// outputs again and pick one of those.
  notFound,

  /// Any other refusal; [AudioOutputException.cause] has the platform's
  /// error. Chrome, for one, refuses with a `SecurityError` while the page
  /// has no microphone permission ("No permission to use requested
  /// device").
  other,
}

/// Thrown by [Room.setAudioOutputDevice] when the platform refuses the
/// device. The output is unchanged: audio keeps playing where it played.
///
/// Not to be confused with [AudioRouteUnavailableException], which
/// [Room.selectAudioRoute] throws on phones, where call audio is routed
/// rather than sent to a chosen device. Where [Room.canSelectAudioOutput]
/// is `false`, [Room.setAudioOutputDevice] throws an [UnsupportedError]
/// instead.
final class AudioOutputException implements Exception {
  /// Creates the exception.
  const AudioOutputException(this.reason, {required this.deviceId, this.cause});

  /// Why the device was refused.
  final AudioOutputFailure reason;

  /// The device that was asked for, a [MediaDevice.deviceId] of an
  /// [MediaDeviceKind.audioOutput] device.
  final String deviceId;

  /// The platform's error, for logs: in a browser a JavaScript
  /// `DOMException` (an untyped JS value under WebAssembly), on native
  /// platforms usually a `PlatformException` from `flutter_webrtc`. Don't
  /// show it to users verbatim.
  final Object? cause;

  @override
  String toString() =>
      'AudioOutputException(${reason.name}, deviceId: $deviceId)'
      '${cause == null ? '' : ': $cause'}';
}

/// The failure for a browser error named [name] (a `DOMException.name`).
AudioOutputFailure audioOutputFailureForName(String name) => switch (name) {
  'NotAllowedError' => AudioOutputFailure.needsUserGesture,
  'NotFoundError' => AudioOutputFailure.notFound,
  _ => AudioOutputFailure.other,
};

/// The failure for a browser [error] whose name only shows in its text: a
/// `DOMException`'s `toString()` starts with its name in every browser,
/// under JavaScript and WebAssembly alike.
AudioOutputFailure audioOutputFailureFromText(Object error) {
  final text = error.toString();
  if (text.contains('NotAllowedError')) {
    return AudioOutputFailure.needsUserGesture;
  }
  if (text.contains('NotFoundError')) return AudioOutputFailure.notFound;
  return AudioOutputFailure.other;
}
