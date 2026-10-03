import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import '../support/room_harness.dart';

const _mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);

/// Typed stats only, without connection-quality polls.
const _statsOnly = RoomOptions(
  connectEarly: false,
  activeSpeaker: null,
  stats: RoomStatsOptions(connectionQuality: null),
);

/// The defaults (quality on), without active-speaker polls.
const _withQuality = RoomOptions(connectEarly: false, activeSpeaker: null);

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

/// A remote audio stream: [bytes] and [packets] received, [lost] lost.
StatsReport _inboundAudio(
  String? mid, {
  int bytes = 0,
  int packets = 0,
  int lost = 0,
  double jitter = 0.005,
}) => StatsReport('in-$mid', 'inbound-rtp', 0, {
  'kind': 'audio',
  'mid': mid,
  'bytesReceived': bytes,
  'packetsReceived': packets,
  'packetsLost': lost,
  'jitter': jitter,
});

/// The selected candidate pair with [rtt] seconds.
List<StatsReport> _pair({double rtt = 0.02}) => [
  StatsReport('T', 'transport', 0, {'selectedCandidatePairId': 'CP'}),
  StatsReport('CP', 'candidate-pair', 0, {
    'currentRoundTripTime': rtt,
    'availableOutgoingBitrate': 3000000,
    'localCandidateId': 'L',
    'remoteCandidateId': 'R',
  }),
  StatsReport('L', 'local-candidate', 0, {'candidateType': 'host'}),
  StatsReport('R', 'remote-candidate', 0, {'candidateType': 'host'}),
];

