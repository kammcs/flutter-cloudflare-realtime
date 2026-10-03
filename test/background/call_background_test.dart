import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/call_audio_backend.dart';
import 'package:cloudflare_realtime/src/background/call_background.dart';
import 'package:cloudflare_realtime/src/background/call_background_backend.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../support/room_harness.dart';

/// Android's foreground service and iOS's camera pauses, recorded.
class _FakeBackground implements CallBackgroundBackend {
  _FakeBackground({this.android = true, this.ios = false});

  final bool android;
  final bool ios;

  /// What the service runs with: `mic`, `mic+cam`, `cam`, or `stopped`.
  String state = 'stopped';

  /// Every start and stop, in order.
  final List<String> calls = [];

  /// Makes the next starts throw, like Android refusing a start from the
  /// background.
  Object? startError;

  final StreamController<CameraPauseSignal> _pauses =
      StreamController.broadcast();

  void pause(CameraPauseReason? reason) =>
      _pauses.add(CameraPauseSignal(reason));

  @override
  bool get runsForegroundService => android;

  @override
  bool get reportsCameraPause => ios;

  @override
  Future<bool> startService({
    required bool microphone,
    required bool camera,
  }) async {
    final types = [if (microphone) 'mic', if (camera) 'cam'].join('+');
    calls.add('start $types');
    if (startError case final error?) throw error;
    state = types;
    return true;
  }

  @override
  Future<void> stopService() async {
    calls.add('stop');
    state = 'stopped';
  }

  @override
  Stream<CameraPauseSignal> get cameraPauses => _pauses.stream;
}

class _FakeLifecycle implements AppLifecycleSource {
  final StreamController<AppLifecycleState> _states =
      StreamController.broadcast(sync: true);

  void emit(AppLifecycleState state) => _states.add(state);

  @override
  Stream<AppLifecycleState> get states => _states.stream;
}

Future<void> _settle() => pumpEventQueue(times: 50);

