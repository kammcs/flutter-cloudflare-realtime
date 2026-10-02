import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/call_audio.dart';
import 'package:cloudflare_realtime/src/audio/call_audio_backend.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';

import '../support/room_harness.dart';

const _speaker = AudioRoute(id: 'spk', kind: AudioRouteKind.speaker);
const _earpiece = AudioRoute(id: 'ear', kind: AudioRouteKind.earpiece);
const _buds = AudioRoute(
  id: 'bt-1',
  kind: AudioRouteKind.bluetooth,
  name: 'Buds',
);
const _wired = AudioRoute(
  id: 'wired',
  kind: AudioRouteKind.wiredHeadset,
  name: 'Headset',
);

/// A phone: lists [routes], plays on [current], and accepts a selection
/// of a listed route unless [refuse] is set. It has a proximity sensor
/// unless [noSensor], and gives the audio back on `resume` unless
/// [refuseResume] (a phone call still holding it).
class _FakePhone implements CallAudioBackend {
  List<AudioRoute> routesNow = [_speaker, _earpiece];
  AudioRoute? currentNow;
  bool refuse = false;
  bool noSensor = false;
  bool refuseResume = false;
  bool proximityOn = false;
  final List<String> calls = [];
  final StreamController<void> _changes = StreamController.broadcast();
  final StreamController<AudioInterruptionSignal> _interruptions =
      StreamController.broadcast();

  /// The platform interrupts the call (began) or ends the interruption.
  void interrupt(AudioInterruptionSignal signal) => _interruptions.add(signal);

  /// Connects or disconnects devices, like the platform would.
  void setRoutes(List<AudioRoute> routes) {
    routesNow = routes;
    if (currentNow != null && !routes.contains(currentNow)) currentNow = null;
    _changes.add(null);
  }

  @override
  bool get supported => true;

  @override
  Future<void> activate() async => calls.add('activate');

  @override
  Future<void> deactivate() async => calls.add('deactivate');

  @override
  Future<void> setDefaultToSpeaker(bool speaker) async =>
      calls.add('default ${speaker ? 'speaker' : 'earpiece'}');

  @override
  Future<List<AudioRoute>> routes() async => routesNow;

  @override
  Future<AudioRoute?> current() async => currentNow;

  @override
  Future<bool> select(AudioRoute route) async {
    calls.add('select ${route.id}');
    if (refuse || !routesNow.contains(route)) return false;
    currentNow = route;
    return true;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> setProximityMonitoring(bool enabled) async {
    calls.add('proximity ${enabled ? 'on' : 'off'}');
    proximityOn = enabled && !noSensor;
    return proximityOn;
  }

  @override
  Future<bool> resume() async {
    calls.add('resume');
    return !refuseResume;
  }

  @override
  Stream<AudioInterruptionSignal> get interruptions => _interruptions.stream;
}

/// The app lifecycle, driven by the test.
class _FakeLifecycle implements AppLifecycleSource {
  final StreamController<AppLifecycleState> _states =
      StreamController.broadcast(sync: true);

  void emit(AppLifecycleState state) => _states.add(state);

