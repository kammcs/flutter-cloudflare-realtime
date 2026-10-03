import 'package:flutter_webrtc/flutter_webrtc.dart'
    show Helper, MediaStreamTrack, navigator;

import 'audio_output_exception.dart';
import 'remote_audio_sink.dart';

/// The sink for native platforms (Android, iOS, macOS, Windows, Linux).
RemoteAudioSink createPlatformRemoteAudioSink(
  AudioBlockedListener onBlockedChanged,
) => const NativeRemoteAudioSink();

/// Switches the app's audio output to a device ID.
typedef SelectAudioOutput = Future<void> Function(String deviceId);

/// Lists the IDs of the audio output devices.
typedef ListAudioOutputs = Future<List<String>> Function();

/// Native WebRTC plays every received audio track by itself, and there is
/// no autoplay policy: attaching and detaching do nothing.
///
/// Output selection goes through `flutter_webrtc`'s
/// [Helper.selectAudioOutput], which applies to the whole app. On phones,
/// call audio routing (`CallAudio`) chooses the output instead.
class NativeRemoteAudioSink implements RemoteAudioSink {
  /// Creates the sink. [selectOutput] and [listOutputs] replace
  /// `flutter_webrtc` in tests.
  const NativeRemoteAudioSink({
    SelectAudioOutput selectOutput = Helper.selectAudioOutput,
    ListAudioOutputs listOutputs = _audioOutputIds,
  }) : _selectOutput = selectOutput,
       _listOutputs = listOutputs;

  final SelectAudioOutput _selectOutput;
  final ListAudioOutputs _listOutputs;

  @override
  void attach(String id, MediaStreamTrack track) {}

  @override
  void detach(String id) {}

  @override
  Future<bool> resume() async => true;

  @override
  bool get supportsOutputSelection => true;

  /// Throws an [AudioOutputException] when the platform refuses the device:
  /// [AudioOutputFailure.notFound] when it isn't in the device list (macOS
  /// and Windows refuse an unknown ID), [AudioOutputFailure.other] for
  /// anything else, such as iOS failing to override the route.
  @override
  Future<void> setOutputDevice(String deviceId) async {
    try {
      await _selectOutput(deviceId);
    } catch (error, stack) {
      Error.throwWithStackTrace(
        AudioOutputException(
          await _reasonFor(deviceId),
          deviceId: deviceId,
          cause: error,
        ),
        stack,
      );
    }
  }

  Future<AudioOutputFailure> _reasonFor(String deviceId) async {
    try {
      final ids = await _listOutputs();
      return ids.contains(deviceId)
          ? AudioOutputFailure.other
          : AudioOutputFailure.notFound;
    } catch (_) {
      // Without a list, there is no telling.
      return AudioOutputFailure.other;
    }
  }

  @override
  void dispose() {}
}

Future<List<String>> _audioOutputIds() async => [
  for (final device in await navigator.mediaDevices.enumerateDevices())
    if (device.kind == 'audiooutput') device.deviceId,
];
