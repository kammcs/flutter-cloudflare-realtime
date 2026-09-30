/// @docImport 'device_media_source.dart';
/// @docImport 'screen_share_source.dart';
library;

import 'package:flutter/foundation.dart';

import 'media_types.dart';

/// A capture resolution and frame rate.
///
/// The named presets are 16:9 and line up with the simulcast plan in
/// `docs/design.md` §6: publishing [h720] gives layer `a` at 1280×720,
/// `b` at ½ (640×360, the same as [h360]) and `c` at ¼ (320×180, [h180]).
@immutable
class VideoPreset {
  /// Creates a preset.
  const VideoPreset({
    required this.width,
    required this.height,
    required this.frameRate,
  });

  /// 1920×1080 at 30 fps.
  static const h1080 = VideoPreset(width: 1920, height: 1080, frameRate: 30);

  /// 1280×720 at 30 fps. The default camera preset.
  static const h720 = VideoPreset(width: 1280, height: 720, frameRate: 30);

  /// 960×540 at 30 fps.
  static const h540 = VideoPreset(width: 960, height: 540, frameRate: 30);

  /// 640×360 at 30 fps.
  static const h360 = VideoPreset(width: 640, height: 360, frameRate: 30);

  /// 320×180 at 15 fps.
  static const h180 = VideoPreset(width: 320, height: 180, frameRate: 15);

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  /// Frames per second.
  final int frameRate;

  /// The dimensions of a simulcast layer sent with
  /// `scaleResolutionDownBy: factor`, rounded down.
  ({int width, int height}) scaledDownBy(num factor) =>
      (width: width ~/ factor, height: height ~/ factor);

  @override
  bool operator ==(Object other) =>
      other is VideoPreset &&
      other.width == width &&
      other.height == height &&
      other.frameRate == frameRate;

  @override
  int get hashCode => Object.hash(width, height, frameRate);

  @override
  String toString() => 'VideoPreset(${width}x$height@$frameRate)';
}

/// Which way a mobile camera faces.
enum CameraFacing {
  /// The front ("selfie") camera.
  user,

  /// The back camera.
  environment,
}

/// Camera capture settings.
@immutable
class CameraOptions {
  /// Creates camera settings.
  const CameraOptions({this.preset = VideoPreset.h720, this.facing});

  /// The requested resolution and frame rate. Cameras pick the closest mode
  /// they support, so the captured track may differ.
  final VideoPreset preset;

  /// Front or back camera, for mobile. Ignored once a specific device is
  /// selected.
  final CameraFacing? facing;

  /// Returns a copy with the given fields replaced.
  CameraOptions copyWith({VideoPreset? preset, CameraFacing? facing}) =>
      CameraOptions(
        preset: preset ?? this.preset,
        facing: facing ?? this.facing,
      );

  @override
  bool operator ==(Object other) =>
      other is CameraOptions &&
      other.preset == preset &&
      other.facing == facing;

  @override
  int get hashCode => Object.hash(preset, facing);

  @override
  String toString() => 'CameraOptions($preset, facing: ${facing?.name})';
}

/// Microphone capture settings.
///
/// All three processing steps default to on, which is what calls want.
/// Turn them off for music or for audio that is already processed.
@immutable
class MicrophoneOptions {
  /// Creates microphone settings.
  const MicrophoneOptions({
    this.echoCancellation = true,
    this.noiseSuppression = true,
    this.autoGainControl = true,
  });

  /// Acoustic echo cancellation (AEC).
  final bool echoCancellation;

  /// Noise suppression (NS).
  final bool noiseSuppression;

  /// Automatic gain control (AGC).
  final bool autoGainControl;

  /// Returns a copy with the given fields replaced.
  MicrophoneOptions copyWith({
    bool? echoCancellation,
    bool? noiseSuppression,
    bool? autoGainControl,
  }) => MicrophoneOptions(
    echoCancellation: echoCancellation ?? this.echoCancellation,
    noiseSuppression: noiseSuppression ?? this.noiseSuppression,
    autoGainControl: autoGainControl ?? this.autoGainControl,
  );

  @override
  bool operator ==(Object other) =>
      other is MicrophoneOptions &&
      other.echoCancellation == echoCancellation &&
      other.noiseSuppression == noiseSuppression &&
      other.autoGainControl == autoGainControl;

  @override
  int get hashCode =>
      Object.hash(echoCancellation, noiseSuppression, autoGainControl);

  @override
  String toString() =>
      'MicrophoneOptions(aec: $echoCancellation, ns: $noiseSuppression, '
      'agc: $autoGainControl)';
}