  @override
  Stream<AppLifecycleState> get states => _states.stream;
}

Future<void> _settle() => pumpEventQueue(times: 30);

void main() {
  late _FakePhone phone;
  late _FakeLifecycle lifecycle;

  setUp(() {
    phone = _FakePhone();
    lifecycle = _FakeLifecycle();
    debugCallAudioBackendFactory = () => phone;
    debugCallLifecycleSource = lifecycle;
    CallAudio.debugReset();
  });

  tearDown(() {
    CallAudio.debugReset();
    debugCallAudioBackendFactory = null;
    debugCallLifecycleSource = null;
  });

  CallAudio audio() => CallAudio.instance;

  group('visibleAudioRoutes', () {
    test('drops the earpiece while a Bluetooth headset is connected', () {
      expect(visibleAudioRoutes([_speaker, _earpiece, _buds]), [
        _speaker,
        _buds,
      ]);
      expect(visibleAudioRoutes([_speaker, _earpiece, _wired]), [
        _speaker,
        _earpiece,
        _wired,
      ]);
    });

    test('drops duplicate ids', () {
      expect(visibleAudioRoutes([_speaker, _speaker, _earpiece]), [
        _speaker,
        _earpiece,
      ]);
    });
  });

  group('the policy', () {
    test('a voice call starts on the earpiece, and video moves it to the '
        'speaker for good', () async {
      final room = Object();
      await audio().join(room);
      expect(phone.calls, [
        'activate',
        'default earpiece',
        'select ear',
        'proximity on',
      ]);
      expect(audio().current.value, _earpiece);
      expect(audio().routes.value, [_speaker, _earpiece]);

      audio().videoStarted(room);
      await _settle();
      expect(audio().current.value, _speaker);
      expect(phone.calls, contains('default speaker'));

      // A device change doesn't send it back to the earpiece.
      phone.setRoutes([_speaker, _earpiece]);
      await _settle();
      expect(audio().current.value, _speaker);
    });

    test('a connected headset comes first, even with video', () async {
      phone.routesNow = [_speaker, _earpiece, _wired];
      final room = Object();
      await audio().join(room);
      expect(audio().current.value, _wired);
      audio().videoStarted(room);
      await _settle();
      expect(audio().current.value, _wired);
    });

    test('a headset that connects mid-call takes over; when it goes, the '
        'default comes back', () async {
      final room = Object();
      await audio().join(room);
      audio().videoStarted(room);
      await _settle();
      expect(audio().current.value, _speaker);

      phone.setRoutes([_speaker, _earpiece, _buds]);
      await _settle();
      expect(audio().current.value, _buds);
      expect(audio().routes.value, [_speaker, _buds], reason: 'no earpiece');

      phone.setRoutes([_speaker, _earpiece]);
      await _settle();
      expect(audio().current.value, _speaker);
    });

    test("the user's choice sticks until a new headset arrives", () async {
      phone.routesNow = [_speaker, _earpiece, _wired];
      final room = Object();
      await audio().join(room);
      await audio().select(_speaker);
      expect(audio().current.value, _speaker);

      // Unrelated changes, even video starting, don't undo it.
      audio().videoStarted(room);
      phone.setRoutes([_speaker, _earpiece, _wired]);
      await _settle();
      expect(audio().current.value, _speaker);

      // A new headset does.
      phone.setRoutes([_speaker, _wired, _buds]);
      await _settle();
      expect(audio().current.value, _buds);
    });

    test('picking the earpiece in a video call switches the base to voice '
        'first (iOS reaches the receiver only from voice chat)', () async {
      final room = Object();
      await audio().join(room);
      audio().videoStarted(room);
      await _settle();
      expect(audio().current.value, _speaker);
      phone.calls.clear();

      await audio().select(_earpiece);
      expect(phone.calls.take(2), ['default earpiece', 'select ear']);
      expect(audio().current.value, _earpiece);
      phone.calls.clear();

      await audio().select(_speaker);
      expect(phone.calls.take(2), ['default speaker', 'select spk']);
    });

    test("the user's choice is dropped when its route goes", () async {
      phone.routesNow = [_speaker, _earpiece, _wired];
      final room = Object();
      await audio().join(room);
      await audio().select(_earpiece);
      expect(audio().current.value, _earpiece);

      phone.setRoutes([_speaker, _wired, _buds]);
      await _settle();
      expect(audio().current.value, _buds, reason: 'new headset');
      phone.setRoutes([_speaker, _earpiece]);
      await _settle();
      expect(audio().current.value, _earpiece, reason: 'voice call default');
    });

    test(
      'a refused selection throws and leaves the policy in charge',
      () async {
        final room = Object();
        await audio().join(room);
        phone.refuse = true;
        await expectLater(
          audio().select(_speaker),
          throwsA(isA<AudioRouteUnavailableException>()),
        );
        phone.refuse = false;
        phone.setRoutes([_speaker, _earpiece]);
        await _settle();
        expect(audio().current.value, _earpiece);
      },
    );

    test(
      'setSpeakerphone forces speaker or earpiece, after headsets',
      () async {
        final room = Object();
        await audio().join(room);
        await audio().setSpeakerphone(true);
        expect(audio().current.value, _speaker);
        await audio().setSpeakerphone(false);
        expect(audio().current.value, _earpiece);

        phone.setRoutes([_speaker, _earpiece, _wired]);
        await _settle();
        await audio().setSpeakerphone(true);
        expect(audio().current.value, _wired, reason: 'the headset first');
      },
    );

    test(
      "a room's option forces the route; video doesn't override it",
      () async {
        final room = Object();
        await audio().join(room, speakerphone: false);
        audio().videoStarted(room);
        await _settle();
        expect(audio().current.value, _earpiece);
      },
    );

    test(
      'an external route chosen elsewhere is kept (Apple route picker)',
      () async {
        const airplay = AudioRoute(
          id: 'ap',
          kind: AudioRouteKind.other,
          name: 'Living Room',
        );
        phone.routesNow = [_speaker, _earpiece, _buds];
        final room = Object();
        await audio().join(room);
        expect(audio().current.value, _buds);

        // The user picks AirPlay in Apple's picker: it becomes the route.
        phone.currentNow = airplay;
        phone.setRoutes([_speaker, _buds, airplay]);
        await _settle();
        expect(audio().current.value, airplay);
      },
    );

    test('rooms share one route; the last one out leaves call mode', () async {
      final voice = Object();
      final video = Object();
      await audio().join(voice);
      await audio().join(video);
      audio().videoStarted(video);
      await _settle();
      expect(audio().current.value, _speaker);
      expect(phone.calls.where((c) => c == 'activate'), hasLength(1));

      await audio().leave(video);
      await audio().leave(voice);
      expect(phone.calls.last, 'deactivate');
      expect(phone.calls.where((c) => c == 'deactivate'), hasLength(1));
    });
  });

  group('interruptions', () {
    test('the platform interrupts and ends: the call takes its audio back '
        'and routes again', () async {
      final room = Object();
      await audio().join(room);
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.phoneCall),
      );
      await _settle();
      expect(audio().interruption.value, CallInterruptionReason.phoneCall);

      // The platform moved the audio meanwhile.
      phone.currentNow = _speaker;
      phone.calls.clear();
      phone.interrupt(const AudioInterruptionSignal.ended());
      await _settle();
      expect(phone.calls.first, 'resume');
      expect(audio().interruption.value, isNull);
      expect(audio().current.value, _earpiece, reason: 'routed again');
    });

    test('a refined reason replaces the first one', () async {
      await audio().join(Object());
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.otherAudio),
      );
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.phoneCall),
      );
      await _settle();
      expect(audio().interruption.value, CallInterruptionReason.phoneCall);
    });

    test('without an end, the call takes its audio back in the foreground; '
        'not while a phone call holds it', () async {
      await audio().join(Object());
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.otherAudio),
      );
      await _settle();

      phone.refuseResume = true;
      lifecycle.emit(AppLifecycleState.resumed);
      await _settle();
      expect(phone.calls.last, 'resume');
      expect(audio().interruption.value, CallInterruptionReason.otherAudio);

      phone.refuseResume = false;
      lifecycle.emit(AppLifecycleState.paused);
      lifecycle.emit(AppLifecycleState.resumed);
      await _settle();
      expect(audio().interruption.value, isNull);
    });

    test('resume() asks the platform only while interrupted', () async {
      await audio().join(Object());
      expect(await audio().resume(), isTrue);
      expect(phone.calls, isNot(contains('resume')));

      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.unknown),
      );
      await _settle();
      phone.refuseResume = true;
      expect(await audio().resume(), isFalse);
      phone.refuseResume = false;
      expect(await audio().resume(), isTrue);
      expect(audio().interruption.value, isNull);
    });

    test('ignored before a room joins; cleared when the last one '
        'leaves', () async {
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.unknown),
      );
      await _settle();
      expect(audio().interruption.value, isNull);

      final room = Object();
      await audio().join(room);
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.unknown),
      );
      await _settle();
      expect(audio().interruption.value, isNotNull);
      await audio().leave(room);
      expect(audio().interruption.value, isNull);
    });

    test('the native event maps', () {
      expect(
        audioInterruptionFromMap({
          'event': 'interruption',
          'type': 'began',
          'reason': 'phoneCall',
        }),
        const AudioInterruptionSignal.began(CallInterruptionReason.phoneCall),
      );
      expect(
        audioInterruptionFromMap({
          'event': 'interruption',
          'type': 'began',
          'reason': 'somethingNew',
        }),
        const AudioInterruptionSignal.began(CallInterruptionReason.unknown),
      );
      expect(
        audioInterruptionFromMap({'event': 'interruption', 'type': 'ended'}),
        const AudioInterruptionSignal.ended(),
      );
      expect(audioInterruptionFromMap({'event': 'other'}), isNull);
    });
  });

  group('the proximity sensor', () {
    test('on for the earpiece in a voice call; off on the speaker, a '
        'headset, with video, and after leaving', () async {
      final room = Object();
      await audio().join(room);
      expect(audio().proximity.value, isTrue);

      await audio().select(_speaker);
      expect(audio().proximity.value, isFalse);
      await audio().select(_earpiece);
      expect(audio().proximity.value, isTrue);

      phone.setRoutes([_speaker, _earpiece, _wired]);
      await _settle();
      expect(audio().current.value, _wired);
      expect(audio().proximity.value, isFalse);
      phone.setRoutes([_speaker, _earpiece]);
      await _settle();
      expect(audio().proximity.value, isTrue);

      audio().videoStarted(room);
      await _settle();
      expect(audio().proximity.value, isFalse);
      await audio().select(_earpiece);
      expect(audio().current.value, _earpiece);
      expect(audio().proximity.value, isFalse, reason: 'video');

      await audio().leave(room);
      expect(phone.proximityOn, isFalse);
    });

    test('off while any room turned it off', () async {
      final quiet = Object();
      final normal = Object();
      await audio().join(normal);
      expect(audio().proximity.value, isTrue);
      await audio().join(quiet, proximitySensor: false);
      expect(audio().proximity.value, isFalse);
      expect(phone.proximityOn, isFalse);
      await audio().leave(quiet);
      expect(audio().proximity.value, isTrue);
    });

    test('reports off on a device without the sensor, and asks once', () async {
      phone.noSensor = true;
      await audio().join(Object());
      expect(audio().proximity.value, isFalse);
      phone.setRoutes([_speaker, _earpiece]);
      await _settle();
      expect(phone.calls.where((c) => c.startsWith('proximity')), [
        'proximity on',
      ]);
    });
  });

  group('the Room', () {
    late RoomHarness h;

    setUp(() => h = RoomHarness());

    test('joins call audio, moves to the speaker when it publishes its '
        'camera, and leaves it', () async {
      final alice = await h.join('alice');
      expect(alice.canSelectAudioRoute, isTrue);
      expect(alice.currentAudioRoute, _earpiece);
      expect(alice.speakerphone, isFalse);

      await alice.localParticipant.publishCamera();
      await _settle();
      expect(alice.currentAudioRoute, _speaker);
      expect(alice.speakerphone, isTrue);

      await alice.selectAudioRoute(_earpiece);
      expect(alice.currentAudioRoute, _earpiece);
      await alice.setSpeakerphone(true);
      expect(alice.currentAudioRoute, _speaker);

      await alice.leave();
      expect(phone.calls.last, 'deactivate');
      expect(() => alice.selectAudioRoute(_speaker), throwsStateError);
    });

    test(
      'RoomOptions.speakerphone true starts a voice call on the speaker',
      () async {
        final alice = await h.join(
          'alice',
          options: const RoomOptions(connectEarly: false, speakerphone: true),
        );
        expect(alice.currentAudioRoute, _speaker);
        await alice.leave();
      },
    );

    test('an interruption silences the call, announces nothing, and '
        'resumes', () async {
      final alice = await h.join(
        'alice',
        options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
      );
      final bob = await h.join('bob');
      final events = <RoomEvent>[];
      alice.events.listen(events.add);
      final mic = await alice.localParticipant.publishMicrophone();
      await bob.localParticipant.publishMicrophone();
      await _settle();
      final pulled = alice.participant('bob')!.microphone!;
      final remote = pulled.currentTrack!.track;
      final local = mic.mediaSource.currentBroadcastTrack!.track;
      expect(alice.canDetectAudioInterruptions, isTrue);

      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.phoneCall),
      );
      await _settle();
      expect(alice.audioInterruption, CallInterruptionReason.phoneCall);
      expect(
        events.whereType<CallInterruptedEvent>().single.reason,
        CallInterruptionReason.phoneCall,
      );
      expect(remote.enabled, isFalse);
      expect(local.enabled, isFalse);
      expect(mic.muted, isFalse, reason: 'not announced as muted');
      expect(h.announced('alice')!.tracks.values.single.muted, isFalse);

      phone.interrupt(const AudioInterruptionSignal.ended());
      await _settle();
      expect(alice.audioInterruption, isNull);
      expect(
        events.whereType<CallResumedEvent>().single.reason,
        CallInterruptionReason.phoneCall,
      );
      expect(remote.enabled, isTrue);
      expect(local.enabled, isTrue);

      await alice.leave();
      await bob.leave();
    });

    test('resumeAudio() takes the audio back after a permanent loss, and a '
        "leave doesn't leave an app's microphone silent", () async {
      final alice = await h.join('alice');
      final source = MicrophoneSource(backend: h.media);
      await source.startBroadcasting();
      await alice.localParticipant.publishMediaSource(source);
      await _settle();
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.otherAudio),
      );
      await _settle();
      final track = source.currentBroadcastTrack!.track;
      expect(track.enabled, isFalse);

      phone.refuseResume = true;
      expect(await alice.resumeAudio(), isFalse);
      phone.refuseResume = false;
      expect(await alice.resumeAudio(), isTrue);
      await _settle();
      expect(track.enabled, isTrue);

      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.otherAudio),
      );
      await _settle();
      expect(track.enabled, isFalse);
      await alice.leave();
      expect(track.enabled, isTrue);
      await source.dispose();
    });

    test('proximity follows the route; RoomOptions.proximitySensor turns it '
        'off', () async {
      final alice = await h.join('alice');
      expect(alice.proximitySensorActive, isTrue);
      await alice.setSpeakerphone(true);
      expect(alice.proximitySensorActive, isFalse);
      await alice.leave();
      expect(phone.proximityOn, isFalse);

      final bob = await h.join(
        'bob',
        options: const RoomOptions(proximitySensor: false),
      );
      expect(bob.currentAudioRoute, _earpiece);
      expect(bob.proximitySensorActive, isFalse);
      await bob.leave();
    });

    test('desktops and browsers: no routes, and the calls throw', () async {
      debugCallAudioBackendFactory = () => const UnsupportedCallAudioBackend();
      CallAudio.debugReset();
      final alice = await h.join('alice');
      expect(alice.canSelectAudioRoute, isFalse);
      expect(alice.canSetSpeakerphone, isFalse);
      expect(alice.currentAudioRoutes, isEmpty);
      expect(alice.currentAudioRoute, isNull);
      expect(() => alice.setSpeakerphone(true), throwsUnsupportedError);
      expect(() => alice.selectAudioRoute(_speaker), throwsUnsupportedError);
      expect(alice.canDetectAudioInterruptions, isFalse);
      expect(alice.audioInterruption, isNull);
      expect(await alice.resumeAudio(), isTrue);
      expect(alice.proximitySensorActive, isFalse);
      await alice.leave();
    });
  });
}
