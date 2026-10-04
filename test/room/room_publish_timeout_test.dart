// A publish never hangs forever (docs/design.md §4.3, Bounded publish):
// seen once on an iPhone, a microphone publish right after CallKit
// activated the audio session waited forever before its `tracks/new`. A
// capture that never answers throws a typed error; a negotiation step that
// never completes fails the session, and the room re-sessions and pushes
// the publish once more.

import 'dart:async';
import 'dart:math' as math;

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/reconnect/backoff.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/room_harness.dart';

/// Jitter at the ceiling, so every backoff delay is its upper bound.
class _MaxRandom implements math.Random {
  @override
  double nextDouble() => 1;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

const _options = RoomOptions(
  connectEarly: false,
  reconnect: ReconnectOptions(
    backoff: BackoffOptions(
      initialDelay: Duration(seconds: 1),
      maxDelay: Duration(seconds: 4),
      maxAttempts: 3,
      maxElapsed: null,
    ),
  ),
);

Duration _ms(int ms) => Duration(milliseconds: ms);

const _short = Duration(milliseconds: 50);

bool _isPush(BrokerCall call) =>
    (call.request! as TracksRequest).sessionDescription != null;

void main() {
  late RoomHarness h;

  setUp(() => Backoff.debugDefaultRandom = _MaxRandom.new);

  tearDown(() => Backoff.debugDefaultRandom = null);

  /// Runs [body] in fake time; the harness is created in the fake zone so
  /// its streams run on the fake clock. `pump` settles microtasks and
  /// zero-duration timers (the session's batching).
  void fake(void Function(FakeAsync async, void Function() pump) body) {
    fakeAsync((async) {
      h = RoomHarness();
      void pump() {
        for (var i = 0; i < 60; i++) {
          async.elapse(Duration.zero);
        }
      }

      body(async, pump);
    });
  }

  Room join(void Function() pump, String id, [RoomOptions options = _options]) {
    Room? room;
    h.join(id, options: options).then((r) => room = r);
    pump();
    return room!;
  }

  List<RoomEvent> record(Room room) {
    final events = <RoomEvent>[];
    room.events.listen(events.add);
    return events;
  }

  List<BrokerCall> pushesOf(String sessionId) => [
    for (final c in h.broker.callsTo('tracks/new'))
      if (c.sessionId == sessionId && _isPush(c)) c,
  ];

  // Real time with short bounds: a failed publish disposes its media
  // source, whose stream cancels don't complete under fake_async.
  Future<void> settle() => pumpEventQueue(times: 50);

  group('a capture that never answers', () {
    test('throws MediaCaptureException after RoomOptions.captureTimeout; '
        'the room stays usable and the late track is released', () async {
      h = RoomHarness();
      final alice = await h.join(
        'alice',
        options: const RoomOptions(
          connectEarly: false,
          captureTimeout: Duration(milliseconds: 50),
        ),
      );
      final gate = h.media.userMediaGate = Completer<void>();
      final watch = Stopwatch()..start();
      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(
          isA<MediaCaptureException>().having(
            (e) => e.cause,
            'cause',
            isA<TimeoutException>(),
          ),
        ),
      );
      expect(watch.elapsed, greaterThanOrEqualTo(_ms(50)));
      expect(alice.localParticipant.trackPublications, isEmpty);
      expect(h.broker.callsTo('tracks/new'), isEmpty);
      await settle();
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(alice.connectionState, isNot(RoomConnectionState.disconnected));

      // The platform answers late: the track is stopped at once.
      gate.complete();
      await settle();
      final late = h.media.streams.single;
      expect(late.disposed, isTrue);
      expect(late.track.stopped, isTrue);

      // A retry publishes.
      final mic = await alice.localParticipant.publishMicrophone();
      expect(mic.publication.state, SfuTrackState.active);
      await settle();
      expect(h.announced('alice')!.tracks.keys, [mic.trackName]);
      await alice.leave();
    });

    test('the default is 30 s', () {
      expect(const RoomOptions().captureTimeout, const Duration(seconds: 30));
    });
  });

