import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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
  Future<rtc.MediaStream> getUserMedia(Map<String, dynamic> constraints) async {
    if (audioInputToSelect(constraints, platform) case final input?) {
      await rtc.Helper.selectAudioInput(input);
    }
    return rtc.navigator.mediaDevices.getUserMedia(constraints);
  }

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
      // The Windows and Linux plugin (flutter_webrtc's common C++) makes the
      // facing up: "front" for the second camera, "back" for the others.
      final pluginFacing =
          platform != MediaPlatform.windows && platform != MediaPlatform.linux;
      return orderBuiltInCameras([
        for (final source in sources)
          if (source is Map)
            ?mediaDeviceFromSource(source, pluginFacing: pluginFacing),
      ]);
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

  @override
  ScreenCaptureServiceBackend? get screenCaptureService =>
      platform == MediaPlatform.android
      ? const AndroidScreenCaptureService()
      : null;

  @override
  BroadcastExtensionBackend? get broadcastExtension =>
      platform == MediaPlatform.ios ? const IosBroadcastExtension() : null;
}

/// The iOS [BroadcastExtensionBackend]: this package's plugin
/// (`ScreenBroadcast.swift`), which checks the setup, hands the settings to
/// the extension through the App Group, and forwards the extension's
/// Darwin notifications.
class IosBroadcastExtension implements BroadcastExtensionBackend {
  /// Creates the backend.
  const IosBroadcastExtension();

  static const _methods = MethodChannel(
    'dev.kammcs.cloudflare_realtime/screen_broadcast',
  );
  static const _events = EventChannel(
    'dev.kammcs.cloudflare_realtime/screen_broadcast_events',
  );

  static final Stream<BroadcastExtensionEvent> _stream = _events
      .receiveBroadcastStream()
      .map((event) => event is Map ? event['event'] : null)
      .where((name) => name == 'started' || name == 'finished')
      .map(
        (name) => name == 'started'
            ? BroadcastExtensionEvent.started
            : BroadcastExtensionEvent.finished,
      )
      .asBroadcastStream();

  @override
  Future<BroadcastExtensionStatus> status() async {
    final map = await _methods.invokeMapMethod<String, Object?>('status');
    final codes = map?['problems'];
    return BroadcastExtensionStatus(
      problems: [
        if (codes is List)
          for (final code in codes) ?BroadcastSetupProblem.fromCode('$code'),
      ],
      broadcasting: map?['broadcasting'] == true,
    );
  }

  @override
  Future<void> prepare({required int frameRate, required double scale}) =>
      _methods.invokeMethod<void>('prepare', {
        'frameRate': frameRate,
        'scale': scale,
      });

  @override
  Future<void> abandon() => _methods.invokeMethod<void>('abandon');

  @override
  Stream<BroadcastExtensionEvent> get events => _stream;
}

/// The Android [ScreenCaptureServiceBackend]: `flutter_webrtc`'s consent
/// dialog (`Helper.requestCapturePermission`, whose result its next
/// `getDisplayMedia` uses) and this package's foreground service
/// (`ScreenCapture.kt`, `ScreenCaptureService.kt`).
class AndroidScreenCaptureService implements ScreenCaptureServiceBackend {
  /// Creates the backend.
  const AndroidScreenCaptureService();

  static const _methods = MethodChannel(
    'dev.kammcs.cloudflare_realtime/screen_capture',
  );
  static const _events = EventChannel(
    'dev.kammcs.cloudflare_realtime/screen_capture_events',
  );

  static final Stream<String?> _stopped = _events
      .receiveBroadcastStream()
      .where((event) => event is Map && event['event'] == 'stopped')
      .map((event) {
        final trackId = (event as Map)['trackId'];
        return trackId is String ? trackId : null;
      })
      .asBroadcastStream();

  @override
  Future<bool> requestConsent() async {
    try {
      await _methods.invokeMethod<bool>('prepare');
    } catch (error) {
      // The notification permission is a nicety; the share works without.
      debugPrint('cloudflare_realtime: notification permission: $error');
    }
    // Keeps the system's choice of a single app or the entire screen.
    return await rtc.Helper.requestCapturePermission();
  }

  @override
  Future<void> startService() => _methods.invokeMethod<void>('startService');

  @override
  Future<bool> watch(String trackId) async =>
      await _methods.invokeMethod<bool>('watch', {'trackId': trackId}) ?? false;

  @override
  Future<void> stopService() => _methods.invokeMethod<void>('stopService');

  @override
  Stream<String?> get stopped => _stopped;
}

/// The microphone to select before `getUserMedia` with [constraints] on
/// [platform], or `null` when the request picks it by itself.
///
/// The Android plugin reads the microphone named in the constraints
/// (`optional: [{sourceId: id}]`) only to report it back in the track's
/// settings: it captures from whichever input was selected last. Only
/// `Helper.selectAudioInput` changes it. Darwin, Windows and browsers
/// select it from the constraints.
@visibleForTesting
String? audioInputToSelect(
  Map<String, dynamic> constraints,
  MediaPlatform platform,
) {
  if (platform != MediaPlatform.android) return null;
  final audio = constraints['audio'];
  if (audio is! Map) return null;
  final optional = audio['optional'];
  if (optional is! List) return null;
  for (final entry in optional) {
    final id = entry is Map ? entry['sourceId'] : null;
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}

/// A [MediaDevice] from one entry of `flutter_webrtc`'s device list, or
/// `null` for a kind this package doesn't use.
///
/// Native platforms give `facing` for cameras: `front`, `back` (Android,
/// Darwin), or `unspecified` (a Mac's built-in camera). Browsers don't, so
/// the label decides there ([cameraFacingFromLabel]). With [pluginFacing]
/// `false` (Windows and Linux, whose plugin calls the second camera
/// `front` and every other one `back`), the label decides too.
@visibleForTesting
MediaDevice? mediaDeviceFromSource(
  Map<Object?, Object?> source, {
  bool pluginFacing = true,
}) {
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
        ? switch (pluginFacing ? source['facing'] : null) {
            'front' || 'user' => CameraFacing.user,
            'back' || 'environment' => CameraFacing.environment,
            _ => cameraFacingFromLabel(label),
          }
        : null,
  );
}

final _builtInCamera = RegExp(
  r'^com\.apple\.avfoundation\.avcapturedevice\.built-in_video:(\d+)$',
);

/// [devices] with Apple's built-in cameras in the order of their index
/// (`...built-in_video:N`), in the slots they already hold; other devices
/// keep their place.
///
/// iOS lists its virtual multi-camera devices first ("Back Triple Camera",
/// "Back Dual Camera": `:7`, `:3`), and `flutter_webrtc`'s capturer gets
/// no frames from them (an iPhone on iOS 27: 1–2 frames in 6 s, against
/// 150–176 from "Back Camera"). The plain cameras have the lowest indexes
/// (`:0` back, `:1` front), so this puts them first, without relying on
/// labels, which are localized.
@visibleForTesting
List<MediaDevice> orderBuiltInCameras(List<MediaDevice> devices) {
  int? index(MediaDevice d) {
    final match = _builtInCamera.firstMatch(d.deviceId);
    return match == null ? null : int.parse(match.group(1)!);
  }

  final slots = [
    for (final (i, d) in devices.indexed)
      if (index(d) != null) i,
  ];
  if (slots.length < 2) return devices;
  final sorted = [for (final i in slots) devices[i]]
    ..sort((a, b) => index(a)!.compareTo(index(b)!));
  final result = List.of(devices);
  for (final (n, slot) in slots.indexed) {
    result[slot] = sorted[n];
  }
  return result;
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
