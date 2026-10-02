import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../audio/call_audio_backend.dart' show callLifecycleSource;
import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'call_background_backend.dart';
import 'camera_pause.dart';

/// Keeps calls alive outside the foreground, for the whole app
/// (`docs/design.md` §4.7).
///
/// - **Android:** runs this package's foreground service while any joined
///   room publishes a microphone or a capturing camera, with the type
///   `microphone`, plus `camera` while a camera captures. Android 14+ lets
///   a backgrounded app keep its microphone and camera only under such a
///   service, and only one started while the app was in the foreground; so
///   it starts on the first publish, its types follow the camera, and it
///   stops when nothing is published or the last room leaves. A start that
///   fails (the app was in the background) is retried when the app returns
///   to the foreground, and reported on [errors].
/// - **iOS:** nothing to start (calls keep their audio with the app's
///   `UIBackgroundModes: audio`), but the system pauses the camera in the
///   background: [cameraPause] reports it.
///
/// Rooms register while joined, like `CallAudio`. A room joined with
/// `RoomOptions.foregroundService: false` doesn't count for the service.
///
/// Internal: the Room exposes it.
class CallBackground {
  CallBackground._(this._backend);

  static CallBackground? _instance;

  /// The app's instance.
  static CallBackground get instance =>
      _instance ??= CallBackground._(createCallBackgroundBackend());

  /// **Tests only:** forgets the instance (and its backend), so the next
  /// one is created afresh from [debugCallBackgroundBackendFactory].
  @visibleForTesting
  static void debugReset() {
    _instance?._dispose();
    _instance = null;
  }

  final CallBackgroundBackend _backend;
  late final CoalescingRunner _runner = CoalescingRunner(_apply);

  // Every joined room; what each one that counts for the service publishes.
  final Set<Object> _rooms = {};
  final Map<Object, ({bool microphone, bool camera})> _publishing = {};
  final Set<Object> _withService = {};
  ({bool microphone, bool camera})? _running;
  StreamSubscription<CameraPauseSignal>? _cameraPauses;
  StreamSubscription<AppLifecycleState>? _lifecycle;
  final StreamController<Object> _errors = StreamController.broadcast();
  // A failure is reported once, until the service runs as wanted again.
  bool _failing = false;

  /// Whether this platform needs a foreground service for a call (Android).
  bool get runsForegroundService => _backend.runsForegroundService;

  /// Whether this platform reports a camera paused by the system (iOS).
  bool get reportsCameraPause => _backend.reportsCameraPause;

  /// Whether the foreground service runs now (Android).
  final StateStream<bool> serviceRunning = StateStream(false, distinct: true);

  /// Why the system paused the camera, or `null` while it runs (iOS).
  final StateStream<CameraPauseReason?> cameraPause = StateStream(
    null,
    distinct: true,
  );

  /// Failures to start or change the foreground service; a failure that
  /// repeats is reported once.
  Stream<Object> get errors => _errors.stream;

  /// Registers [room], which has joined. With [foregroundService] `false`
  /// it never counts for the foreground service.
  void join(Object room, {required bool foregroundService}) {
    if (!_rooms.add(room)) return;
    if (foregroundService) _withService.add(room);
    if (_rooms.length == 1) {
      if (reportsCameraPause) {
        _cameraPauses = _backend.cameraPauses.listen(
          (signal) => cameraPause.set(signal.reason),
          onError: (Object _) {},
        );
      }
      if (runsForegroundService) {
        _lifecycle = callLifecycleSource().states.listen(
          _onLifecycle,
          onError: (Object _) {},
        );
      }
    }
  }

  /// [room] publishes a microphone ([microphone]) and a capturing camera
  /// ([camera]), or not.
  void publishing(
    Object room, {
    required bool microphone,
    required bool camera,
  }) {
    if (!_rooms.contains(room) || !_withService.contains(room)) return;
    _publishing[room] = (microphone: microphone, camera: camera);
    if (runsForegroundService) unawaited(_runner.run());
  }

  /// Unregisters [room]. The last one out stops the service.
  Future<void> leave(Object room) async {
    if (!_rooms.remove(room)) return;
    _withService.remove(room);
    _publishing.remove(room);
    if (_rooms.isEmpty) {
      await _cameraPauses?.cancel();
      _cameraPauses = null;
      await _lifecycle?.cancel();
      _lifecycle = null;
      cameraPause.set(null);
    }
    if (runsForegroundService) await _runner.run();
  }

  /// What the service should run with now, or `null` for no service.
  ({bool microphone, bool camera})? get _wanted {
    final microphone = _publishing.values.any((p) => p.microphone);
    final camera = _publishing.values.any((p) => p.camera);
    return microphone || camera
        ? (microphone: microphone, camera: camera)
        : null;
  }

  // A start refused in the background is retried in the foreground.
  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _wanted != _running) {
      unawaited(_runner.run());
    }
  }

  Future<void> _apply() async {
    final wanted = _wanted;
    if (wanted == _running) return;
    try {
      if (wanted == null) {
        _running = null;
        serviceRunning.set(false);
        await _backend.stopService();
      } else {
        final running = await _backend.startService(
          microphone: wanted.microphone,
          camera: wanted.camera,
        );
        _running = running ? wanted : null;
        serviceRunning.set(running);
      }
      _failing = false;
    } catch (error) {
      debugPrint('cloudflare_realtime: foreground service failed: $error');
      if (!_failing && !_errors.isClosed) _errors.add(error);
      _failing = true;
    }
  }

  void _dispose() {
    unawaited(_cameraPauses?.cancel());
    unawaited(_lifecycle?.cancel());
    unawaited(_errors.close());
    unawaited(serviceRunning.close());
    unawaited(cameraPause.close());
  }
}
