import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/call_audio.dart';
import 'package:cloudflare_realtime/src/audio/call_audio_backend.dart';
import 'package:cloudflare_realtime/src/screen_awake/screen_awake.dart';
import 'package:cloudflare_realtime/src/screen_awake/screen_awake_backend.dart';
import 'package:cloudflare_realtime/src/util/state_stream.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

import '../support/room_harness.dart';

/// The platform's screen switch, recorded.
class _FakeScreen implements ScreenAwakeBackend {
  @override
  bool get supported => true;

  /// Whether the screen is kept on.
  bool on = false;

  /// Every request, in order: `on` or `off`.
  final List<String> calls = [];

  /// Makes the next requests throw.
  Object? error;

  final StreamController<bool> _changes = StreamController.broadcast();

  /// The platform releases the hold by itself, or takes it again (the web).
  void platformChange(bool held) {
    on = held;
    _changes.add(held);
  }

  @override
  Future<bool> setKeepAwake(bool on) async {
    calls.add(on ? 'on' : 'off');
    if (error case final error?) throw error;
    this.on = on;
    return this.on;
  }

  @override
  Stream<bool> get changes => _changes.stream;
}

/// A phone for call audio: the speaker and the earpiece, a proximity
/// sensor. Only what the proximity rule needs.
class _FakePhone implements CallAudioBackend {
  static const speaker = AudioRoute(id: 'spk', kind: AudioRouteKind.speaker);
  static const earpiece = AudioRoute(id: 'ear', kind: AudioRouteKind.earpiece);

  AudioRoute? currentNow;
  bool proximityOn = false;

  @override
  bool get supported => true;

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> setDefaultToSpeaker(bool speaker) async {}

  @override
  Future<List<AudioRoute>> routes() async => const [speaker, earpiece];

  @override
  Future<AudioRoute?> current() async => currentNow;

  @override
  Future<bool> select(AudioRoute route) async {
    currentNow = route;
    return true;
  }

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<bool> setProximityMonitoring(bool enabled) async =>
      proximityOn = enabled;

  @override
  Future<bool> resume() async => true;

  @override
  Stream<AudioInterruptionSignal> get interruptions => const Stream.empty();
}

const _failed = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
const _disconnected = RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;

Future<void> _settle() => pumpEventQueue(times: 50);

