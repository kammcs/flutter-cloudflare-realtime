import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signaling/participant_state.dart';
import '../util/state_stream.dart';
import 'constraints.dart';
import 'device_priority.dart';
import 'flutter_webrtc_media_backend.dart';
import 'local_media_source.dart';
import 'media_backend.dart';
import 'media_device_list.dart';
import 'media_errors.dart';
import 'media_types.dart';
import 'release.dart';

/// A [LocalMediaSource] that captures from a camera or microphone, with
/// device selection and automatic fallback.
///
/// Ported from partytracks' `getDevice`/`resilientTrack$`/`deviceManager`:
///
/// - [devices] lists the devices of this kind, kept current.
/// - [setPreferredDevice] picks one. Capture tries the preferred device
///   first, then the rest in [devicePriority] order, until one produces a
///   track.
/// - **Fallback:** when the active device is unplugged (or its track ends),
///   the source captures from the next device and [track] emits the new
///   track.
/// - **Return:** when the preferred device comes back, the source switches
///   back to it.
/// - A device that fails is tried last until it is unplugged or chosen
///   again. If every device fails, [errors] gets a
///   [DevicesExhaustedException] and the source turns off. A permission
///   error stops the search at once ([MediaPermissionDeniedException]).
///
/// Unlike partytracks, unrelated device-list changes don't restart capture:
/// the source only captures again when its device went away, the preferred
/// device became available, the options changed, or the track ended.
///
/// Remembering the preference across app runs is up to the app: persist
/// [currentPreferredDevice] and pass it back as `preferredDevice`.
abstract class DeviceMediaSource<O extends Object> extends LocalMediaSource {
  /// Initializes device handling. For subclasses.
  DeviceMediaSource({
    required super.kind,
    required super.source,
    required super.mutePolicy,
    required this.deviceKind,
    required O options,
    required MediaBackend backend,
    MediaDeviceList? deviceList,
    MediaDevice? preferredDevice,
  }) : _backend = backend,
       _wantedOptions = options,
       _ownsDeviceList = deviceList == null,
       _deviceList = deviceList ?? MediaDeviceList(backend: backend),
       _preferred = StateStream(preferredDevice, distinct: true) {
    _activeDevice = StateStream(_computeActiveDevice(), distinct: true);
    _deviceSubscription = _deviceList
        .devicesOfKind(deviceKind)
        .listen(_onDevicesChanged);
  }

  /// The kind of device this source captures from.
  final MediaDeviceKind deviceKind;

  final MediaBackend _backend;
  final MediaDeviceList _deviceList;
  final bool _ownsDeviceList;
  final StateStream<MediaDevice?> _preferred;
  late final StateStream<MediaDevice?> _activeDevice;
  late final StreamSubscription<List<MediaDevice>> _deviceSubscription;
  final List<MediaDevice> _deprioritized = [];
  O _wantedOptions;
  O? _capturedOptions;
  bool _trackEnded = false;

  /// The shared device list this source reads from.
  MediaDeviceList get deviceList => _deviceList;

  /// Devices of [deviceKind]. Replays the current list.
  Stream<List<MediaDevice>> get devices =>
      _deviceList.devicesOfKind(deviceKind);

  /// The current devices of [deviceKind].
  List<MediaDevice> get currentDevices =>
      _deviceList.currentDevicesOfKind(deviceKind);

  /// [currentDevices] in the order capture tries them. See
  /// [prioritizeDevices].
  List<MediaDevice> get devicePriority => prioritizeDevices(
    currentDevices,
    preferred: _preferred.value,
    deprioritized: _deprioritized,
    facing: preferredFacing,
  );

  /// Which way a camera should face, for [devicePriority]; `null` for
  /// sources that aren't cameras.
  @protected
  CameraFacing? get preferredFacing => null;

  /// The user's preferred device, or `null` for "no preference". Replays the
  /// current value.
  Stream<MediaDevice?> get preferredDevice => _preferred.stream;

  /// The user's preferred device, or `null`.
  MediaDevice? get currentPreferredDevice => _preferred.value;

  /// The device in use while capturing; otherwise the device capture would
  /// try first. Use it to show the selection in a device picker. Replays the
  /// current value.
  Stream<MediaDevice?> get activeDevice => _activeDevice.stream;