void main() {
  late RoomHarness h;

  setUp(() => h = RoomHarness());

  /// Runs [body] on fake time; `pump` settles microtasks and zero-length
  /// timers.
  void run(void Function(FakeAsync async, void Function() pump) body) {
    fakeAsync((async) {
      void pump() {
        for (var i = 0; i < 40; i++) {
          async.elapse(Duration.zero);
        }
      }

      body(async, pump);
    });
  }

  Room join(
    void Function() pump,
    String id, {
    RoomOptions options = _statsOnly,
  }) {
    Room? room;
    h.join(id, options: options).then((r) => room = r);
    pump();
    return room!;
  }

  group('polling', () {
    test('only while someone listens, when quality is off; stops when the '
        'last listener cancels and on leave', () {
      run((async, pump) {
        final bob = join(pump, 'bob');
        final pc = h.pcOf(bob);
        async.elapse(const Duration(seconds: 10));
        expect(pc.statsCalls, 0, reason: 'nobody listens');

        final snapshots = <RoomStats>[];
        final first = bob.statsChanges.listen(snapshots.add);
        pump();
        expect(pc.statsCalls, 1, reason: 'a snapshot at once');
        async.elapse(const Duration(seconds: 4));
        pump();
        expect(pc.statsCalls, 3, reason: 'every 2 s');
        expect(snapshots, hasLength(3));

        // A second listener shares the polls and gets the latest at once.
        final late = <RoomStats>[];
        final second = bob.statsChanges.listen(late.add);
        pump();
        expect(late, [snapshots.last]);
        expect(pc.statsCalls, 3);
        expect(bob.stats, same(snapshots.last));

        first.cancel();
        async.elapse(const Duration(seconds: 2));
        pump();
        expect(pc.statsCalls, 4, reason: 'one listener left');
        second.cancel();
        async.elapse(const Duration(seconds: 10));
        pump();
        expect(pc.statsCalls, 4, reason: 'stopped');

        // One snapshot on demand, without listeners.
        late RoomStats taken;
        bob.getStats().then((s) => taken = s);
        pump();
        expect(pc.statsCalls, 5);
        expect(taken.interval, isNotNull, reason: 'rates since the last');

        final sub = bob.statsChanges.listen(null);
        pump();
        expect(pc.statsCalls, 6);
        bob.leave();
        pump();
        final calls = pc.statsCalls;
        async.elapse(const Duration(seconds: 10));
        expect(pc.statsCalls, calls, reason: 'stopped with the room');
        expect(() => bob.getStats(), throwsStateError);
        sub.cancel();
      });
    });

    test('with connection quality (the default), polls while joined and '
        'stops on leave', () {
      run((async, pump) {
        final bob = join(pump, 'bob', options: _withQuality);
        final pc = h.pcOf(bob);
        async.elapse(const Duration(seconds: 4));
        pump();
        expect(pc.statsCalls, 3);
        bob.leave();
        pump();
        final calls = pc.statsCalls;
        async.elapse(const Duration(seconds: 10));
        expect(pc.statsCalls, calls);
      });
    });

    test('the interval is configurable; failed polls are skipped', () {
      run((async, pump) {
        final bob = join(
          pump,
          'bob',
          options: const RoomOptions(
            connectEarly: false,
            activeSpeaker: null,
            stats: RoomStatsOptions(
              interval: Duration(milliseconds: 500),
              connectionQuality: null,
            ),
          ),
        );
        final pc = h.pcOf(bob);
        final snapshots = <RoomStats>[];
        final sub = bob.statsChanges.listen(snapshots.add);
        pump();
        pc.failNext('getStats', StateError('renegotiating'));
        async.elapse(const Duration(seconds: 2));
        pump();
        expect(pc.statsCalls, 5);
        expect(snapshots, hasLength(4));
        sub.cancel();
        bob.leave();
        pump();
      });
    });
  });

  group('typed stats', () {
    test('map the local publications and the pulled tracks, with rates; '
        'publications have their own streams', () {
      run((async, pump) {
        final bob = join(pump, 'bob');
        final ann = _Puppet(h, 'ann')..announce({'m': _mic});
        pump();
        late LocalMediaPublication cam;
        bob.localParticipant.publishCamera().then((p) => cam = p);
        pump();
        final annMic = bob.participant('ann')!.microphone!;
        final pullMid = annMic.subscription!.mid;
        final camMid = cam.publication.mid;
        expect(pullMid, isNotNull);
        expect(camMid, isNotNull);

        var bytes = 0;
        h.pcOf(bob).statsProvider = () => [
          ..._pair(),
          StatsReport('codec', 'codec', 0, {'mimeType': 'video/VP8'}),
          for (final (i, rid) in ['a', 'b', 'c'].indexed)
            StatsReport('out-$rid', 'outbound-rtp', 0, {
              'kind': 'video',
              'mid': camMid,
              'rid': rid,
              'encodingIndex': i,
              'codecId': 'codec',
              'bytesSent': bytes * (4 - i),
              'frameHeight': 720 >> i,
            }),
          _inboundAudio(pullMid, bytes: bytes ~/ 10),
          // A stream nobody maps.
          _inboundAudio('nope', bytes: 1),
        ];

        final camStats = <LocalTrackStats?>[];
        final micStats = <RemoteTrackStats?>[];
        final subs = [
          cam.statsChanges.listen(camStats.add),
          annMic.statsChanges.listen(micStats.add),
        ];
        pump();
        bytes = 100000;
        async.elapse(const Duration(seconds: 2));
        pump();

        final stats = bob.stats!;
        expect(
          stats.connection!.roundTripTime,
          const Duration(milliseconds: 20),
        );
        expect(stats.local.keys, [cam.trackName]);
        final local = stats.local[cam.trackName]!;
        expect(local.source, TrackSource.camera);
        expect(local.codec, 'video/VP8');
        expect([for (final l in local.layers) l.rid], ['a', 'b', 'c']);
        expect([for (final l in local.layers) l.height], [720, 360, 180]);
        // 400000 bytes in 2 s on layer a.
        expect(local.layer('a')!.bitrate, 1600000);
        expect(local.bitrate, (400000 + 300000 + 200000) * 8 ~/ 2);
        expect(stats.remote.keys, [annMic.id]);
        final remote = stats.remote[annMic.id]!;
        expect(remote.participantId, 'ann');
        expect(remote.bitrate, 40000);

        expect(camStats.last, same(local));
        expect(micStats.last, same(remote));
        expect(cam.stats, same(local));
        expect(annMic.stats, same(remote));
        for (final s in subs) {
          s.cancel();
        }
        bob.leave();
        ann.signaling.dispose();
        pump();
      });
    });

    test('a replaced session starts without rates', () {
      run((async, pump) {
        final bob = join(pump, 'bob');
        final snapshots = <RoomStats>[];
        final sub = bob.statsChanges.listen(snapshots.add);
        pump();
        async.elapse(const Duration(seconds: 2));
        pump();
        expect(snapshots.last.interval, isNotNull);
        final before = bob.session;
        bob.debugSimulateConnectionFailure();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(bob.session, isNot(same(before)), reason: 're-sessioned');
        final count = snapshots.length;
        async.elapse(const Duration(seconds: 2));
        pump();
        expect(snapshots.length, greaterThan(count));
        expect(
          snapshots[count].interval,
          isNull,
          reason: 'no rate across peer connections',
        );
        sub.cancel();
        bob.leave();
        pump();
      });
    });
  });

  group('connection quality', () {
    test('a remote participant: unknown, then rated from what arrives, '
        'lost when their media stops, and back', () {
      run((async, pump) {
        final bob = join(pump, 'bob', options: _withQuality);
        final events = <ParticipantConnectionQualityChangedEvent>[];
        bob.events
            .where((e) => e is ParticipantConnectionQualityChangedEvent)
            .cast<ParticipantConnectionQualityChangedEvent>()
            .listen(events.add);
        final ann = _Puppet(h, 'ann')..announce({'m': _mic});
        pump();
        final annP = bob.participant('ann')!;
        final mid = annP.microphone!.subscription!.mid;
        expect(annP.connectionQuality, ConnectionQuality.unknown);
        final changes = <ConnectionQuality>[];
        annP.connectionQualityChanges.listen(changes.add);

        var bytes = 0;
        var packets = 0;
        var lost = 0;
        var flowing = true;
        h.pcOf(bob).statsProvider = () => [
          ..._pair(),
          _inboundAudio(mid, bytes: bytes, packets: packets, lost: lost),
        ];
        void tick({int lostNow = 0}) {
          if (flowing) {
            bytes += 10000;
            packets += 100;
            lost += lostNow;
          }
          async.elapse(const Duration(seconds: 2));
          pump();
        }

        tick();
        tick();
        expect(annP.connectionQuality, ConnectionQuality.excellent);
        expect(
          bob.localParticipant.connectionQuality,
          ConnectionQuality.excellent,
        );

        // 10 % loss: poor after 4 s, not before.
        tick(lostNow: 11);
        expect(annP.connectionQuality, ConnectionQuality.excellent);
        tick(lostNow: 11);
        expect(annP.connectionQuality, ConnectionQuality.poor);

        // Their media stops while they are still in the room: lost after
        // 5 s without bytes.
        flowing = false;
        tick();
        tick();
        expect(annP.connectionQuality, ConnectionQuality.poor);
        tick();
        expect(annP.connectionQuality, ConnectionQuality.lost);

        // It flows again: rated at once.
        flowing = true;
        tick();
        expect(annP.connectionQuality, ConnectionQuality.excellent);

        // Muted: not measured, so not lost.
        ann.announce({'m': _mic.copyWith(muted: true)});
        pump();
        flowing = false;
        for (var i = 0; i < 5; i++) {
          tick();
        }
        expect(annP.connectionQuality, ConnectionQuality.excellent);

        expect(changes, [
          ConnectionQuality.unknown,
          ConnectionQuality.excellent,
          ConnectionQuality.poor,
          ConnectionQuality.lost,
          ConnectionQuality.excellent,
        ]);
        expect([
          for (final e in events)
            if (e.participant == annP) e.quality,
        ], changes.skip(1));
        expect(
          [
            for (final e in events)
              if (e.participant == bob.localParticipant) e.quality,
          ],
          [ConnectionQuality.excellent],
        );

        bob.leave();
        ann.signaling.dispose();
        pump();
      });
    });

    test('the local participant is lost while the room reconnects, and '
        'others unknown', () {
      run((async, pump) {
        h.autoConnect = true;
        final bob = join(
          pump,
          'bob',
          options: const RoomOptions(
            connectEarly: false,
            activeSpeaker: null,
            reconnect: ReconnectOptions(
              backoff: BackoffOptions(initialDelay: Duration(seconds: 3)),
            ),
          ),
        );
        final ann = _Puppet(h, 'ann')..announce({'m': _mic});
        pump();
        final annP = bob.participant('ann')!;
        var bytes = 0;
        h.pcOf(bob).statsProvider = () {
          bytes += 10000;
          return [
            ..._pair(),
            _inboundAudio(annP.microphone!.subscription?.mid, bytes: bytes),
          ];
        };
        async.elapse(const Duration(seconds: 4));
        pump();
        expect(
          bob.localParticipant.connectionQuality,
          ConnectionQuality.excellent,
        );
        expect(annP.connectionQuality, ConnectionQuality.excellent);

        bob.debugSimulateConnectionFailure();
        pump();
        expect(bob.connectionState, RoomConnectionState.reconnecting);
        expect(bob.localParticipant.connectionQuality, ConnectionQuality.lost);
        expect(annP.connectionQuality, ConnectionQuality.unknown);

        async.elapse(const Duration(seconds: 4));
        pump();
        expect(
          bob.connectionState,
          isNot(RoomConnectionState.reconnecting),
        );
        // The new session's stats rate everyone again.
        h.pcOf(bob).statsProvider = () {
          bytes += 10000;
          return [
            ..._pair(),
            _inboundAudio(annP.microphone!.subscription?.mid, bytes: bytes),
          ];
        };
        async.elapse(const Duration(seconds: 6));
        pump();
        expect(
          bob.localParticipant.connectionQuality,
          ConnectionQuality.excellent,
        );
        expect(annP.connectionQuality, ConnectionQuality.excellent);

        bob.leave();
        ann.signaling.dispose();
        pump();
      });
    });

    test('off: everyone stays unknown and nothing is polled', () {
      run((async, pump) {
        final bob = join(pump, 'bob');
        final ann = _Puppet(h, 'ann')..announce({'m': _mic});
        pump();
        async.elapse(const Duration(seconds: 10));
        expect(h.pcOf(bob).statsCalls, 0);
        expect(
          bob.localParticipant.connectionQuality,
          ConnectionQuality.unknown,
        );
        expect(
          bob.participant('ann')!.connectionQuality,
          ConnectionQuality.unknown,
        );
        bob.leave();
        ann.signaling.dispose();
        pump();
      });
    });

    // On real time: a StateStream's done event escapes fake_async.
    test('the streams complete when a participant leaves, and after '
        'leave', () async {
      final bob = await h.join('bob', options: _withQuality);
      final ann = _Puppet(h, 'ann')..announce({'m': _mic});
      await pumpEventQueue();
      final annLeft = Completer<void>();
      bob
          .participant('ann')!
          .connectionQualityChanges
          .listen(null, onDone: annLeft.complete);
      final statsDone = Completer<void>();
      final localDone = Completer<void>();
      bob.statsChanges.listen(null, onDone: statsDone.complete);
      bob.localParticipant.connectionQualityChanges.listen(
        null,
        onDone: localDone.complete,
      );
      await ann.signaling.leave();
      await annLeft.future.timeout(const Duration(seconds: 1));
      await bob.leave();
      await statsDone.future.timeout(const Duration(seconds: 1));
      await localDone.future.timeout(const Duration(seconds: 1));
      ann.signaling.dispose();
    });
  });
}
