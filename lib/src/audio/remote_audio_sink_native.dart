import 'package:flutter_webrtc/flutter_webrtc.dart'
    show Helper, MediaStreamTrack;

import 'remote_audio_sink.dart';

/// The sink for native platforms (Android, iOS, macOS, Windows, Linux).
RemoteAudioSink createPlatformRemoteAudioSink(
  AudioBlockedListener onBlockedChanged,
) => const NativeRemoteAudioSink();

/// Native WebRTC plays every received audio track by itself, and there is
/// no autoplay policy: attaching and detaching do nothing.
///
/// Output selection goes through `flutter_webrtc`'s
/// [Helper.selectAudioOutput], which applies to the whole app.
class NativeRemoteAudioSink implements RemoteAudioSink {
  /// Creates the sink.
  const NativeRemoteAudioSink();

  @override
  void attach(String id, MediaStreamTrack track) {}

  @override
  void detach(String id) {}

  @override
  Future<bool> resume() async => true;

  @override
  bool get supportsOutputSelection => true;

  @override
  Future<void> setOutputDevice(String deviceId) =>
      Helper.selectAudioOutput(deviceId);

  @override
  void dispose() {}
}
