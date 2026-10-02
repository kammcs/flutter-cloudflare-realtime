import 'dart:io' show Platform;

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        AppleAudioCategory,
        AppleAudioCategoryOption,
        AppleAudioConfiguration,
        AppleAudioMode,
        Helper,
        MediaStreamTrack;

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
///
/// **Speakerphone** (phones only) gives both phones the same behaviour,
/// which `flutter_webrtc` doesn't: out of the box Android starts a call on
/// the loudspeaker and iOS on the earpiece, even with video
/// (`docs/design.md` §4.3, Speakerphone).
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

  // The real OS (not `defaultTargetPlatform`, which is Android in widget
  // tests on any host).
  @override
  bool get supportsSpeakerphone => Platform.isAndroid || Platform.isIOS;

  @override
  Future<void> setSpeakerphone(bool on) async {
    if (Platform.isIOS) {
      // WebRTC applies its base configuration again whenever it starts
      // audio, so a one-off route override wouldn't last: set the base
      // (video chat with "default to speaker", or voice chat), then the
      // route now.
      await Helper.setAppleAudioConfiguration(appleCallAudio(on));
      if (on) {
        await Helper.setSpeakerphoneOnButPreferBluetooth();
      } else {
        await Helper.setSpeakerphoneOn(false);
      }
    } else if (Platform.isAndroid) {
      // setSpeakerphoneOn also reorders the app's preferred outputs
      // (speaker or earpiece first, after Bluetooth and wired), which
      // later headset changes follow; with `on`, it then selects the
      // loudspeaker outright, so pick a headset again if there is one.
      await Helper.setSpeakerphoneOn(on);
      if (on) await Helper.setSpeakerphoneOnButPreferBluetooth();
    } else {
      throw UnsupportedError(
        'Only phones have a speakerphone switch; use setOutputDevice.',
      );
    }
  }

  @override
  void dispose() {}
}

/// The iOS audio session for a call: play and record, Bluetooth and
/// AirPlay allowed, and with [speakerphone] the video-chat mode with
/// "default to speaker" (a wired or Bluetooth headset still wins), else
/// voice chat on the earpiece.
AppleAudioConfiguration appleCallAudio(bool speakerphone) =>
    AppleAudioConfiguration(
      appleAudioCategory: AppleAudioCategory.playAndRecord,
      appleAudioCategoryOptions: {
        AppleAudioCategoryOption.allowBluetooth,
        AppleAudioCategoryOption.allowBluetoothA2DP,
        AppleAudioCategoryOption.allowAirPlay,
        if (speakerphone) AppleAudioCategoryOption.defaultToSpeaker,
      },
      appleAudioMode: speakerphone
          ? AppleAudioMode.videoChat
          : AppleAudioMode.voiceChat,
    );
