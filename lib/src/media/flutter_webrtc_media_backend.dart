import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import '../diagnostics/log.dart';
import '../util/native_negotiation.dart';
import 'media_backend.dart';
import 'media_types.dart';
import 'screen_geometry.dart';
import 'screen_geometry_native.dart';
import 'windows_audio_defaults.dart';

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
    final platform = this.platform;
    if (audioInputToSelect(constraints, platform) case final input?) {
      // Before the selection, so a re-selection of the previous input
      // can't land after it.
      if (platform == MediaPlatform.macos) {
        _macInputReselector.selected(input);
        // The selection waits for the audio device module, which may be
        // busy under a description being applied: don't block the
        // platform thread on it meanwhile.
        await NativeNegotiation.whenIdle();
      }
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
      final devices = orderBuiltInCameras([
        for (final source in sources)
          if (source is Map)
            ?mediaDeviceFromSource(source, pluginFacing: pluginFacing),
      ]);
      if (platform != MediaPlatform.windows) return devices;
      // The Windows plugin lists audio devices by endpoint ID and opens
      // the first one unless told otherwise: ask Windows for its defaults.
      final defaults = readWindowsDefaultAudioEndpoints();
      return markDefaultAudioDevices(
        devices,
        input: defaults?.input,
        output: defaults?.output,
      );
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
      RealtimeLog.warning(
        'asking for the notification permission failed',
        error: error,
      );
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
/// The Android and macOS plugins read the microphone named in the
/// constraints (`optional: [{sourceId: id}]`) only to report it back in
/// the track's settings: they capture from whichever input was selected
/// last (on macOS, libwebrtc's one audio device module per process, which
/// starts on the system default). Only `Helper.selectAudioInput` changes
/// it. The Darwin plugin means to select it from the constraints on
/// macOS, but behind `#if !defined(TARGET_OS_IPHONE)`, which is never
/// true on an Apple platform (`TARGET_OS_IPHONE` is defined as 0 on
/// macOS; flutter-webrtc issue #2216). Windows and browsers select it from the constraints. iOS is
/// left alone: there `selectAudioInput` sets the audio session's preferred
/// input, which moves the call's audio route (docs/design.md §4.6).
@visibleForTesting
String? audioInputToSelect(
  Map<String, dynamic> constraints,
  MediaPlatform platform,
) {
  if (platform != MediaPlatform.android && platform != MediaPlatform.macos) {
    return null;
  }
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

final _macInputReselector = MacInputReselector(rtc.Helper.selectAudioInput);

/// Selects the microphone chosen on macOS again a few times after the
/// switch, because libwebrtc's audio device module sometimes undoes it.
///
/// The module (WebRTC-SDK's `AudioEngineDevice`) goes back to the system
/// default input whenever it sees the device list change, and rebuilding
/// its voice-processing graph for the new input can change that list: on a
/// MacBook, 1 switch in 5 to 1 in 2 logged `Setting input device: MacBook
/// Pro Microphone`, then `Did update devices` and `Using default input
/// device` within a second or two (docs/design.md §4.5). `flutter_webrtc`
/// doesn't pass that event on, so the backend selects the input again
/// after each of [delays]. Selecting the input the module already uses
/// does nothing, so this costs nothing when the switch held.
///
/// The system default (`default`) needs nothing, and a newer selection
/// cancels the pending ones. A failure (the device is gone) is ignored:
/// the source moves to another device, which is then selected.
///
/// A re-selection first waits for [whenIdle] (by default, until no
/// description is being applied, [NativeNegotiation]): the plugin selects
/// on the platform thread and waits for the audio device module, which
/// the first audio send can keep busy for many seconds on macOS. The app
/// froze for 8 s after a join that way.
@visibleForTesting
class MacInputReselector {
  /// Creates a reselector that selects inputs with [select].
  MacInputReselector(
    this._select, {
    this.delays = const [
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
    ],
    Future<void> Function() whenIdle = NativeNegotiation.whenIdle,
  }) : _whenIdle = whenIdle;

  final Future<void> Function(String deviceId) _select;
  final Future<void> Function() _whenIdle;
  int _generation = 0;

  /// When to select the input again, counted from [selected].
  final List<Duration> delays;

  final List<Timer> _timers = [];

  /// Records that [deviceId] is being selected for a capture, cancels the
  /// pending selections of the previous input, and schedules selecting
  /// [deviceId] again.
  void selected(String deviceId) {
    cancel();
    if (deviceId == 'default') return;
    final generation = _generation;
    for (final delay in delays) {
      _timers.add(
        Timer(delay, () {
          unawaited(_reselect(deviceId, generation));
        }),
      );
    }
  }

  Future<void> _reselect(String deviceId, int generation) async {
    try {
      await _whenIdle();
      // Cancelled (or another input chosen) while waiting.
      if (generation != _generation) return;
      await _select(deviceId);
    } catch (_) {
      // Gone: the source moves to another device and selects it.
    }
  }

  /// Cancels the pending selections.
  void cancel() {
    _generation++;
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
  }
}

/// A [MediaDevice] from one entry of `flutter_webrtc`'s device list, or
/// `null` for a kind this package doesn't use.
///
/// Native platforms give `facing` for cameras: `front`, `back` (Android,
/// Darwin), or `unspecified` (a Mac's built-in camera). Browsers don't, so
/// the label decides there ([cameraFacingFromLabel]). With [pluginFacing]
/// `false` (Windows and Linux, whose plugin calls the second camera
/// `front` and every other one `back`), the label decides too.
///
/// Chromium's `default` and `communications` audio entries ("Default -
/// Headset Microphone") are marked [MediaDevice.isDefault].
@visibleForTesting
MediaDevice? mediaDeviceFromSource(
  Map<Object?, Object?> source, {
  bool pluginFacing = true,
}) {
  final kind = MediaDeviceKind.fromWireName('${source['kind'] ?? ''}');
  if (kind == null) return null;
  final label = '${source['label'] ?? ''}';
  final groupId = source['groupId'];
  final deviceId = '${source['deviceId'] ?? ''}';
  return MediaDevice(
    deviceId: deviceId,
    kind: kind,
    label: label,
    groupId: groupId is String ? groupId : null,
    isDefault:
        kind != MediaDeviceKind.videoInput &&
        _browserDefaultIds.contains(deviceId),
    facing: kind == MediaDeviceKind.videoInput
        ? switch (pluginFacing ? source['facing'] : null) {
            'front' || 'user' => CameraFacing.user,
            'back' || 'environment' => CameraFacing.environment,
            _ => cameraFacingFromLabel(label),
          }
        : null,
  );
}

/// [devices] with the microphone whose ID is [input] and the speaker whose
/// ID is [output] marked [MediaDevice.isDefault] (and no others), in the
/// same order.
///
/// On Windows, `flutter_webrtc` lists audio devices in Core Audio's
/// enumeration order (by endpoint ID, unrelated to the user's choice) and
/// doesn't say which is the default, so the backend reads the defaults
/// from the OS ([readWindowsDefaultAudioEndpoints]) and marks them here.
@visibleForTesting
List<MediaDevice> markDefaultAudioDevices(
  List<MediaDevice> devices, {
  String? input,
  String? output,
}) => [
  for (final device in devices)
    switch (device.kind) {
      MediaDeviceKind.audioInput => _withDefault(
        device,
        input != null && device.deviceId == input,
      ),
      MediaDeviceKind.audioOutput => _withDefault(
        device,
        output != null && device.deviceId == output,
      ),
      MediaDeviceKind.videoInput => device,
    },
];

MediaDevice _withDefault(MediaDevice device, bool isDefault) =>
    device.isDefault == isDefault
    ? device
    : MediaDevice(
        deviceId: device.deviceId,
        kind: device.kind,
        label: device.label,
        groupId: device.groupId,
        facing: device.facing,
        isDefault: isDefault,
      );

/// Chromium's alias entries for the system's default devices.
const _browserDefaultIds = {'default', 'communications'};

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
      RealtimeLog.warning('cannot watch device changes', error: error);
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

  /// Display and window geometry from the operating system (macOS and
  /// Windows; `null` answers elsewhere).
  static final _geometry = ScreenGeometryLookup(createNativeScreenGeometry());

  static ScreenSource _snapshot(rtc.DesktopCapturerSource source) =>
      ScreenSource(
        id: source.id,
        name: source.name,
        type: source.type == rtc.SourceType.Window
            ? ScreenSourceType.window
            : ScreenSourceType.screen,
        thumbnail: source.thumbnail,
      );

  static ScreenSource _snapshotWithGeometry(rtc.DesktopCapturerSource source) =>
      _geometry.withGeometryOf(_snapshot(source));

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
    return _geometry.withGeometry([
      for (final source in sources) _snapshot(source),
    ]);
  }

  @override
  Future<bool> updateSources({required Set<ScreenSourceType> types}) =>
      rtc.desktopCapturer.updateSources(types: _types(types));

  @override
  Stream<ScreenSource> get onAdded =>
      rtc.desktopCapturer.onAdded.stream.map(_snapshotWithGeometry);

  @override
  Stream<ScreenSource> get onRemoved =>
      rtc.desktopCapturer.onRemoved.stream.map(_snapshot);

  @override
  Stream<ScreenSource> get onNameChanged =>
      rtc.desktopCapturer.onNameChanged.stream.map(_snapshotWithGeometry);

  @override
  Stream<ScreenSource> get onThumbnailChanged =>
      rtc.desktopCapturer.onThumbnailChanged.stream.map(_snapshotWithGeometry);

  @override
  Future<ScreenGeometry?> geometryOf(ScreenSource source) async =>
      _geometry.geometryOf(source.type, source.id);
}