void main() {
  late _FakeBackground backend;
  late _FakeLifecycle lifecycle;
  late RoomHarness h;

  void use(_FakeBackground fake) {
    backend = fake;
    CallBackground.debugReset();
  }

  setUp(() {
    lifecycle = _FakeLifecycle();
    debugCallLifecycleSource = lifecycle;
    debugCallBackgroundBackendFactory = () => backend;
    use(_FakeBackground());
    h = RoomHarness();
  });

  tearDown(() {
    CallBackground.debugReset();
    debugCallBackgroundBackendFactory = null;
    debugCallLifecycleSource = null;
  });

  group('Android: the foreground service', () {
    test('starts with the microphone, adds the camera while it captures, '
        'and stops when nothing is published', () async {
      final alice = await h.join('alice');
      await _settle();
      expect(backend.calls, isEmpty, reason: 'nothing published');

      final mic = await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(backend.state, 'mic');
      expect(CallBackground.instance.serviceRunning.value, isTrue);

      final camera = await alice.localParticipant.publishCamera();
      await _settle();
      expect(backend.state, 'mic+cam');

      await camera.mute();
      await _settle();
      expect(backend.state, 'mic', reason: 'a muted camera releases capture');
      await camera.unmute();
      await _settle();
      expect(backend.state, 'mic+cam');

      await mic.unpublish();
      await _settle();
      expect(backend.state, 'cam');
      await camera.unpublish();
      await _settle();
      expect(backend.state, 'stopped');
      expect(CallBackground.instance.serviceRunning.value, isFalse);

      await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(backend.state, 'mic');
      await alice.leave();
      expect(backend.state, 'stopped');
      expect(backend.calls, [
        'start mic',
        'start mic+cam',
        'start mic',
        'start mic+cam',
        'start cam',
        'stop',
        'start mic',
        'stop',
      ]);
    });

    test('a screen share alone has its own service', () async {
      const screen = ScreenSource(
        id: 'screen-1',
        name: 'Screen 1',
        type: ScreenSourceType.screen,
      );
      h = RoomHarness(
        media: FakeMediaBackend(
          devices: [cam1, mic1],
          desktop: FakeDesktopCapturer([screen]),
        ),
      );
      final alice = await h.join(
        'alice',
        options: const RoomOptions(screenShareStallTimeout: null),
      );
      await alice.localParticipant.publishScreen(source: screen);
      await _settle();
      expect(backend.calls, isEmpty);
      await alice.leave();
    });

    test('rooms share one service; the last one out stops it', () async {
      final alice = await h.join('alice');
      final bob = await h.join('bob');
      await alice.localParticipant.publishMicrophone();
      await bob.localParticipant.publishCamera();
      await _settle();
      expect(backend.state, 'mic+cam');
      await alice.leave();
      await _settle();
      expect(backend.state, 'cam');
      await bob.leave();
      expect(backend.state, 'stopped');
    });

    test('RoomOptions.foregroundService false: no service', () async {
      final alice = await h.join(
        'alice',
        options: const RoomOptions(foregroundService: false),
      );
      await alice.localParticipant.publishMicrophone();
      await alice.localParticipant.publishCamera();
      await _settle();
      expect(backend.calls, isEmpty);
      await alice.leave();
      expect(backend.calls, isEmpty);
    });

    test('a refused start is reported and retried in the foreground', () async {
      final alice = await h.join('alice');
      final errors = <RoomErrorEvent>[];
      alice.events.listen((e) {
        if (e is RoomErrorEvent) errors.add(e);
      });
      backend.startError = StateError('not allowed in the background');
      await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(backend.state, 'stopped');
      expect(errors.single.operation, 'foregroundService');

      backend.startError = null;
      lifecycle.emit(AppLifecycleState.resumed);
      await _settle();
      expect(backend.state, 'mic');
      await alice.leave();
    });
  });

  group('iOS: the camera paused by the system', () {
    setUp(() => use(_FakeBackground(android: false, ios: true)));

    test('reported while a camera is published, and when it runs '
        'again', () async {
      final alice = await h.join('alice');
      final events = <RoomEvent>[];
      alice.events.listen(events.add);
      expect(alice.canDetectCameraPause, isTrue);

      // No camera published: the state changes, no event.
      backend.pause(CameraPauseReason.background);
      await _settle();
      expect(alice.cameraPause, CameraPauseReason.background);
      backend.pause(null);
      await _settle();
      expect(events.whereType<RoomCameraPausedEvent>(), isEmpty);
      expect(events.whereType<RoomCameraResumedEvent>(), isEmpty);

      await alice.localParticipant.publishCamera();
      backend.pause(CameraPauseReason.background);
      await _settle();
      expect(
        events.whereType<RoomCameraPausedEvent>().single.reason,
        CameraPauseReason.background,
      );
      backend.pause(null);
      await _settle();
      expect(events.whereType<RoomCameraResumedEvent>(), hasLength(1));
      expect(alice.cameraPause, isNull);
      expect(backend.calls, isEmpty, reason: 'no service on iOS');
      await alice.leave();
    });

    test('cleared when the last room leaves', () async {
      final alice = await h.join('alice');
      backend.pause(CameraPauseReason.systemPressure);
      await _settle();
      expect(alice.cameraPause, CameraPauseReason.systemPressure);
      await alice.leave();
      expect(CallBackground.instance.cameraPause.value, isNull);
    });

    test('the native event maps', () {
      expect(
        cameraPauseFromMap({'event': 'cameraPaused', 'reason': 'background'}),
        const CameraPauseSignal(CameraPauseReason.background),
      );
      expect(
        cameraPauseFromMap({'event': 'cameraPaused', 'reason': 'new'}),
        const CameraPauseSignal(CameraPauseReason.other),
      );
      expect(
        cameraPauseFromMap({'event': 'cameraResumed'}),
        const CameraPauseSignal(null),
      );
      expect(cameraPauseFromMap({'event': 'x'}), isNull);
    });
  });

  test('desktops and browsers: nothing to run or report', () async {
    use(_FakeBackground(android: false));
    debugCallBackgroundBackendFactory = () =>
        const UnsupportedCallBackgroundBackend();
    CallBackground.debugReset();
    final alice = await h.join('alice');
    await alice.localParticipant.publishMicrophone();
    expect(alice.canDetectCameraPause, isFalse);
    expect(alice.cameraPause, isNull);
    await alice.leave();
  });
}