  /// The device in use, or the one capture would try first.
  MediaDevice? get currentActiveDevice => _activeDevice.value;

  /// The capture options.
  O get options => _wantedOptions;

  /// Sets the preferred device (or clears it with `null`), and switches
  /// capture to it if the source is enabled.
  ///
  /// Completes when the switch has finished.
  Future<void> setPreferredDevice(MediaDevice? device) async {
    _checkNotDisposed();
    if (device != null) _deprioritized.removeWhere(device.sameDeviceAs);
    _preferred.set(device);
    _updateActiveDevice();
    await requestReconcile();
  }

  /// Changes the capture options. If the source is capturing, it captures
  /// again with the new options and [track] emits the new track.
  ///
  /// Completes when the new capture has started (or failed).
  Future<void> setOptions(O options) async {
    _checkNotDisposed();
    _wantedOptions = options;
    await requestReconcile();
  }

  /// The `getUserMedia` constraints for [options] on [device]; `null`
  /// [device] means "any device".
  @protected
  Map<String, dynamic> buildConstraints(
    O options,
    MediaDevice? device,
    MediaPlatform platform,
  );

  void _checkNotDisposed() {
    if (isDisposed) throw StateError('This $runtimeType has been disposed.');
  }

  void _onDevicesChanged(List<MediaDevice> devices) {
    // A device that was unplugged gets a fresh chance when it comes back.
    _deprioritized.removeWhere((gone) => !devices.any(gone.sameDeviceAs));
    _updateActiveDevice();
    if (isEnabled) requestReconcile();
  }

  MediaDevice? _computeActiveDevice() {
    final captured = currentTrack?.device;
    if (captured != null) return captured;
    final priority = devicePriority;
    return priority.isEmpty ? null : priority.first;
  }

  void _updateActiveDevice() {
    if (_activeDevice.isClosed) return;
    _activeDevice.set(_computeActiveDevice());
  }

  @override
  void didChangeState() => _updateActiveDevice();

  @override
  Future<void> reconcile() async {
    if (!isEnabled) {
      await _release();
      return;
    }
    await _deviceList.ready;
    if (!isEnabled) return; // The next run releases.
    final current = currentTrack;
    if (current != null && _canKeep(current)) {
      _updateActiveDevice();
      return;
    }
    await _capture(current);
  }

  /// Whether the running capture [current] still matches what's wanted.
  bool _canKeep(CapturedTrack current) {
    if (_trackEnded || _capturedOptions != _wantedOptions) return false;
    final device = current.device;
    if (device == null) return true; // Unknown device: nothing to compare.
    final available = _usable(currentDevices);
    // No usable list (web before permission): keep what works.
    if (available.isEmpty) return true;
    if (!available.any(device.sameDeviceAs)) return false; // Unplugged.
    final preferred = _preferred.value;
    return preferred == null ||
        preferred.sameDeviceAs(device) ||
        !available.any(preferred.sameDeviceAs) ||
        _deprioritized.any(preferred.sameDeviceAs);
  }

  static List<MediaDevice> _usable(List<MediaDevice> devices) =>
      devices.where((d) => d.deviceId.isNotEmpty).toList();