void main() {
  group('ScreenAwake (the app-wide policy)', () {
    late _FakeScreen screen;
    late StateStream<bool> proximity;
    late ScreenAwake awake;
    final roomA = Object();
    final roomB = Object();

    setUp(() {
      screen = _FakeScreen();
      proximity = StateStream(false, distinct: true);
      awake = ScreenAwake(screen, proximity: () => proximity);
    });

    tearDown(() async {
      awake.dispose();
      await proximity.close();
    });

    test('keeps the screen on while a room wants it', () async {
      awake.update(roomA, wanted: false);
      await _settle();
      expect(screen.calls, isEmpty);
      expect(awake.held.value, isFalse);

      awake.update(roomA, wanted: true);
      await _settle();
      expect(screen.on, isTrue);
      expect(awake.held.value, isTrue);

      awake.update(roomA, wanted: true);
      await _settle();
      expect(screen.calls, ['on'], reason: 'no repeats');

      awake.update(roomA, wanted: false);
      await _settle();
      expect(screen.on, isFalse);
      expect(awake.held.value, isFalse);
      expect(screen.calls, ['on', 'off']);
    });

    test('two rooms: on while either wants it; the last to leave lets the '
        'screen sleep', () async {
      awake.update(roomA, wanted: true);
      awake.update(roomB, wanted: false);
      await _settle();
      expect(screen.on, isTrue);

      awake.update(roomB, wanted: true);
      awake.update(roomA, wanted: false);
      await _settle();
      expect(screen.on, isTrue);
      expect(screen.calls, ['on'], reason: 'held throughout');

      await awake.leave(roomB);
      expect(screen.on, isFalse);
      expect(awake.held.value, isFalse);

      awake.update(roomA, wanted: true);
      await _settle();
      expect(screen.on, isTrue);
      await awake.leave(roomA);
      expect(screen.on, isFalse);
      expect(screen.calls, ['on', 'off', 'on', 'off']);
    });

    test('the proximity sensor wins: the screen is left to it while it is '
        'on', () async {
      proximity.set(true);
      awake.update(roomA, wanted: true);
      await _settle();
      expect(screen.calls, isEmpty, reason: 'the sensor owns the screen');
      expect(awake.held.value, isFalse);

      proximity.set(false);
      await _settle();
      expect(screen.on, isTrue);
      expect(awake.held.value, isTrue);

      proximity.set(true);
      await _settle();
      expect(screen.on, isFalse);
      expect(awake.held.value, isFalse);
      expect(screen.calls, ['on', 'off']);
    });

    test('a refused or failed request reports not held', () async {
      screen.error = StateError('no window');
      awake.update(roomA, wanted: true);
      await _settle();
      expect(awake.held.value, isFalse);
      expect(screen.calls, ['on']);
    });

    test('an unsupported platform never holds it', () async {
      final unsupported = ScreenAwake(
        const UnsupportedScreenAwakeBackend(),
        proximity: () => proximity,
      );
      addTearDown(unsupported.dispose);
      expect(unsupported.supported, isFalse);
      unsupported.update(roomA, wanted: true);
      await _settle();
      expect(unsupported.held.value, isFalse);
    });

    test('follows the platform releasing and taking the hold again (a '
        'hidden browser tab)', () async {
      awake.update(roomA, wanted: true);
      await _settle();
      expect(awake.held.value, isTrue);

      screen.platformChange(false);
      await _settle();
      expect(awake.held.value, isFalse);
      screen.platformChange(true);
      await _settle();
      expect(awake.held.value, isTrue);

      await awake.leave(roomA);
      screen.platformChange(true);
      await _settle();
      expect(awake.held.value, isFalse, reason: 'no longer wanted');
    });

    test('dispose lets the screen sleep', () async {
      awake.update(roomA, wanted: true);
      await _settle();
      awake.dispose();
      await _settle();
      expect(screen.on, isFalse);
    });
  });

  group('Room.keepScreenAwake', () {
    late _FakeScreen screen;
    late RoomHarness h;
    late ScreenAwakeBackendFactory? previousFactory;

    setUp(() {
      previousFactory = debugScreenAwakeBackendFactory;
      screen = _FakeScreen();
      debugScreenAwakeBackendFactory = () => screen;
      ScreenAwake.debugReset();
      h = RoomHarness();
    });

    tearDown(() {
      ScreenAwake.debugReset();
      debugScreenAwakeBackendFactory = previousFactory;
    });

    Future<Room> join(
      String id, {
      KeepScreenAwake policy = KeepScreenAwake.whileVideo,
      ReconnectOptions reconnect = const ReconnectOptions(),
      String roomId = 'room',
    }) async {
      final room = await h.join(
        id,
        roomId: roomId,
        options: RoomOptions(
          connectEarly: false,
          keepScreenAwake: policy,
          reconnect: reconnect,
        ),
      );
      await _settle();
      return room;
    }

    test('whileVideo (the default): not for a voice call; on while the '
        'local camera sends, off while it is muted or unpublished', () async {
      expect(const RoomOptions().keepScreenAwake, KeepScreenAwake.whileVideo);
      final alice = await join('alice');
      expect(alice.canKeepScreenAwake, isTrue);
      await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(alice.keepingScreenAwake, isFalse, reason: 'audio only');
      expect(screen.calls, isEmpty);

      final camera = await alice.localParticipant.publishCamera();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);
      expect(screen.on, isTrue);

      await camera.mute();
      await _settle();
      expect(alice.keepingScreenAwake, isFalse, reason: 'nothing is sent');
      await camera.unmute();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);

      await camera.unpublish();
      await _settle();
      expect(alice.keepingScreenAwake, isFalse);
      expect(screen.calls, ['on', 'off', 'on', 'off']);
      await alice.leave();
    });

    test(
      'whileVideo: a published camera that starts muted does not count',
      () async {
        final alice = await join('alice');
        await alice.localParticipant.publishCamera(muted: true);
        await _settle();
        expect(alice.keepingScreenAwake, isFalse);
        await alice.leave();
      },
    );

    test('whileVideo: subscribing to a remote camera holds it; '
        'unsubscribing or the publisher muting releases it', () async {
      // Bob publishes with keepScreenAwake: never, so only Alice's view of
      // his camera counts.
      final bob = await join('bob', policy: KeepScreenAwake.never);
      final bobCamera = await bob.localParticipant.publishCamera();
      final alice = await join('alice');
      await _settle();
      final aliceBobCamera = alice.participant('bob')!.camera!;
      expect(aliceBobCamera.isSubscribed, isFalse, reason: 'video waits');
      expect(alice.keepingScreenAwake, isFalse);

      await aliceBobCamera.subscribe();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);

      await bobCamera.mute();
      await _settle();
      expect(aliceBobCamera.muted, isTrue);
      expect(alice.keepingScreenAwake, isFalse);
      await bobCamera.unmute();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);

      await aliceBobCamera.unsubscribe();
      await _settle();
      expect(alice.keepingScreenAwake, isFalse);

      // A view's lease counts too.
      final lease = aliceBobCamera.retain();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);
      lease.release();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _settle();
      expect(alice.keepingScreenAwake, isFalse, reason: 'after the grace');

      await aliceBobCamera.subscribe();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);
      await bobCamera.unpublish();
      await _settle();
      expect(alice.keepingScreenAwake, isFalse, reason: 'unpublished');
      await alice.leave();
      await bob.leave();
    });

    test('stays on while reconnecting; off once the room gives up', () async {
      final alice = await join(
        'alice',
        reconnect: const ReconnectOptions(enabled: false),
      );
      await alice.localParticipant.publishCamera();
      await _settle();
      h.pcOf(alice).emitConnectionState(_connected);
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);

      h.pcOf(alice).emitConnectionState(_disconnected);
      await _settle();
      expect(alice.currentConnectionState, RoomConnectionState.reconnecting);
      expect(alice.keepingScreenAwake, isTrue);

      h.pcOf(alice).emitConnectionState(_connected);
      await _settle();
      expect(alice.currentConnectionState, RoomConnectionState.connected);
      expect(alice.keepingScreenAwake, isTrue);
      expect(screen.calls, ['on'], reason: 'held throughout');

      h.pcOf(alice).emitConnectionState(_failed);
      await _settle();
      expect(alice.currentConnectionState, RoomConnectionState.disconnected);
      expect(alice.keepingScreenAwake, isFalse);
      expect(screen.calls, ['on', 'off']);
      await alice.leave();
    });

    test('leave releases it', () async {
      final alice = await join('alice');
      await alice.localParticipant.publishCamera();
      await _settle();
      expect(screen.on, isTrue);
      await alice.leave();
      expect(screen.on, isFalse);
      expect(alice.keepingScreenAwake, isFalse);
    });

    test('two rooms: held while either has video', () async {
      final video = await join('alice', roomId: 'video');
      final voice = await join('alice', roomId: 'voice');
      await voice.localParticipant.publishMicrophone();
      final camera = await video.localParticipant.publishCamera();
      await _settle();
      expect(voice.keepingScreenAwake, isTrue, reason: 'app-wide');

      await camera.mute();
      await _settle();
      expect(screen.on, isFalse);
      await camera.unmute();
      await _settle();
      expect(screen.on, isTrue);

      await video.leave();
      expect(screen.on, isFalse, reason: 'the voice room has no video');
      await voice.leave();
      expect(screen.calls, ['on', 'off', 'on', 'off']);
    });

    test('always: on from the join, video or not; off on leave', () async {
      final alice = await join('alice', policy: KeepScreenAwake.always);
      expect(alice.keepingScreenAwake, isTrue);
      await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(alice.keepingScreenAwake, isTrue);
      await alice.leave();
      expect(screen.on, isFalse);
    });

    test('never: not even with video', () async {
      final alice = await join('alice', policy: KeepScreenAwake.never);
      await alice.localParticipant.publishCamera();
      await _settle();
      expect(alice.keepingScreenAwake, isFalse);
      expect(screen.calls, isEmpty);
      await alice.leave();
    });

    group('on a phone with a proximity sensor', () {
      late _FakePhone phone;

      setUp(() {
        phone = _FakePhone();
        debugCallAudioBackendFactory = () => phone;
        CallAudio.debugReset();
        // The policy reads the new CallAudio's proximity sensor.
        ScreenAwake.debugReset();
      });

      tearDown(() {
        CallAudio.debugReset();
        debugCallAudioBackendFactory = null;
      });

      test('always: the proximity sensor wins on the earpiece; the '
          'speaker keeps the screen on', () async {
        final alice = await h.join(
          'alice',
          options: const RoomOptions(
            connectEarly: false,
            keepScreenAwake: KeepScreenAwake.always,
            speakerphone: false,
          ),
        );
        await alice.localParticipant.publishMicrophone();
        await _settle();
        expect(phone.currentNow, _FakePhone.earpiece);
        expect(alice.proximitySensorActive, isTrue);
        expect(alice.keepingScreenAwake, isFalse, reason: 'at the ear');
        expect(screen.calls, isEmpty);

        await alice.setSpeakerphone(true);
        await _settle();
        expect(alice.proximitySensorActive, isFalse);
        expect(alice.keepingScreenAwake, isTrue);

        await alice.setSpeakerphone(false);
        await _settle();
        expect(alice.proximitySensorActive, isTrue);
        expect(alice.keepingScreenAwake, isFalse);
        await alice.leave();
        expect(screen.calls, ['on', 'off']);
      });

      test(
        'whileVideo: a voice call on the earpiece leaves the screen to '
        'the sensor; video turns the sensor off and keeps the screen on',
        () async {
          final alice = await h.join(
            'alice',
            options: const RoomOptions(connectEarly: false),
          );
          await alice.localParticipant.publishMicrophone();
          await _settle();
          expect(phone.currentNow, _FakePhone.earpiece);
          expect(alice.proximitySensorActive, isTrue);
          expect(alice.keepingScreenAwake, isFalse);

          await alice.localParticipant.publishCamera();
          await _settle();
          expect(phone.currentNow, _FakePhone.speaker);
          expect(alice.proximitySensorActive, isFalse);
          expect(alice.keepingScreenAwake, isTrue);
          await alice.leave();
          expect(screen.on, isFalse);
        },
      );
    });
  });
}
