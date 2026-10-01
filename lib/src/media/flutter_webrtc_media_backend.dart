import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'media_backend.dart';
import 'media_types.dart';

/// The production [MediaBackend]: delegates to `flutter_webrtc`'s
/// `navigator.mediaDevices` and `desktopCapturer`.
///
/// Stateless, so every instance behaves the same. `ondevicechange` is a
/// single callback slot in `flutter_webrtc`; all instances share one handler,
/// which also calls any handler that was installed before it.
class FlutterWebrtcMediaBackend implements MediaBackend {
  /// Creates the backend.
  const FlutterWebrtcMediaBackend();

  @override
  MediaPlatform get platform => currentMediaPlatform();

  @override
  Future<rtc.MediaStream> getUserMedia(Map<String, dynamic> constraints) =>
      rtc.navigator.mediaDevices.getUserMedia(constraints);

  @override
  Future<rtc.MediaStream> getDisplayMedia(Map<String, dynamic> constraints) =>
      rtc.navigator.mediaDevices.getDisplayMedia(constraints);

  @override
  Future<List<MediaDevice>> enumerateDevices() async {
    if (!kIsWeb) {
      // Native `enumerateDevices` drops the `facing` that Android and Darwin
      // report for each camera; the raw list keeps it. Labels can't stand
      // in on iOS, where they are localized ("Front Camera" is English).
      final List<dynamic> sources;
      try {
        // ignore: deprecated_member_use
        sources = await rtc.navigator.mediaDevices.getSources();
      } catch (_) {
        return _enumerate(); // Not implemented here: labels decide.
      }
      return [
        for (final source in sources)
          if (source is Map) ?mediaDeviceFromSource(source),
      ];
    }
    return _enumerate();
  }

  static Future<List<MediaDevice>> _enumerate() async {
    final infos = await rtc.navigator.mediaDevices.enumerateDevices();
    return [
      for (final info in infos)
        ?mediaDeviceFromSource({
          'deviceId': info.deviceId,
          'kind': info.kind,
          'label': info.label,
          'groupId': info.groupId,
        }),
    ];
  }

  @override
  Stream<void> get deviceChanges => _DeviceChangeHub.stream;

  @override
  DesktopCapturerBackend? get desktopCapturer =>
      platform.isDesktop ? const _FlutterWebrtcDesktopCapturer() : null;
}

/// A [MediaDevice] from one entry of `flutter_webrtc`'s device list, or
/// `null` for a kind this package doesn't use.
///
/// Native platforms give `facing` for cameras: `front`, `back` (Android,
/// Darwin), or `unspecified` (a Mac's built-in camera). Browsers don't, so
/// the label decides there ([cameraFacingFromLabel]).
@visibleForTesting
MediaDevice? mediaDeviceFromSource(Map<Object?, Object?> source) {
  final kind = MediaDeviceKind.fromWireName('${source['kind'] ?? ''}');
  if (kind == null) return null;
  final label = '${source['label'] ?? ''}';
  final groupId = source['groupId'];
  return MediaDevice(
    deviceId: '${source['deviceId'] ?? ''}',
    kind: kind,
    label: label,
    groupId: groupId is String ? groupId : null,
    facing: kind == MediaDeviceKind.videoInput
        ? switch (source['facing']) {
            'front' || 'user' => CameraFacing.user,
            'back' || 'environment' => CameraFacing.environment,
            _ => cameraFacingFromLabel(label),
          }
        : null,
  );
}

/// Which way a camera faces, from its label: "Front Camera", "Back
/// Camera" (Safari, iOS), "camera2 1, facing front" (Chrome on Android),
/// "Camera 0, Facing back" (the Android plugin). `null` when the label
/// doesn't say, as for desktop webcams.
@visibleForTesting
CameraFacing? cameraFacingFromLabel(String label) {
  final words = label.toLowerCase();
  if (RegExp(r'\b(front|user)\b').hasMatch(words)) return CameraFacing.user;
  if (RegExp(r'\b(back|rear|environment)\b').hasMatch(words)) {
    return CameraFacing.environment;
  }
  return null;
}

/// The [MediaPlatform] this code is running on.
MediaPlatform currentMediaPlatform() {
  if (kIsWeb) return MediaPlatform.web;
  return switch (defaultTargetPlatform) {
    TargetPlatform.windows => MediaPlatform.windows,
    TargetPlatform.macOS => MediaPlatform.macos,
    TargetPlatform.linux => MediaPlatform.linux,
    TargetPlatform.android => MediaPlatform.android,
    TargetPlatform.iOS => MediaPlatform.ios,
    TargetPlatform.fuchsia => MediaPlatform.unknown,
  };
}

/// Shares `navigator.mediaDevices.ondevicechange` (a single callback slot)
/// among all listeners, and restores the previous handler when the last one
/// leaves.
abstract final class _DeviceChangeHub {
  static StreamController<void>? _controller;
  static void Function(dynamic event)? _previous;

  static Stream<void> get stream =>
      (_controller ??= StreamController<void>.broadcast(
        onListen: _install,
        onCancel: _uninstall,
      )).stream;

  static void _install() {
    try {
      final mediaDevices = rtc.navigator.mediaDevices;
      final previous = mediaDevices.ondevicechange;
      _previous = previous == null ? null : (event) => previous(event);
      mediaDevices.ondevicechange = (event) {
        _previous?.call(event);
        _controller?.add(null);
      };
    } catch (error) {
      debugPrint('cloudflare_realtime: cannot watch device changes: $error');
    }
  }

  static void _uninstall() {
    try {
      rtc.navigator.mediaDevices.ondevicechange = _previous;
    } catch (_) {
      // Nothing to restore.
    }
    _previous = null;
  }
}

class _FlutterWebrtcDesktopCapturer implements DesktopCapturerBackend {
  const _FlutterWebrtcDesktopCapturer();

  static ScreenSource _snapshot(rtc.DesktopCapturerSource source) =>
      ScreenSource(
        id: source.id,
        name: source.name,
        type: source.type == rtc.SourceType.Window
            ? ScreenSourceType.window
            : ScreenSourceType.screen,
        thumbnail: source.thumbnail,
      );

  static List<rtc.SourceType> _types(Set<ScreenSourceType> types) => [
    for (final type in types)
      switch (type) {
        ScreenSourceType.screen => rtc.SourceType.Screen,
        ScreenSourceType.window => rtc.SourceType.Window,
      },
  ];

  @override
  Future<List<ScreenSource>> getSources({
    required Set<ScreenSourceType> types,
    ({int width, int height})? thumbnailSize,
  }) async {
    final sources = await rtc.desktopCapturer.getSources(
      types: _types(types),
      thumbnailSize: thumbnailSize == null
          ? null
          : rtc.ThumbnailSize(thumbnailSize.width, thumbnailSize.height),
    );
    return [for (final source in sources) _snapshot(source)];
  }

  @override
  Future<bool> updateSources({required Set<ScreenSourceType> types}) =>
      rtc.desktopCapturer.updateSources(types: _types(types));

  @override
  Stream<ScreenSource> get onAdded =>
      rtc.desktopCapturer.onAdded.stream.map(_snapshot);

  @override
  Stream<ScreenSource> get onRemoved =>
      rtc.desktopCapturer.onRemoved.stream.map(_snapshot);

  @override
  Stream<ScreenSource> get onNameChanged =>
      rtc.desktopCapturer.onNameChanged.stream.map(_snapshot);

  @override
  Stream<ScreenSource> get onThumbnailChanged =>
      rtc.desktopCapturer.onThumbnailChanged.stream.map(_snapshot);
}