  Future<void> _capture(CapturedTrack? old) async {
    final oldEnded = _trackEnded;
    _trackEnded = false;
    final usable = _usable(devicePriority);
    // No device IDs yet (web before permission): let the platform choose.
    final candidates = usable.isEmpty ? <MediaDevice?>[null] : usable;
    final failures = <(MediaDevice?, Object)>[];
    var oldReleased = old == null;

    Future<void> releaseOld() async {
      if (oldReleased) return;
      oldReleased = true;
      setTrack(null);
      _capturedOptions = null;
      await releaseStream(old!.stream);
    }

    for (final device in candidates) {
      if (!isEnabled) return; // Disabled meanwhile: the next run releases.
      final sameAsOld =
          old != null &&
          (device == null ||
              old.device == null ||
              old.device!.sameDeviceAs(device));
      if (sameAsOld && !oldReleased) {
        // Reached the device already in use: keep it if nothing is wrong
        // with it, else free it (cameras can't be opened twice).
        if (!oldEnded && _capturedOptions == _wantedOptions) {
          _updateActiveDevice();
          return;
        }
        await releaseOld();
      }
      final MediaStream stream;
      try {
        stream = await _backend.getUserMedia(
          buildConstraints(_wantedOptions, device, _backend.platform),
        );
      } catch (error) {
        if (isPermissionError(error)) {
          await releaseOld();
          fail(
            MediaPermissionDeniedException(
              'Access to the ${deviceKind.wireName} device was denied.',
              cause: error,
            ),
          );
          return;
        }
        failures.add((device, error));
        if (device != null && !_deprioritized.any(device.sameDeviceAs)) {
          _deprioritized.add(device);
        }
        continue;
      }
      final tracks = kind == TrackKind.audio
          ? stream.getAudioTracks()
          : stream.getVideoTracks();
      if (tracks.isEmpty) {
        await releaseStream(stream);
        failures.add((device, 'getUserMedia returned no ${kind.name} track'));
        continue;
      }
      if (!isEnabled || isDisposed) {
        await releaseStream(stream);
        return;
      }
      final captured = CapturedTrack(
        track: tracks.first,
        stream: stream,
        device: _resolveDevice(tracks.first, device),
      );
      _capturedOptions = _wantedOptions;
      _watchEnded(captured);
      setTrack(captured);
      if (!oldReleased) {
        oldReleased = true;
        await releaseStream(old!.stream);
      }
      if (device == null || captured.device?.label.isEmpty != false) {
        // Labels and IDs appear once permission is granted.
        unawaited(_deviceList.refresh());
      }
      return;
    }

    await releaseOld();
    fail(
      DevicesExhaustedException(
        candidates.length == 1 && candidates.single == null
            ? 'No ${deviceKind.wireName} device produced a track.'
            : 'None of ${candidates.length} ${deviceKind.wireName} devices '
                  'produced a track.',
        failures: List.unmodifiable(failures),
        cause: failures.isEmpty ? null : failures.last.$2,
      ),
    );
  }

  /// Works out which device [track] really captures from.
  ///
  /// Native Windows silently opens the first camera when the requested one
  /// is missing, and an unconstrained request lets the platform choose, so
  /// the track's `deviceId` setting wins over what was requested.
  MediaDevice? _resolveDevice(MediaStreamTrack track, MediaDevice? requested) {
    String? settingsId;
    try {
      final id = track.getSettings()['deviceId'];
      if (id is String && id.isNotEmpty) settingsId = id;
    } catch (_) {
      // Not implemented on this platform.
    }
    final known = currentDevices;
    if (settingsId != null) {
      for (final device in known) {
        if (device.deviceId == settingsId) return device;
      }
      if (requested != null && requested.deviceId == settingsId) {
        return requested;
      }
    }
    if (requested != null) return requested;
    final label = track.label;
    if (label != null && label.isNotEmpty) {
      for (final device in known) {
        if (device.label == label) return device;
      }
    }
    return settingsId == null
        ? null
        : MediaDevice(deviceId: settingsId, kind: deviceKind, label: '');
  }

  void _watchEnded(CapturedTrack captured) {
    captured.track.onEnded = () {
      if (!identical(currentTrack?.track, captured.track)) return;
      // The device went away (web reports this; native platforms rely on
      // the device list instead). Capture again, from the next device if
      // this one is gone.
      _trackEnded = true;
      unawaited(_deviceList.refresh().then((_) => requestReconcile()));
    };
  }

  Future<void> _release() async {
    final current = currentTrack;
    _trackEnded = false;
    if (current == null) return;
    setTrack(null);
    _capturedOptions = null;
    await releaseStream(current.stream);
  }

  @override
  Future<void> onDispose() async {
    await _deviceSubscription.cancel();
    await _preferred.close();
    await _activeDevice.close();
    if (_ownsDeviceList) await _deviceList.dispose();
  }
}