  group('a negotiation step that never completes', () {
    test('fails the session; the publish completes on the new session', () {
      fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = record(alice);
        final first = alice.session;
        final stuck = h.pcOf(alice).hangNext('setLocalDescription');
        h.autoConnect = true;

        LocalMediaPublication? mic;
        Object? error;
        alice.localParticipant.publishMicrophone().then(
          (p) {
            mic = p;
          },
          onError: (Object e) {
            error = e;
          },
        );
        pump();
        async.elapse(const Duration(seconds: 59));
        pump();
        expect(mic, isNull);
        expect(alice.isReconnecting, isFalse);

        async.elapse(const Duration(seconds: 1)); // The negotiation timeout.
        pump();
        expect(
          events.whereType<RoomSessionFailedEvent>().single.failure,
          isA<SfuPeerConnectionFailed>().having(
            (f) => f.kind,
            'kind',
            PeerConnectionFailureKind.negotiationTimeout,
          ),
        );
        expect(alice.isReconnecting, isTrue);

        async.elapse(const Duration(seconds: 1)); // The backoff delay.
        pump();
        expect(error, isNull);
        final second = alice.session;
        expect(second, isNot(same(first)));
        expect(first.isClosed, isTrue);
        expect(mic!.publication.session, same(second));
        expect(mic!.publication.state, SfuTrackState.active);
        expect(pushesOf(first.sessionId), isEmpty);
        expect(pushesOf(second.sessionId), hasLength(1));
        expect(h.media.userMediaCalls, hasLength(1), reason: 'one capture');
        expect(h.announced('alice')!.sessionId, second.sessionId);
        expect(h.announced('alice')!.tracks.keys, [mic!.trackName]);

        // The stuck step completing late changes nothing.
        stuck.complete();
        pump();
        expect(pushesOf(first.sessionId), isEmpty);
        expect(alice.session, same(second));

        alice.leave();
        pump();
      });
    });

    test('a re-session whose peer connection is not created in time tries '
        'again; the publish still completes', () {
      fake((async, pump) {
        final alice = join(pump, 'alice');
        h.pcOf(alice).hangNext('createOffer');
        h.autoConnect = true;
        // The re-session's first peer connection never comes.
        h.sessions.peerConnections.hangNextCreate = Completer<void>();

        LocalMediaPublication? mic;
        Object? error;
        alice.localParticipant.publishMicrophone().then(
          (p) {
            mic = p;
          },
          onError: (Object e) {
            error = e;
          },
        );
        pump();
        async.elapse(const Duration(seconds: 60)); // The stuck createOffer.
        pump();
        async.elapse(const Duration(seconds: 1)); // Backoff.
        pump();
        expect(mic, isNull);
        async.elapse(const Duration(seconds: 60)); // The stuck create.
        pump();
        async.elapse(const Duration(seconds: 4)); // Backoff.
        pump();

        expect(error, isNull);
        expect(mic?.publication.state, SfuTrackState.active);
        expect(alice.connectionState, RoomConnectionState.connected);
        // The join, the attempt whose peer connection never came, the next.
        expect(h.connectAttempts, 3);
        expect(h.sessions.peerConnections.created, hasLength(2));

        alice.leave();
        pump();
      });
    });

    test('with automatic reconnection off, the publish throws a typed '
        'error instead of waiting', () async {
      h = RoomHarness();
      final alice = await h.join(
        'alice',
        options: const RoomOptions(
          connectEarly: false,
          reconnect: ReconnectOptions(enabled: false),
          sessionOptions: SfuSessionOptions(negotiationTimeout: _short),
        ),
      );
      h.pcOf(alice).hangNext('addTransceiver');
      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(
          isA<SfuSessionFailedException>().having(
            (e) => (e.failure as SfuPeerConnectionFailed).kind,
            'kind',
            PeerConnectionFailureKind.negotiationTimeout,
          ),
        ),
      );
      // The capture the room made for it is released.
      expect(h.media.streams.single.disposed, isTrue);
      expect(alice.localParticipant.trackPublications, isEmpty);
      expect(alice.connectionState, RoomConnectionState.disconnected);
      await alice.leave();
    });
  });
}
