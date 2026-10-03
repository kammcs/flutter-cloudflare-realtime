import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import '../support/room_harness.dart';

const _mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);
const _screenAudio = TrackInfo(
  kind: TrackKind.audio,
  source: TrackSource.screenAudio,
);

StatsReport _inbound(String id, {String? mid, String? track, double? level}) =>
    StatsReport(id, 'inbound-rtp', 0, {
      'kind': 'audio',
      'mid': ?mid,
      'trackIdentifier': ?track,
      'audioLevel': ?level,
    });

StatsReport _source(String track, double level) => StatsReport(
  'source-$track',
  'media-source',
  0,
  {'kind': 'audio', 'trackIdentifier': track, 'audioLevel': level},
);

/// A presence-only participant driven by the test.
class _Puppet {
  _Puppet(this.h, this.id);

  final RoomHarness h;
  final String id;
  late final InMemorySignaling signaling = InMemorySignaling(h.hub);
  bool _joined = false;

  String get sessionId => '$id-1';

  void announce(Map<String, TrackInfo> tracks) {
    for (final MapEntry(key: name, value: info) in tracks.entries) {
      h.broker.trackKinds['$sessionId/$name'] = info.kind.name;
    }
    final state = ParticipantState(
      participantId: id,
      sessionId: sessionId,
      tracks: tracks,
    );
    if (_joined) {
      signaling.update(state);
    } else {
      _joined = true;
      signaling.join('room', state);
    }
  }
}