/// A camera, with resolution/frame-rate presets.
///
/// ```dart
/// final camera = CameraSource(options: CameraOptions(preset: VideoPreset.h720));
/// camera.track.listen((t) => renderer.srcObject = t?.stream);
/// await camera.enable(); // preview
/// await camera.startBroadcasting(); // send (roadmap M2)
/// await camera.switchCamera(); // front/back on phones, next camera elsewhere
/// ```
///
/// It behaves the same on every platform: it opens the front camera by
/// default ([CameraOptions.facing]), at the preset's resolution, and
/// [switchCamera] moves to another camera.
///
/// Defaults to [MutePolicy.releaseCapture]: muting turns the camera light
/// off.
class CameraSource extends DeviceMediaSource<CameraOptions> {
  /// Creates a camera source. It captures nothing until [enable] or
  /// [startBroadcasting].
  ///
  /// Pass a shared [deviceList] to avoid enumerating devices once per
  /// source.
  CameraSource({
    super.backend = const FlutterWebrtcMediaBackend(),
    super.deviceList,
    super.options = const CameraOptions(),
    super.preferredDevice,
    super.mutePolicy = MutePolicy.releaseCapture,
  }) : super(
         kind: TrackKind.video,
         source: TrackSource.camera,
         deviceKind: MediaDeviceKind.videoInput,
       );

  @override
  Map<String, dynamic> buildConstraints(
    CameraOptions options,
    MediaDevice? device,
    MediaPlatform platform,
  ) => cameraConstraints(options, platform: platform, device: device);

  @override
  CameraFacing? get preferredFacing => options.facing;

  /// Which way the camera in use faces ([currentActiveDevice]), when known.
  /// `null` on desktops, whose cameras don't say.
  CameraFacing? get currentFacing => currentActiveDevice?.facing;

  /// Switches to another camera, with one call on every platform.
  ///
  /// - On phones and tablets, it flips between the front and back cameras.
  /// - Elsewhere (desktops, or a camera that doesn't say which way it
  ///   faces), it moves to the next camera in [currentDevices], in priority
  ///   order (virtual cameras last; see [devicePriority]), wrapping around.
  ///
  /// The choice becomes the [currentPreferredDevice]. If the source is
  /// capturing, it captures from the new camera before releasing the old
  /// one, so [track] emits the new track with no gap, and a publication
  /// keeps sending. With a single camera it does nothing.
  ///
  /// In browsers before the user grants camera access, devices have no IDs
  /// yet; it then flips [CameraOptions.facing] instead.
  ///
  /// Completes with the camera now in use (or the one capture will use),
  /// or `null` when there is none.
  Future<MediaDevice?> switchCamera() async {
    _checkNotDisposed();
    await deviceList.ready;
    final next = nextCamera(
      currentDevices,
      current: currentActiveDevice,
      deprioritized: _deprioritized,
    );
    if (next != null) {
      await setPreferredDevice(next);
    } else if (currentDevices.isNotEmpty &&
        DeviceMediaSource._usable(currentDevices).isEmpty) {
      await setOptions(
        options.copyWith(
          facing: options.facing == CameraFacing.environment
              ? CameraFacing.user
              : CameraFacing.environment,
        ),
      );
    }
    return currentActiveDevice;
  }
}

/// A microphone, with echo cancellation, noise suppression and automatic
/// gain control.
///
/// Defaults to [MutePolicy.keepCapture]: muting keeps the microphone open,
/// so unmuting is instant and "talking while muted" hints are possible.
/// Pass [MutePolicy.releaseCapture] to close it on mute instead.
class MicrophoneSource extends DeviceMediaSource<MicrophoneOptions> {
  /// Creates a microphone source. It captures nothing until [enable] or
  /// [startBroadcasting].
  MicrophoneSource({
    super.backend = const FlutterWebrtcMediaBackend(),
    super.deviceList,
    super.options = const MicrophoneOptions(),
    super.preferredDevice,
    super.mutePolicy = MutePolicy.keepCapture,
  }) : super(
         kind: TrackKind.audio,
         source: TrackSource.microphone,
         deviceKind: MediaDeviceKind.audioInput,
       );

  @override
  Map<String, dynamic> buildConstraints(
    MicrophoneOptions options,
    MediaDevice? device,
    MediaPlatform platform,
  ) => microphoneConstraints(options, platform: platform, device: device);
}
