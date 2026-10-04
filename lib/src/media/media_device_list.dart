/// @docImport 'device_media_source.dart';
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'flutter_webrtc_media_backend.dart';
import 'media_backend.dart';
import 'media_types.dart';

const ListEquality<MediaDevice> _listEquality = ListEquality<MediaDevice>();

/// The cameras, microphones and audio outputs the platform reports, kept up
/// to date as devices are plugged in and out.
///
/// Ported from partytracks' `devices$`: enumerate once, then re-enumerate on
/// every `devicechange` event, and only emit when the list really changed.
///
/// One list can be shared by several sources (a [CameraSource] and a
/// [MicrophoneSource], say). A source that creates its own list disposes it;
/// a list passed in is left for its owner to dispose.
///
/// On the web, device IDs and labels are empty until the user grants
/// permission. Sources call [refresh] after their first successful capture
/// so the full list appears.
///
/// **The list enumerates when it is first used:** reading [ready], [devices]
/// (or a kind's list) or one of the change streams, or calling [refresh].
/// Until then it costs nothing, and ignores device changes. A
/// [MicrophoneSource] on macOS with no preferred device captures from the
/// system default without the list (`docs/design.md` §4.5, Capture before
/// listing on macOS), because the first enumeration in a process blocks a
/// Mac's UI thread for seconds.
class MediaDeviceList {
  /// Creates the list. It enumerates devices through [backend] when first
  /// used.
  MediaDeviceList({MediaBackend backend = const FlutterWebrtcMediaBackend()})
    : _backend = backend {
    _deviceChanges = backend.deviceChanges.listen((_) {
      if (_started) refresh();
    });
  }

  final MediaBackend _backend;
  final StateStream<List<MediaDevice>> _devices = StateStream(
    const [],
    equals: _listEquality.equals,
  );
  late final StreamSubscription<void> _deviceChanges;
  bool _started = false;
  late final Future<void> _ready = _start();
  late final CoalescingRunner _enumerator = CoalescingRunner(_enumerate);
  bool _disposed = false;

  Future<void> _start() {
    _started = true;
    return _disposed ? Future.value() : _enumerator.run();
  }

  /// Completes when the first enumeration has finished (successfully or
  /// not). Starts it if the list wasn't used yet.
  Future<void> get ready => _ready;

  /// Every device, in the order the platform lists them. Empty until the
  /// first enumeration finishes; reading it starts that enumeration.
  List<MediaDevice> get devices {
    unawaited(_ready);
    return _devices.value;
  }

  /// [devices], replaying the current list to each new listener, then
  /// emitting when it changes. Completes after [dispose]. Starts the first
  /// enumeration.
  Stream<List<MediaDevice>> get devicesChanges {
    unawaited(_ready);
    return _devices.stream;
  }

  /// The devices of one [kind], now.
  List<MediaDevice> devicesOfKind(MediaDeviceKind kind) =>
      _ofKind(devices, kind);

  /// [devicesOfKind], replaying the current list to each new listener, then
  /// emitting when it changes.
  Stream<List<MediaDevice>> devicesOfKindChanges(MediaDeviceKind kind) =>
      _kindChanges(devicesChanges, kind);

  static Stream<List<MediaDevice>> _kindChanges(
    Stream<List<MediaDevice>> all,
    MediaDeviceKind kind,
  ) {
    List<MediaDevice>? previous;
    return all.map((all) => _ofKind(all, kind)).where((list) {
      if (previous != null && _listEquality.equals(previous, list)) {
        return false;
      }
      previous = list;
      return true;
    });
  }

  /// The microphones, now.
  List<MediaDevice> get audioInputs =>
      devicesOfKind(MediaDeviceKind.audioInput);

  /// [audioInputs], replaying the current list, then its changes.
  Stream<List<MediaDevice>> get audioInputsChanges =>
      devicesOfKindChanges(MediaDeviceKind.audioInput);

  /// The cameras, now.
  List<MediaDevice> get videoInputs =>
      devicesOfKind(MediaDeviceKind.videoInput);

  /// [videoInputs], replaying the current list, then its changes.
  Stream<List<MediaDevice>> get videoInputsChanges =>
      devicesOfKindChanges(MediaDeviceKind.videoInput);

  /// The speakers and headsets, now.
  List<MediaDevice> get audioOutputs =>
      devicesOfKind(MediaDeviceKind.audioOutput);

  /// [audioOutputs], replaying the current list, then its changes.
  Stream<List<MediaDevice>> get audioOutputsChanges =>
      devicesOfKindChanges(MediaDeviceKind.audioOutput);

  static List<MediaDevice> _ofKind(
    List<MediaDevice> all,
    MediaDeviceKind kind,
  ) => List.unmodifiable(all.where((d) => d.kind == kind));

  /// How long one enumeration may take: 10 s. One that takes longer
  /// counts as failed, softly: the list is left unchanged and no error is
  /// reported, so [ready] and the captures that wait on it never hang on a
  /// platform that doesn't answer, and a capture without a list lets the
  /// platform pick the device (`docs/design.md` §4.5, Bounded capture). Its
  /// late result is dropped; the next enumeration (after a capture, or a
  /// device change) reads the devices again. A Mac's first enumeration in
  /// a process can take about 9 s (AVFoundation building its device list).
  static const enumerationTimeout = Duration(seconds: 10);

  /// Re-enumerates devices now (the first time: enumerates them).
  ///
  /// Concurrent calls share one enumeration, plus one more if a call arrived
  /// while it was running. Enumeration errors (and an enumeration that
  /// takes longer than [enumerationTimeout]) are logged and leave the list
  /// unchanged.
  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (!_started) return _ready;
    return _enumerator.run();
  }

  Future<void> _enumerate() async {
    if (_disposed) return;
    try {
      final devices = await _backend.enumerateDevices().timeout(
        enumerationTimeout,
      );
      if (_disposed) return;
      _devices.set(List.unmodifiable(devices));
    } catch (error) {
      debugPrint('cloudflare_realtime: enumerateDevices failed: $error');
    }
  }

  /// Stops watching for device changes and completes [devicesChanges].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _deviceChanges.cancel();
    await _devices.close();
  }
}

/// The package's own access to a [MediaDeviceList], which doesn't start
/// it: a source reads and watches the list without making it enumerate
/// (`docs/design.md` §4.5, Capture before listing on macOS).
///
/// Internal: not exported from the package barrel.
extension MediaDeviceListInternal on MediaDeviceList {
  /// Whether the list has been used, so it enumerates (or has).
  bool get isStarted => _started;

  /// The devices of [kind] now, without starting the list.
  List<MediaDevice> currentDevicesOfKind(MediaDeviceKind kind) =>
      MediaDeviceList._ofKind(_devices.value, kind);

  /// [currentDevicesOfKind], replaying the current list to each new
  /// listener, then each change, without starting the list.
  Stream<List<MediaDevice>> watchDevicesOfKind(MediaDeviceKind kind) =>
      MediaDeviceList._kindChanges(_devices.stream, kind);

  /// [MediaDeviceList.refresh] if the list has started; otherwise nothing.
  Future<void> refreshIfStarted() => _started ? refresh() : Future.value();
}
