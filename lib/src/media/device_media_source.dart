import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../diagnostics/log.dart';
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
/// - [devices] lists the devices of this kind, kept current
///   ([devicesChanges]).
/// - [setPreferredDevice] picks one. Capture tries the preferred device
///   first, then the rest in [devicePriority] order, until one produces a
///   track.
/// - **Fallback:** when the active device is unplugged (or its track ends),
///   the source captures from the next device and [trackChanges] emits the
///   new track.
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
/// [preferredDevice] and pass it back as `preferredDevice`.
///
/// **A capture can't hang forever:** a `getUserMedia` that doesn't answer
/// within [captureTimeout] fails the source with a [MediaCaptureException]
/// whose `cause` is a [TimeoutException], and a track it delivers later is
/// released (`docs/design.md` §4.5, Bounded capture).
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
    this.captureTimeout = defaultCaptureTimeout,
  }) : _backend = backend,
       _wantedOptions = options,
       _ownsDeviceList = deviceList == null,
       _deviceList = deviceList ?? MediaDeviceList(backend: backend),
       _preferred = StateStream(preferredDevice, distinct: true) {
    _activeDevice = StateStream(_computeActiveDevice(), distinct: true);
    _deviceSubscription = _deviceList
        .watchDevicesOfKind(deviceKind)
        .listen(_onDevicesChanged);
    // The list is read up front, as it always was, unless this source can
    // capture without it (a Mac's microphone).
    if (_unlistedDevice() == null) unawaited(_deviceList.ready);
  }

  /// The kind of device this source captures from.
  final MediaDeviceKind deviceKind;

  /// The default [captureTimeout]: 30 s.
  static const defaultCaptureTimeout = Duration(seconds: 30);

  /// How long one `getUserMedia` may take before the capture fails; null
  /// waits for as long as it takes.
  ///
  /// It normally answers in well under a second; this bounds a platform
  /// that never answers (`docs/design.md` §4.5, Bounded capture). The
  /// capture then fails with a [MediaCaptureException] (its `cause` a
  /// [TimeoutException]) without trying the other devices, the device is
  /// tried last next time, and a track that arrives later is stopped.
  ///
  /// A permission prompt the platform shows inside `getUserMedia` (the
  /// first capture on iOS, macOS and Android, and the browser's prompt)
  /// counts too: ask for the permission before capturing, or pass a longer
  /// timeout or null, if a prompt may stay open longer.
  final Duration? captureTimeout;

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

  /// The devices of [deviceKind], now. Reading it starts the device list's
  /// first enumeration, if nothing has ([MediaDeviceList]).
  List<MediaDevice> get devices => _deviceList.devicesOfKind(deviceKind);

  // The same, without starting the list.
  List<MediaDevice> get _listed => _deviceList.currentDevicesOfKind(deviceKind);

  /// [devices], replaying the current list to each new listener, then each
  /// change.
  Stream<List<MediaDevice>> get devicesChanges =>
      _deviceList.devicesOfKindChanges(deviceKind);

  /// [devices] in the order capture tries them. See
  /// [prioritizeDevices].
  List<MediaDevice> get devicePriority {
    unawaited(_deviceList.ready);
    return _priority();
  }

  List<MediaDevice> _priority() => prioritizeDevices(
    _listed,
    preferred: _preferred.value,
    deprioritized: _deprioritized,
    facing: preferredFacing,
  );

  /// The device to capture from without reading the device list first, or
  /// `null` when capture waits for the list.
  ///
  /// Only a Mac's microphone, with no device that failed, while nothing
  /// has used the list: the preferred device (selected by its ID), else the
  /// system default ([unlistedDefaultDevice]). The first device list in a
  /// process blocks a Mac's UI thread for 2–9 s (AVFoundation listing every
  /// capture device), and selecting a microphone by ID needs no list
  /// (`docs/design.md` §4.5, Capture before listing on macOS). If the
  /// capture fails (a preferred device that is gone), the list is read and
  /// the others are tried.
  MediaDevice? _unlistedDevice() {
    if (_deprioritized.isNotEmpty || _deviceList.isStarted) return null;
    final fallback = unlistedDefaultDevice(deviceKind, _backend.platform);
    if (fallback == null) return null;
    final preferred = _preferred.value;
    if (preferred == null) return fallback;
    return preferred.deviceId.isEmpty ? null : preferred;
  }

  /// Which way a camera should face, for [devicePriority]; `null` for
  /// sources that aren't cameras.
  @protected
  CameraFacing? get preferredFacing => null;

  /// The user's preferred device, or `null` for "no preference".
  MediaDevice? get preferredDevice => _preferred.value;

  /// [preferredDevice], replaying the current value to each new listener,
  /// then each change.
  Stream<MediaDevice?> get preferredDeviceChanges => _preferred.stream;

  /// The device in use while capturing; otherwise the device capture would
  /// try first. Use it to show the selection in a device picker.
  MediaDevice? get activeDevice => _activeDevice.value;

  /// [activeDevice], replaying the current value to each new listener, then
  /// each change.
  Stream<MediaDevice?> get activeDeviceChanges => _activeDevice.stream;

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
  /// again with the new options and [trackChanges] emits the new track.
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
    final captured = track?.device;
    if (captured != null) {
      // Captured before the list was read: the listed entry has the label.
      if (captured.label.isNotEmpty) return captured;
      for (final device in _listed) {
        if (device.sameDeviceAs(captured)) return device;
      }
      return captured;
    }
    final priority = _priority();
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
    // A Mac's microphone needs no list for the default or a chosen one:
    // don't start it.
    final unlisted = _unlistedDevice();
    if (unlisted == null) {
      await _deviceList.ready;
      if (!isEnabled) return; // The next run releases.
    }
    final current = track;
    if (current != null && _canKeep(current)) {
      _updateActiveDevice();
      return;
    }
    await _capture(current, unlisted: unlisted);
  }

  /// Whether the running capture [current] still matches what's wanted.
  bool _canKeep(CapturedTrack current) {
    if (_trackEnded || _capturedOptions != _wantedOptions) return false;
    final device = current.device;
    if (device == null) return true; // Unknown device: nothing to compare.
    final available = _usable(_listed);
    if (available.isEmpty) {
      // No usable list (web before permission): keep what works. A Mac's
      // microphone captured without the list moves to a newly preferred
      // device, still without it.
      final unlisted = _unlistedDevice();
      return unlisted == null ||
          _preferred.value == null ||
          unlisted.sameDeviceAs(device);
    }
    if (!available.any(device.sameDeviceAs)) return false; // Unplugged.
    final preferred = _preferred.value;
    return preferred == null ||
        preferred.sameDeviceAs(device) ||
        !available.any(preferred.sameDeviceAs) ||
        _deprioritized.any(preferred.sameDeviceAs);
  }

  static List<MediaDevice> _usable(List<MediaDevice> devices) =>
      devices.where((d) => d.deviceId.isNotEmpty).toList();

  /// Captures from the first device in priority order that works, or
  /// from [unlisted] without reading the list first; if [unlisted] fails,
  /// the list is read and the other devices are tried.
  Future<void> _capture(CapturedTrack? old, {MediaDevice? unlisted}) async {
    final oldEnded = _trackEnded;
    _trackEnded = false;
    List<MediaDevice?> listedCandidates() {
      final usable = _usable(_priority());
      // No device IDs yet (web before permission): let the platform choose.
      return usable.isEmpty ? <MediaDevice?>[null] : usable;
    }

    final candidates = unlisted != null
        ? <MediaDevice?>[unlisted]
        : listedCandidates();
    var listRead = unlisted == null;
    final failures = <(MediaDevice?, Object)>[];
    var oldReleased = old == null;

    Future<void> releaseOld() async {
      if (oldReleased) return;
      oldReleased = true;
      setTrack(null);
      _capturedOptions = null;
      await releaseStream(old!.stream);
    }

    for (var index = 0; ; index++) {
      if (index == candidates.length) {
        if (listRead) break;
        // The default failed without a list: read it, and try the others.
        listRead = true;
        await _deviceList.ready;
        candidates.addAll(
          listedCandidates().where(
            (d) => d != null && !candidates.any((c) => c!.sameDeviceAs(d)),
          ),
        );
        if (index == candidates.length) break;
      }
      final device = candidates[index];
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
        stream = await _getUserMedia(
          buildConstraints(_wantedOptions, device, _backend.platform),
        );
      } on _CaptureTimedOut catch (timedOut) {
        // A platform that doesn't answer won't answer for the next device
        // either: stop here. The device goes last for the next attempt.
        if (device != null && !_deprioritized.any(device.sameDeviceAs)) {
          _deprioritized.add(device);
        }
        if (!isEnabled || isDisposed) return;
        await releaseOld();
        fail(
          MediaCaptureException(
            'The ${deviceKind.wireName} capture did not start within '
            '${timedOut.timeout.inMilliseconds} ms.',
            cause: TimeoutException(
              'getUserMedia did not complete',
              timedOut.timeout,
            ),
          ),
        );
        return;
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
        // Labels and IDs appear once permission is granted. A list nothing
        // has used yet stays unread (a Mac's microphone, above).
        unawaited(_deviceList.refreshIfStarted());
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

  /// `getUserMedia` within [captureTimeout]. A stream that arrives after
  /// the timeout is released.
  Future<MediaStream> _getUserMedia(Map<String, dynamic> constraints) {
    final request = _backend.getUserMedia(constraints);
    final timeout = captureTimeout;
    if (timeout == null) return request;
    return request.timeout(
      timeout,
      onTimeout: () {
        RealtimeLog.warning(
          'getUserMedia (${deviceKind.wireName}) did '
          'not complete within ${timeout.inMilliseconds} ms',
        );
        unawaited(request.then(releaseStream, onError: (Object _) {}));
        throw _CaptureTimedOut(timeout);
      },
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
    final known = _listed;
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
      if (!identical(track?.track, captured.track)) return;
      // The device went away (web reports this; native platforms rely on
      // the device list instead). Capture again, from the next device if
      // this one is gone.
      _trackEnded = true;
      unawaited(_deviceList.refresh().then((_) => requestReconcile()));
    };
  }

  Future<void> _release() async {
    final current = track;
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
    super.captureTimeout,
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

  /// Which way the camera in use faces ([activeDevice]), when known.
  /// `null` on desktops, whose cameras don't say.
  CameraFacing? get facing => activeDevice?.facing;

  /// Switches to another camera, with one call on every platform.
  ///
  /// - On phones and tablets, it flips between the front and back cameras.
  /// - Elsewhere (desktops, or a camera that doesn't say which way it
  ///   faces), it moves to the next camera in [devices], in priority
  ///   order (virtual cameras last; see [devicePriority]), wrapping around.
  ///
  /// The choice becomes the [preferredDevice]. If the source is
  /// capturing, it captures from the new camera before releasing the old
  /// one, so [trackChanges] emits the new track with no gap, and a publication
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
      devices,
      current: activeDevice,
      deprioritized: _deprioritized,
    );
    if (next != null) {
      await setPreferredDevice(next);
    } else if (devices.isNotEmpty &&
        DeviceMediaSource._usable(devices).isEmpty) {
      await setOptions(
        options.copyWith(
          facing: options.facing == CameraFacing.environment
              ? CameraFacing.user
              : CameraFacing.environment,
        ),
      );
    }
    return activeDevice;
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
    super.captureTimeout,
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

/// A `getUserMedia` that didn't answer within [timeout].
class _CaptureTimedOut implements Exception {
  const _CaptureTimedOut(this.timeout);

  final Duration timeout;
}

/// The system default device of [kind] on [platform] that a source can
/// capture from without listing the devices first, or `null` where
/// capture reads the list first.
///
/// macOS microphones only: libwebrtc's audio device module lists the
/// system default first, as `default`, and selecting it
/// (`Helper.selectAudioInput`) needs no device list from Dart. Elsewhere
/// the list is needed: Windows opens the first device it lists unless
/// told which (`docs/design.md` §4.5), browsers give labels only through
/// the list, and phones pick cameras by facing. A Mac's camera lists the
/// cameras inside `getUserMedia` anyway.
@visibleForTesting
MediaDevice? unlistedDefaultDevice(
  MediaDeviceKind kind,
  MediaPlatform platform,
) => platform == MediaPlatform.macos && kind == MediaDeviceKind.audioInput
    ? const MediaDevice(
        deviceId: 'default',
        kind: MediaDeviceKind.audioInput,
        label: '',
        isDefault: true,
      )
    : null;