/// Screen share capture settings.
@immutable
class ScreenShareOptions {
  /// Creates screen share settings.
  const ScreenShareOptions({
    this.frameRate = 15,
    this.captureAudio = false,
    this.showCursor,
  });

  /// Frames per second. On desktop this is `flutter_webrtc`'s
  /// `mandatory.frameRate`; in browsers it is an ideal.
  ///
  /// The default, 15, suits documents, slides and code: screen content
  /// needs sharp text more than motion, and fewer frames leave more bits
  /// for each (`docs/design.md` §12, question 2). Use 30 for video or
  /// animation, with `ScreenSharePresets.motion` when publishing.
  final int frameRate;

  /// Whether to also capture system or tab audio.
  ///
  /// Supported on Windows (loopback capture, `flutter_webrtc` 1.5.0+) and in
  /// Chromium browsers (tab audio). Elsewhere the share has no audio track.
  final bool captureAudio;

  /// Whether the cursor is drawn into the capture. `null` keeps the platform
  /// default (`Helper.screenCaptureShowCursor` on desktop).
  final bool? showCursor;

  /// Returns a copy with the given fields replaced.
  ScreenShareOptions copyWith({
    int? frameRate,
    bool? captureAudio,
    bool? showCursor,
  }) => ScreenShareOptions(
    frameRate: frameRate ?? this.frameRate,
    captureAudio: captureAudio ?? this.captureAudio,
    showCursor: showCursor ?? this.showCursor,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenShareOptions &&
      other.frameRate == frameRate &&
      other.captureAudio == captureAudio &&
      other.showCursor == showCursor;

  @override
  int get hashCode => Object.hash(frameRate, captureAudio, showCursor);
}

/// The constraint entries that pick [deviceId] on [platform].
///
/// Browsers take the W3C `deviceId: {exact: id}`. The native
/// `flutter_webrtc` implementations don't: Windows and Linux only read
/// `optional: [{sourceId: id}]` (and treat a string `deviceId` on audio as
/// the *output* device), and Android and Darwin read `deviceId` as a plain
/// string. `optional.sourceId` is the one form every native platform reads.
Map<String, dynamic> deviceSelector(String deviceId, MediaPlatform platform) =>
    platform == MediaPlatform.web
    ? {
        'deviceId': {'exact': deviceId},
      }
    : {
        'optional': [
          {'sourceId': deviceId},
        ],
      };

/// `getUserMedia` constraints for a camera.
Map<String, dynamic> cameraConstraints(
  CameraOptions options, {
  required MediaPlatform platform,
  MediaDevice? device,
}) => {
  'audio': false,
  'video': {
    'width': {'ideal': options.preset.width},
    'height': {'ideal': options.preset.height},
    'frameRate': {'ideal': options.preset.frameRate},
    if (device != null && device.deviceId.isNotEmpty)
      ...deviceSelector(device.deviceId, platform)
    else if (options.facing != null)
      'facingMode': options.facing!.name,
  },
};

/// `getUserMedia` constraints for a microphone.
Map<String, dynamic> microphoneConstraints(
  MicrophoneOptions options, {
  required MediaPlatform platform,
  MediaDevice? device,
}) => {
  'video': false,
  'audio': {
    'echoCancellation': options.echoCancellation,
    'noiseSuppression': options.noiseSuppression,
    'autoGainControl': options.autoGainControl,
    if (device != null && device.deviceId.isNotEmpty)
      ...deviceSelector(device.deviceId, platform),
  },
};

/// `getDisplayMedia` constraints for a desktop source, in the shape the
/// `flutter_webrtc` desktop implementations read: `deviceId: {exact: id}`
/// and a `mandatory.frameRate` double.
Map<String, dynamic> desktopScreenConstraints(
  ScreenShareOptions options, {
  required String sourceId,
}) => {
  'audio': options.captureAudio,
  'video': {
    'deviceId': {'exact': sourceId},
    'mandatory': {'frameRate': options.frameRate.toDouble()},
    if (options.showCursor != null)
      'cursor': options.showCursor! ? 'always' : 'never',
  },
};

/// `getDisplayMedia` constraints for a browser, which shows its own picker.
Map<String, dynamic> webScreenConstraints(ScreenShareOptions options) => {
  'audio': options.captureAudio,
  'video': {
    'frameRate': {'ideal': options.frameRate},
    if (options.showCursor != null)
      'cursor': options.showCursor! ? 'always' : 'never',
  },
};
