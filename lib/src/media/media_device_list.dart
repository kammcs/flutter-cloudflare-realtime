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
class MediaDeviceList {
  /// Creates the list and starts enumerating devices through [backend].
  MediaDeviceList({MediaBackend backend = const FlutterWebrtcMediaBackend()})
    : _backend = backend {
    _deviceChanges = backend.deviceChanges.listen((_) => refresh());
    _ready = refresh();
  }

  final MediaBackend _backend;
  final StateStream<List<MediaDevice>> _devices = StateStream(
    const [],
    equals: _listEquality.equals,
  );
  late final StreamSubscription<void> _deviceChanges;
  late final Future<void> _ready;
  late final CoalescingRunner _enumerator = CoalescingRunner(_enumerate);
  bool _disposed = false;

  /// Completes when the first enumeration has finished (successfully or
  /// not).
  Future<void> get ready => _ready;

  /// Every device, in the order the platform lists them. Replays the current
  /// list to new listeners.
  Stream<List<MediaDevice>> get devices => _devices.stream;

  /// The current device list. Empty until the first enumeration finishes.
  List<MediaDevice> get currentDevices => _devices.value;

  /// Devices of one [kind]: replays the current list, then emits when it
  /// changes.
  Stream<List<MediaDevice>> devicesOfKind(MediaDeviceKind kind) {
    List<MediaDevice>? previous;
    return devices.map((all) => _ofKind(all, kind)).where((list) {
      if (previous != null && _listEquality.equals(previous, list)) {
        return false;
      }
      previous = list;
      return true;
    });
  }

  /// The current devices of one [kind].
  List<MediaDevice> currentDevicesOfKind(MediaDeviceKind kind) =>
      _ofKind(currentDevices, kind);

  /// Microphones. See [devicesOfKind].
  Stream<List<MediaDevice>> get audioInputs =>
      devicesOfKind(MediaDeviceKind.audioInput);

  /// Cameras. See [devicesOfKind].
  Stream<List<MediaDevice>> get videoInputs =>
      devicesOfKind(MediaDeviceKind.videoInput);

  /// Speakers and headsets. See [devicesOfKind].
  Stream<List<MediaDevice>> get audioOutputs =>
      devicesOfKind(MediaDeviceKind.audioOutput);

  static List<MediaDevice> _ofKind(
    List<MediaDevice> all,
    MediaDeviceKind kind,
  ) => List.unmodifiable(all.where((d) => d.kind == kind));

  /// Re-enumerates devices now.
  ///
  /// Concurrent calls share one enumeration, plus one more if a call arrived
  /// while it was running. Enumeration errors are logged and leave the list
  /// unchanged.
  Future<void> refresh() => _disposed ? Future.value() : _enumerator.run();

  Future<void> _enumerate() async {
    if (_disposed) return;
    try {
      final devices = await _backend.enumerateDevices();
      if (_disposed) return;
      _devices.set(List.unmodifiable(devices));
    } catch (error) {
      debugPrint('cloudflare_realtime: enumerateDevices failed: $error');
    }
  }

  /// Stops watching for device changes and completes [devices].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _deviceChanges.cancel();
    await _devices.close();
  }
}