void main() {
  late RoomHarness h;

  setUp(() => h = RoomHarness());

  /// Runs [body] on fake time. [pump] runs pending microtasks and
  /// zero-length timers; [poll] advances by [count] stats polls.
  void run(
    void Function(
      FakeAsync async,
      void Function() pump,
      void Function([int count]) poll,
    )
    body,
  ) {
    fakeAsync((async) {
      void pump() {
        for (var i = 0; i < 40; i++) {
          async.elapse(Duration.zero);
        }
      }

      void poll([int count = 1]) {
        for (var i = 0; i < count; i++) {
          async.elapse(const Duration(milliseconds: 250));
          pump();
        }
      }

      body(async, pump, poll);
    });
  }

  test('maps inbound audio to participants by mid and track ID', () {
    run((async, pump, poll) {
      late Room bob;
      h.join('bob').then((r) => bob = r);
      pump();
      final ann = _Puppet(h, 'ann')..announce({'m': _mic, 's': _screenAudio});
      final cat = _Puppet(h, 'cat')..announce({'m': _mic});
      pump();
      final annMic = bob.participant('ann')!.microphone!.subscription!;
      final annScreen = bob.participant('ann')!.screenAudio!.subscription!;
      final catTrackId = bob
          .participant('cat')!
          .microphone!
          .subscription!
          .track!
          .id;

      final speakers = <List<String>>[];
      bob.activeSpeakers.listen(speakers.add);
      final annSpeaking = <bool>[];
      bob.participant('ann')!.speakingChanges.listen(annSpeaking.add);

      var annLevel = 0.3;
      var catLevel = 0.0;
      h.pcOf(bob).statsProvider = () => [
        // By mid.
        _inbound('in-ann', mid: annMic.mid, level: annLevel),
        // By track ID only (some platforms leave out the mid).
        _inbound('in-cat', track: catTrackId, level: catLevel),
        // Screen-share audio never counts as speaking.
        _inbound('in-screen', mid: annScreen.mid, level: 0.9),
        // Unknown streams are ignored.
        _inbound('in-x', mid: 'nope', level: 0.9),
      ];

      poll(3);
      expect(bob.currentActiveSpeakers, ['ann']);
      expect(bob.currentDominantSpeaker, 'ann');
      expect(bob.participant('ann')!.isSpeaking, isTrue);
      expect(bob.participant('ann')!.audioLevel, greaterThan(0.1));
      expect(bob.participant('cat')!.isSpeaking, isFalse);
      expect(bob.participant('cat')!.audioLevel, 0);

      // Cat speaks up, louder; the order follows.
      catLevel = 0.6;
      poll(3);
      expect(bob.currentActiveSpeakers, ['cat', 'ann']);

      // Ann stops: released after the hold time.
      annLevel = 0;
      poll(8);
      expect(bob.currentActiveSpeakers, ['cat']);
      expect(bob.participant('ann')!.isSpeaking, isFalse);
      expect(speakers, [
        isEmpty,
        ['ann'],
        ['cat', 'ann'],
        ['cat'],
      ]);
      expect(annSpeaking, [false, true, false]);

      // Cat leaves: gone from the list at once.
      cat.signaling.leave();
      pump();
      poll();
      expect(bob.currentActiveSpeakers, isEmpty);

      bob.leave();
      ann.signaling.dispose();
      cat.signaling.dispose();
      pump();
      expect(bob.currentActiveSpeakers, isEmpty);
    });
  });

  test(
    'the local microphone counts while unmuted, never while muted',
    () async {
      // Captured outside the fake zone: capture awaits futures that only the
      // real event loop completes.
      final source = MicrophoneSource(backend: h.media);
      expect(await source.startBroadcasting(), isTrue);
      run((async, pump, poll) {
        late Room bob;
        h.join('bob').then((r) => bob = r);
        pump();
        late LocalMediaPublication mic;
        bob.localParticipant.publishMediaSource(source).then((p) => mic = p);
        pump();
        final trackId = mic.publication.track!.id!;
        final pc = h.pcOf(bob);
        pc.statsProvider = () => [
          // The sender's media-source, only while it has a track.
          if (mic.publication.track != null) _source(trackId, 0.5),
          // Another local audio source (screen-share audio, say).
          _source('other', 0.9),
        ];

        final levels = <double>[];
        bob.localParticipant.audioLevels.listen(levels.add);
        poll(3);
        expect(bob.localParticipant.isSpeaking, isTrue);
        expect(bob.currentActiveSpeakers, ['bob']);
        // Its own track's level only, not the other source's.
        expect(bob.localParticipant.audioLevel, inInclusiveRange(0.2, 0.5));
        expect(levels.last, bob.localParticipant.audioLevel);
        expect(
          bob.currentDominantSpeaker,
          isNull,
          reason: 'local not dominant',
        );

        mic.mute();
        pump();
        poll(6);
        expect(bob.localParticipant.isSpeaking, isFalse);
        expect(bob.currentActiveSpeakers, isEmpty);
        expect(bob.localParticipant.audioLevel, lessThan(0.05));
        // Not detectable: the muted sender has no track, so no level.
        expect(bob.localParticipant.canDetectSpeakingWhileMuted, isFalse);
        expect(bob.localParticipant.isSpeakingWhileMuted, isFalse);

        bob.leave();
        pump();
      });
      await source.dispose();
    },
  );

  test('polls only while there is audio, and skips failed polls', () {
    run((async, pump, poll) {
      late Room bob;
      // No connection-quality polls: this counts the speakers' polls.
      h
          .join(
            'bob',
            options: const RoomOptions(
              connectEarly: false,
              stats: RoomStatsOptions(connectionQuality: null),
            ),
          )
          .then((r) => bob = r);
      pump();
      final pc = h.pcOf(bob);
      poll(4);
      expect(pc.statsCalls, 0, reason: 'nothing to measure');

      final ann = _Puppet(h, 'ann')..announce({'m': _mic});
      pump();
      final mid = bob.participant('ann')!.microphone!.subscription!.mid;
      pc.stats = [_inbound('in', mid: mid, level: 0.5)];
      poll(3);
      expect(pc.statsCalls, 3);
      expect(bob.currentActiveSpeakers, ['ann']);

      pc.failNext('getStats', StateError('renegotiating'));
      poll();
      expect(pc.statsCalls, 4);
      expect(bob.currentActiveSpeakers, ['ann'], reason: 'skipped');

      bob.leave();
      pump();
      final calls = pc.statsCalls;
      poll(4);
      expect(pc.statsCalls, calls, reason: 'stopped with the room');
      ann.signaling.dispose();
    });
  });

  test('can be turned off', () {
    run((async, pump, poll) {
      late Room bob;
      h
          .join(
            'bob',
            options: const RoomOptions(
              connectEarly: false,
              activeSpeaker: null,
              stats: RoomStatsOptions(connectionQuality: null),
            ),
          )
          .then((r) => bob = r);
      pump();
      final ann = _Puppet(h, 'ann')..announce({'m': _mic});
      pump();
      final pc = h.pcOf(bob);
      final mid = bob.participant('ann')!.microphone!.subscription!.mid;
      pc.stats = [_inbound('in', mid: mid, level: 0.5)];
      poll(8);
      expect(pc.statsCalls, 0);
      expect(bob.currentActiveSpeakers, isEmpty);
      bob.leave();
      ann.signaling.dispose();
      pump();
    });
  });
}
