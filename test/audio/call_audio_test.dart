import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/call_audio.dart';
import 'package:cloudflare_realtime/src/audio/call_audio_backend.dart';
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
/// of a listed route unless [refuse] is set.
class _FakePhone implements CallAudioBackend {
  List<AudioRoute> routesNow = [_speaker, _earpiece];
  AudioRoute? currentNow;
  bool refuse = false;
  final List<String> calls = [];
  final StreamController<void> _changes = StreamController.broadcast();

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
}

Future<void> _settle() => pumpEventQueue(times: 30);

void main() {
  late _FakePhone phone;

  setUp(() {
    phone = _FakePhone();
    debugCallAudioBackendFactory = () => phone;
    CallAudio.debugReset();
  });

  tearDown(() {
    CallAudio.debugReset();
    debugCallAudioBackendFactory = null;
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
      expect(phone.calls, ['activate', 'default earpiece', 'select ear']);
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

      await audio().select(_speaker);
      expect(phone.calls.skip(2).take(2), ['default speaker', 'select spk']);
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
          options: const RoomOptions(speakerphone: true),
        );
        expect(alice.currentAudioRoute, _speaker);
        await alice.leave();
      },
    );

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
      await alice.leave();
    });
  });
}
