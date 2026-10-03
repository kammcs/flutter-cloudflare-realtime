import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;

import 'remote_audio_sink_native.dart'
    if (dart.library.js_interop) 'remote_audio_sink_web.dart'
    as platform;

/// Plays pulled remote audio tracks (`docs/design.md` §4.3, Remote audio).
///
/// Native platforms play a received audio track by themselves, so their
/// sink does nothing. Browsers only play media attached to a media
/// element, so the web sink gives each track a hidden `<audio>` element,
/// and reports when the browser's autoplay policy blocks it.
///
/// Internal: not exported from the package barrel. The `Room` keeps one
/// sink and feeds it every pulled audio track.
abstract interface class RemoteAudioSink {
  /// Plays [track] under [id] (a `RemoteTrackPublication.id`), replacing
  /// the track playing under [id] before, if any.
  void attach(String id, MediaStreamTrack track);

  /// Stops playing what was attached under [id].
  void detach(String id);

  /// Starts whatever the browser refused to play. Call it from a user
  /// gesture (a click or tap handler) with nothing awaited before it, so
  /// the browser sees the gesture. Completes with whether audio plays now.
  Future<bool> resume();

  /// Whether [setOutputDevice] can work here.
  bool get supportsOutputSelection;

  /// Plays remote audio through the output device [deviceId] (an
  /// `audiooutput` device ID). Throws an [UnsupportedError] where
  /// [supportsOutputSelection] is false. When the platform refuses the
  /// device, completes with its error and keeps the previous output.
  Future<void> setOutputDevice(String deviceId);

  /// Stops everything and releases the elements.
  void dispose();
}

/// Called with `true` when the browser blocks playback (autoplay policy),
/// and with `false` once nothing is blocked any more.
typedef AudioBlockedListener = void Function(bool blocked);

/// Creates a [RemoteAudioSink]; the platform's by default.
typedef RemoteAudioSinkFactory =
    RemoteAudioSink Function(AudioBlockedListener onBlockedChanged);

/// **Tests only:** replaces the platform sink, so unit tests can check the
/// room's bookkeeping with a fake. Reset it to `null` afterwards.
@visibleForTesting
RemoteAudioSinkFactory? debugRemoteAudioSinkFactory;

/// Creates the sink for this platform (or [debugRemoteAudioSinkFactory]'s).
RemoteAudioSink createRemoteAudioSink(AudioBlockedListener onBlockedChanged) =>
    (debugRemoteAudioSinkFactory ?? platform.createPlatformRemoteAudioSink)(
      onBlockedChanged,
    );
