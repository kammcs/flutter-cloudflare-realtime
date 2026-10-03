import 'dart:async';
import 'dart:math' as math;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/reconnect/backoff.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

import '../support/room_harness.dart';

const _mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);

/// Jitter at the ceiling, so every backoff delay is its upper bound.
class _MaxRandom implements math.Random {
  @override
  double nextDouble() => 1;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

/// Delays of 1 s, 2 s, then 4 s; three attempts per episode.
const _options = RoomOptions(
  connectEarly: false,
  reconnect: ReconnectOptions(
    backoff: BackoffConfig(
      initialDelay: Duration(seconds: 1),
      maxDelay: Duration(seconds: 4),
      maxAttempts: 3,
      maxElapsed: null,
    ),
  ),
);

const _failed = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _connecting = RTCPeerConnectionState.RTCPeerConnectionStateConnecting;
const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
const _disconnected = RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;

List<RoomEvent> _record(Room room) {
  final events = <RoomEvent>[];
  room.events.listen(events.add);
  return events;
}

/// A [Signaling] whose updates fail on demand.
class _FlakySignaling implements Signaling {
  _FlakySignaling(InMemorySignalingHub hub) : _inner = InMemorySignaling(hub);

  final InMemorySignaling _inner;
  bool failUpdates = false;

  @override
  Future<void> join(String roomId, ParticipantState self) =>
      _inner.join(roomId, self);

  @override
  Future<void> update(ParticipantState self) async {
    if (failUpdates) throw StateError('presence is down');
    await _inner.update(self);
  }

  @override
  Stream<List<ParticipantState>> get participants => _inner.participants;

  @override
  Future<void> leave() => _inner.leave();
}

/// Runs [body] in fake time, with `pump` to settle microtasks and
/// zero-duration timers (the session's batching).
void _fake(void Function(FakeAsync async, void Function() pump) body) {
  fakeAsync((async) {
    void pump() {
      for (var i = 0; i < 60; i++) {
        async.elapse(Duration.zero);
      }
    }

    body(async, pump);
  });
}

void main() {
  late RoomHarness h;

  setUp(() {
    h = RoomHarness();
    Backoff.debugDefaultRandom = _MaxRandom.new;
  });

  tearDown(() => Backoff.debugDefaultRandom = null);

  /// Joins [id] and returns the room once joined.
  Room join(
    void Function() pump,
    String id, {
    RoomOptions options = _options,
    Signaling? signaling,
  }) {
    Room? room;
    h.join(id, options: options, signaling: signaling).then((r) => room = r);
    pump();
    return room!;
  }

  T wait<T>(void Function() pump, Future<T> future) {
    late T value;
    var done = false;
    future.then((v) {
      value = v;
      done = true;
    });
    pump();
    expect(done, isTrue, reason: 'the future should have completed');
    return value;
  }

  group('re-session', () {
    test('a failed peer connection re-sessions: same track names and '
        'tracks, the new session announced, subscriptions pulled again, no '
        'capture restart', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final bob = join(pump, 'bob');
        final mic = wait(pump, alice.localParticipant.publishMicrophone());
        final cam = wait(pump, alice.localParticipant.publishCamera());
        final bobMic = wait(pump, bob.localParticipant.publishMicrophone());
        final bobAliceCam = bob.participant('alice')!.camera!;
        wait(pump, bobAliceCam.subscribe());
        final aliceBobMic = alice.participant('bob')!.microphone!;
        expect(aliceBobMic.currentTrack, isNotNull);

        final events = _record(alice);
        final states = <RoomConnectionState>[];
        alice.connectionState.listen(states.add);
        pump();
        final oldSession = alice.session;
        final oldPc = h.pcOf(alice);
        final micTrack = mic.publication.track;
        final camTrack = cam.publication.track;
        final captures = h.media.userMediaCalls.length;
        final oldBobPull = aliceBobMic.currentTrack!;

        oldPc.emitConnectionState(_failed);
        pump();
        expect(alice.currentConnectionState, RoomConnectionState.reconnecting);
        expect(alice.isReconnecting, isTrue);
        expect(
          events.whereType<RoomSessionFailedEvent>().single.failure,
          isA<SfuPeerConnectionFailed>(),
        );
        expect(
          events.whereType<RoomReconnectingEvent>().single.reason,
          ReconnectReason.peerConnectionFailed,
        );
        expect(
          alice.session,
          same(oldSession),
          reason: 'the first attempt waits for its backoff delay',
        );

        async.elapse(const Duration(seconds: 1));
        pump();
        final session = alice.session;
        expect(session, isNot(same(oldSession)));
        expect(oldSession.isClosed, isTrue);
        expect(oldPc.closed, isTrue);
        expect(alice.failure, isNull);

        // Tracks are on the new session, but its peer connection is still
        // `new`: the room stays reconnecting until it connects, rather than
        // showing connected, connecting, connected.
        expect(alice.isReconnecting, isTrue);
        expect(alice.currentConnectionState, RoomConnectionState.reconnecting);
        expect(events.whereType<RoomReconnectedEvent>(), isEmpty);
        h.pcOf(alice).emitConnectionState(_connecting);
        pump();
        expect(alice.currentConnectionState, RoomConnectionState.reconnecting);
        h.pcOf(alice).emitConnectionState(_connected);
        pump();
        expect(alice.isReconnecting, isFalse);
        expect(alice.currentConnectionState, RoomConnectionState.connected);
        final reconnected = events.whereType<RoomReconnectedEvent>().single;
        expect(reconnected.reason, ReconnectReason.peerConnectionFailed);
        expect(reconnected.attempts, 1);
        expect(reconnected.duration, const Duration(seconds: 1));
        expect(states, [
          RoomConnectionState.connected,
          RoomConnectionState.reconnecting,
          RoomConnectionState.connected,
        ]);

        // The same publications, names and tracks, on the new session.
        for (final (p, track) in [(mic, micTrack), (cam, camTrack)]) {
          expect(p.publication.session, same(session));
          expect(p.publication.state, SfuTrackState.active);
          expect(p.publication.track, same(track));
        }
        final pushed = [
          for (final call in h.callsOf(alice, 'tracks/new'))
            if ((call.request! as TracksRequest).sessionDescription != null)
              for (final t in (call.request! as TracksRequest).tracks)
                t.trackName,
        ];
        expect(pushed, unorderedEquals([mic.trackName, cam.trackName]));
        final newPc = h.pcOf(alice);
        expect([
          for (final t in newPc.transceivers)
            if (t.direction == 'sendonly') t.sentTrack,
        ], unorderedEquals([micTrack, camTrack]));
        expect(h.media.userMediaCalls, hasLength(captures));
        expect(h.media.streams.any((s) => s.track.stopped), isFalse);
        expect(mic.mediaSource.isDisposed, isFalse);

        // Announced with the new session.
        final announced = h.announced('alice')!;
        expect(announced.sessionId, session.sessionId);
        expect(announced.tracks.keys, [mic.trackName, cam.trackName]);

        // Alice pulls Bob's microphone again, on her new session.
        expect(
          h.pullsOf(alice),
          contains('${bob.session.sessionId}/${bobMic.trackName}'),
        );
        expect(aliceBobMic.subscription!.session, same(session));
        expect(aliceBobMic.subscriptionState, SfuTrackState.active);
        expect(aliceBobMic.currentTrack, isNot(same(oldBobPull)));

        // Bob follows Alice to her new session.
        expect(bob.participant('alice')!.sessionId, session.sessionId);
        expect(
          h.pullsOf(bob),
          contains('${session.sessionId}/${cam.trackName}@b'),
        );
        expect(bobAliceCam.subscription!.remoteSessionId, session.sessionId);
        expect(bobAliceCam.subscriptionState, SfuTrackState.active);

        alice.leave();
        bob.leave();
        pump();
      });
    });

    test(
      'disconnected past the timeout re-sessions; a short blip does not',
      () {
        _fake((async, pump) {
          final alice = join(pump, 'alice');
          final events = _record(alice);
          final pc = h.pcOf(alice);
          final attempts = h.connectAttempts;

          pc
            ..emitConnectionState(_connecting)
            ..emitConnectionState(_connected)
            ..emitConnectionState(_disconnected);
          pump();
          expect(
            alice.currentConnectionState,
            RoomConnectionState.reconnecting,
          );
          async.elapse(const Duration(seconds: 4));
          pc.emitConnectionState(_connected);
          pump();
          async.elapse(const Duration(seconds: 30));
          pump();
          expect(alice.currentConnectionState, RoomConnectionState.connected);
          expect(events.whereType<RoomReconnectingEvent>(), isEmpty);
          expect(h.connectAttempts, attempts);

          pc.emitConnectionState(_disconnected);
          pump();
          async.elapse(const Duration(seconds: 5));
          pump();
          expect(
            events.whereType<RoomReconnectingEvent>().single.reason,
            ReconnectReason.disconnectedTooLong,
          );
          async.elapse(const Duration(seconds: 1));
          pump();
          expect(h.connectAttempts, attempts + 1);
          expect(pc.closed, isTrue, reason: 'the old session was closed');
          expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
          expect(alice.currentConnectionState, RoomConnectionState.connected);
          alice.leave();
          pump();
        });
      },
    );

    test('a 410 on an SFU call re-sessions', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final original = h.broker.onNewTracks!;
        final goneSession = alice.session.sessionId;
        // Our session is gone for the SFU: the confirmation says so too.
        h.broker.goneSessions.add(goneSession);
        h.broker.onNewTracks = (sessionId, request) async {
          if (sessionId == goneSession) {
            throw SessionGoneException(
              operation: 'tracks/new',
              sessionId: sessionId,
              statusCode: 410,
              errorCode: 'session_error',
            );
          }
          return original(sessionId, request);
        };

        h.broker.trackKinds['dave-1/dave-mic'] = 'audio';
        final dave = InMemorySignaling(h.hub);
        dave.join(
          'room',
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-1',
            tracks: const {'dave-mic': _mic},
          ),
        );
        pump();
        expect(alice.failure, isA<SfuSessionGone>());
        expect(
          events.whereType<RoomReconnectingEvent>().single.reason,
          ReconnectReason.sessionGone,
        );
        final failed = events.whereType<TrackSubscriptionFailedEvent>();
        expect([for (final e in failed) e.willRetry], [false]);

        async.elapse(const Duration(seconds: 1));
        pump();
        expect(alice.session.sessionId, isNot(goneSession));
        expect(h.pullsOf(alice), ['dave-1/dave-mic']);
        final daveMic = alice.participant('dave')!.microphone!;
        expect(daveMic.subscriptionState, SfuTrackState.active);
        expect(daveMic.currentTrack, isNotNull);
        alice.leave();
        dave.dispose();
        pump();
      });
    });

    test('a pull from a publisher session that is gone keeps our session: '
        'the pull backs off, and follows the publisher to a new session', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final session = alice.session;
        final attempts = h.connectAttempts;
        final original = h.broker.onNewTracks!;
        // The SFU answers a pull naming dave's expired session with a
        // request-level session_error, which the broker client maps to the
        // session in the path: ours.
        h.broker.onNewTracks = (sessionId, request) async {
          if (request.tracks.any((t) => t.sessionId == 'dave-old')) {
            throw SessionGoneException(
              operation: 'tracks/new',
              sessionId: sessionId,
              statusCode: 410,
              errorCode: 'session_error',
            );
          }
          return original(sessionId, request);
        };

        h.broker
          ..trackKinds['dave-old/dave-mic'] = 'audio'
          ..trackKinds['dave-new/dave-mic'] = 'audio';
        final dave = InMemorySignaling(h.hub);
        dave.join(
          'room',
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-old',
            tracks: const {'dave-mic': _mic},
          ),
        );
        pump();

        // Our session was confirmed alive, so only the pull failed.
        expect(
          h.broker.callsTo('sessions/{id}').single.sessionId,
          session.sessionId,
        );
        expect(alice.failure, isNull);
        expect(alice.session, same(session));
        expect(events.whereType<RoomSessionFailedEvent>(), isEmpty);
        expect(events.whereType<RoomReconnectingEvent>(), isEmpty);
        expect(alice.currentConnectionState, RoomConnectionState.connected);
        final daveMic = alice.participant('dave')!.microphone!;
        expect(daveMic.error, isA<SfuTrackException>());
        final failure = events.whereType<TrackSubscriptionFailedEvent>().single;
        expect(failure.willRetry, isTrue);
        expect(
          failure.error,
          isA<SfuTrackException>().having(
            (e) => e.errorCode,
            'errorCode',
            'session_error',
          ),
        );

        // The retries fail the same way, and never re-session.
        async.elapse(const Duration(seconds: 30));
        pump();
        expect(
          events.whereType<TrackSubscriptionFailedEvent>().length,
          greaterThan(1),
        );
        expect(alice.session, same(session));
        expect(h.connectAttempts, attempts);
        expect(events.whereType<RoomReconnectingEvent>(), isEmpty);

        // Dave comes back on a new session: pulled from there at once.
        dave.update(
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-new',
            tracks: const {'dave-mic': _mic},
          ),
        );
        pump();
        expect(daveMic.subscriptionState, SfuTrackState.active);
        expect(daveMic.currentTrack, isNotNull);
        expect(h.pullsOf(alice).last, 'dave-new/dave-mic');
        expect(alice.session, same(session));
        alice.leave();
        dave.dispose();
        pump();
      });
    });

    test('a network change while disconnected re-sessions at once; while '
        'connected it only shortens the wait', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final pc = h.pcOf(alice);
        pc
          ..emitConnectionState(_connecting)
          ..emitConnectionState(_connected);
        pump();

        h.network.change();
        pump();
        async.elapse(const Duration(seconds: 30));
        pump();
        expect(events.whereType<RoomReconnectingEvent>(), isEmpty);

        pc.emitConnectionState(_disconnected);
        pump();
        h.network.change();
        pump();
        expect(
          events.whereType<RoomReconnectingEvent>().single.reason,
          ReconnectReason.networkChanged,
        );
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));

        // Within the window after a change, a drop re-sessions at once.
        final next = h.pcOf(alice);
        next
          ..emitConnectionState(_connecting)
          ..emitConnectionState(_connected);
        async.elapse(const Duration(seconds: 20));
        h.network.change();
        next.emitConnectionState(_disconnected);
        pump();
        expect(events.whereType<RoomReconnectingEvent>(), hasLength(2));
        alice.leave();
        pump();
      });
    });

    test('returning from the background past the threshold re-sessions', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);

        h.lifecycle.emit(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 10));
        h.lifecycle.emit(AppLifecycleState.resumed);
        pump();
        expect(events.whereType<RoomReconnectingEvent>(), isEmpty);

        h.lifecycle.emit(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 31));
        h.lifecycle.emit(AppLifecycleState.resumed);
        pump();
        expect(
          events.whereType<RoomReconnectingEvent>().single.reason,
          ReconnectReason.resumedFromBackground,
        );
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
        alice.leave();
        pump();
      });
    });

    test('DataChannels are republished and resubscribed, and peers follow', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final bob = join(pump, 'bob');
        final dave = InMemorySignaling(h.hub);
        dave.join(
          'room',
          ParticipantState(participantId: 'dave', sessionId: 'dave-1'),
        );
        pump();

        final chat = wait(pump, alice.data.publish('chat'));
        final bobChat = wait(
          pump,
          bob.data.subscribe(bob.participant('alice')!, 'chat'),
        );
        final status = wait(
          pump,
          alice.data.subscribe(alice.participant('dave')!, 'status'),
        );
        final statusChannel = status.channel;

        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        expect(chat.state, SfuDataChannelState.interrupted);
        async.elapse(const Duration(seconds: 1));
        pump();

        final session = alice.session;
        expect(chat.session, same(session));
        expect(chat.name, 'chat');
        expect(status.channel, same(statusChannel), reason: 'moved, not new');
        expect(status.channel.session, same(session));
        expect(status.channel.remoteSessionId, 'dave-1');
        expect(bobChat.channel.remoteSessionId, session.sessionId);
        final opened = [
          for (final call in h.callsOf(alice, 'datachannels/new'))
            for (final d in (call.request! as DataChannelsRequest).dataChannels)
              '${d.location?.name}:${d.dataChannelName}',
        ];
        expect(opened, unorderedEquals(['local:chat', 'remote:status']));
        alice.leave();
        bob.leave();
        dave.dispose();
        pump();
      });
    });
  });

  group('attempts', () {
    test('back off between failed attempts, give up, and reconnect() '
        'tries again', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final base = h.connectAttempts;
        const offline = BrokerNetworkException(operation: 'sessions/new');
        h.connectError = offline;

        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        // Delays of 1 s, 2 s and 4 s: attempts at 1 s, 3 s and 7 s.
        for (final (at, count) in [
          (999, 0),
          (1000, 1),
          (2999, 1),
          (3000, 2),
          (6999, 2),
          (7000, 3),
        ]) {
          async.elapse(Duration(milliseconds: at) - async.elapsed);
          pump();
          expect(h.connectAttempts - base, count, reason: 'at $at ms');
        }
        final failed = events.whereType<RoomReconnectFailedEvent>().single;
        expect(failed.attempts, 3);
        expect(failed.error, offline);
        expect(failed.reason, ReconnectReason.peerConnectionFailed);
        expect(events.whereType<RoomErrorEvent>().map((e) => e.operation), [
          'reconnect',
          'reconnect',
          'reconnect',
        ]);
        expect(
          [
            for (final e in events.whereType<RoomReconnectAttemptEvent>())
              (e.reason, e.attempt, e.delay, e.waited),
          ],
          [
            for (final (n, s) in [(1, 1), (2, 2), (3, 4)])
              (
                ReconnectReason.peerConnectionFailed,
                n,
                Duration(seconds: s),
                Duration(seconds: s),
              ),
          ],
        );
        expect(alice.currentConnectionState, RoomConnectionState.disconnected);
        expect(alice.isReconnecting, isFalse);
        async.elapse(const Duration(minutes: 5));
        pump();
        expect(h.connectAttempts - base, 3, reason: 'gave up');
        expect(h.announced('alice'), isNotNull, reason: 'still in signaling');

        h.connectError = null;
        final result = wait(pump, alice.reconnect());
        expect(result, isTrue);
        expect(h.connectAttempts - base, 4, reason: 'no delay when asked');
        expect(alice.currentConnectionState, RoomConnectionState.connected);
        final reconnected = events.whereType<RoomReconnectedEvent>().single;
        expect(reconnected.reason, ReconnectReason.manual);
        expect(reconnected.attempts, 1);
        final manual = events.whereType<RoomReconnectAttemptEvent>().last;
        expect(manual.reason, ReconnectReason.manual);
        expect(manual.attempt, 1);
        expect(manual.delay, Duration.zero);
        expect(manual.waited, Duration.zero);
        expect(h.announced('alice')!.sessionId, alice.session.sessionId);
        alice.leave();
        pump();
      });
    });

    test('a network change while offline cuts the backoff wait short', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final base = h.connectAttempts;
        h.connectError = const BrokerNetworkException(
          operation: 'sessions/new',
        );
        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(h.connectAttempts - base, 1);

        // Attempt 2 would wait 2 s; the network comes back after 0.5 s.
        h.connectError = null;
        async.elapse(const Duration(milliseconds: 500));
        pump();
        expect(h.connectAttempts - base, 1);
        h.network.change();
        pump();
        expect(h.connectAttempts - base, 2, reason: 'retried at once');
        final second = events.whereType<RoomReconnectAttemptEvent>().last;
        expect(second.attempt, 2);
        expect(second.delay, const Duration(seconds: 2));
        expect(second.waited, const Duration(milliseconds: 500));
        h.pcOf(alice).emitConnectionState(_connected);
        pump();
        expect(alice.currentConnectionState, RoomConnectionState.connected);
        expect(events.whereType<RoomReconnectedEvent>().single.attempts, 2);
        alice.leave();
        pump();
      });
    });

    test('after giving up, a network change tries again', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        h.connectError = const BrokerNetworkException(operation: 'x');
        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 7));
        pump();
        expect(events.whereType<RoomReconnectFailedEvent>(), hasLength(1));

        h.connectError = null;
        h.network.change();
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(
          events.whereType<RoomReconnectedEvent>().single.reason,
          ReconnectReason.networkChanged,
        );
        alice.leave();
        pump();
      });
    });

    test('reconnect() on a healthy room replaces the session; works with '
        'automatic reconnection off', () {
      _fake((async, pump) {
        final alice = join(
          pump,
          'alice',
          options: const RoomOptions(
            connectEarly: false,
            reconnect: ReconnectOptions.disabled,
          ),
        );
        final events = _record(alice);
        final mic = wait(pump, alice.localParticipant.publishMicrophone());
        final first = alice.session;
        // New sessions connect once their tracks are on them.
        h.autoConnect = true;

        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        async.elapse(const Duration(minutes: 1));
        pump();
        expect(alice.currentConnectionState, RoomConnectionState.disconnected);
        expect(events.whereType<RoomReconnectingEvent>(), isEmpty);

        expect(wait(pump, alice.reconnect()), isTrue);
        final second = alice.session;
        expect(second, isNot(same(first)));
        expect(mic.publication.session, same(second));

        expect(wait(pump, alice.reconnect()), isTrue);
        expect(alice.session, isNot(same(second)));
        expect(second.isClosed, isTrue);
        expect(mic.publication.session, same(alice.session));
        expect(events.whereType<RoomReconnectedEvent>().map((e) => e.reason), [
          ReconnectReason.manual,
          ReconnectReason.manual,
        ]);
        alice.leave();
        pump();
      });
    });

    test('a new session that fails during the attempt is replaced by the '
        'next attempt', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final mic = wait(pump, alice.localParticipant.publishMicrophone());
        final first = alice.session.sessionId;
        final original = h.broker.onNewTracks!;
        var failPush = true;
        h.broker.onNewTracks = (sessionId, request) async {
          if (failPush &&
              sessionId != first &&
              request.sessionDescription != null) {
            failPush = false;
            throw const BrokerNetworkException(operation: 'tracks/new');
          }
          return original(sessionId, request);
        };
        h.autoConnect = true;

        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 1));
        pump();
        final broken = h.sessions.peerConnections.last;
        expect(broken.closed, isTrue, reason: 'the failed attempt closed it');
        expect(alice.isReconnecting, isTrue);
        expect(
          events.whereType<RoomErrorEvent>().single.error,
          isA<BrokerNetworkException>(),
        );

        async.elapse(const Duration(seconds: 2));
        pump();
        expect(events.whereType<RoomReconnectedEvent>().single.attempts, 2);
        expect(mic.publication.session, same(alice.session));
        expect(mic.publication.state, SfuTrackState.active);
        expect(h.announced('alice')!.tracks.keys, [mic.trackName]);
        alice.leave();
        pump();
      });
    });

    test('a new session with tracks whose peer connection never leaves new '
        'fails the attempt after the connect timeout', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final mic = wait(pump, alice.localParticipant.publishMicrophone());

        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 1));
        pump();
        final stuck = h.pcOf(alice);
        expect(mic.publication.session, same(alice.session));
        expect(alice.currentConnectionState, RoomConnectionState.reconnecting);

        async.elapse(const Duration(seconds: 14));
        pump();
        expect(alice.isReconnecting, isTrue);
        expect(events.whereType<RoomErrorEvent>(), isEmpty);

        // 15 s: ReconnectTriggerConfig.connectTimeout.
        h.autoConnect = true;
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(stuck.closed, isTrue);
        expect(
          events.whereType<RoomErrorEvent>().single.error,
          isA<SfuSessionException>(),
        );

        async.elapse(const Duration(seconds: 2));
        pump();
        final reconnected = events.whereType<RoomReconnectedEvent>().single;
        expect(reconnected.attempts, 2);
        expect(alice.currentConnectionState, RoomConnectionState.connected);
        expect(mic.publication.state, SfuTrackState.active);
        alice.leave();
        pump();
      });
    });

    test('a new session with nothing on it is connected at once', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final states = <RoomConnectionState>[];
        alice.connectionState.listen(states.add);
        pump();

        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(h.pcOf(alice).connectionState, isNot(_connected));
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
        expect(states, [
          RoomConnectionState.connected,
          RoomConnectionState.reconnecting,
          RoomConnectionState.connected,
        ]);
        alice.leave();
        pump();
      });
    });

    test('triggers during a reconnection coalesce into it', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final base = h.connectAttempts;

        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        final first = alice.reconnect();
        final second = alice.reconnect();
        expect(second, same(first));
        pump();
        expect(
          h.connectAttempts - base,
          1,
          reason: 'reconnect() skips the wait',
        );
        expect(wait(pump, first), isTrue);
        async.elapse(const Duration(seconds: 30));
        pump();
        expect(h.connectAttempts - base, 1);
        expect(events.whereType<RoomReconnectingEvent>(), hasLength(1));
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
        alice.leave();
        pump();
      });
    });

    test('a failing signaling update is retried with backoff', () {
      _fake((async, pump) {
        final signaling = _FlakySignaling(h.hub);
        final alice = join(pump, 'alice', signaling: signaling);
        final events = _record(alice);

        h.pcOf(alice).emitConnectionState(_failed);
        signaling.failUpdates = true;
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(alice.isReconnecting, isTrue);
        expect(events.whereType<RoomErrorEvent>().map((e) => e.operation), [
          'signaling.update',
        ]);
        expect(h.announced('alice')!.sessionId, isNot(alice.session.sessionId));

        signaling.failUpdates = false;
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
        expect(h.announced('alice')!.sessionId, alice.session.sessionId);
        alice.leave();
        pump();
      });
    });

    test('a session that breaks again soon continues the backoff', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final base = h.connectAttempts;

        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(h.connectAttempts - base, 1);

        // Within the stable period: the next delay is 2 s, not 1 s.
        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(milliseconds: 1999));
        pump();
        expect(h.connectAttempts - base, 1);
        async.elapse(const Duration(milliseconds: 1));
        pump();
        expect(h.connectAttempts - base, 2);

        // After it: 1 s again.
        async.elapse(const Duration(seconds: 11));
        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(h.connectAttempts - base, 3);
        alice.leave();
        pump();
      });
    });
  });

  group('while reconnecting', () {
    test('leave() during the backoff wait stops it', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final base = h.connectAttempts;
        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        wait(pump, alice.leave());
        async.elapse(const Duration(minutes: 1));
        pump();
        expect(h.connectAttempts, base);
        expect(alice.currentConnectionState, RoomConnectionState.disconnected);
        expect(h.announced('alice'), isNull);
      });
    });

    test('leave() while a new session connects closes it', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        final gate = h.connectGate = Completer<void>();
        h.pcOf(alice).emitConnectionState(_failed);
        async.elapse(const Duration(seconds: 1));
        pump();
        final old = alice.session;

        wait(pump, alice.leave());
        gate.complete();
        pump();
        final late = h.sessions.peerConnections.last;
        expect(late.closed, isTrue);
        expect(alice.session, same(old), reason: 'never switched');
        expect(h.broker.forgotten, contains(old.sessionId));
        expect(h.broker.forgotten, hasLength(2));
        expect(events.whereType<RoomReconnectedEvent>(), isEmpty);
        expect(h.announced('alice'), isNull);
        async.elapse(const Duration(minutes: 1));
        pump();
      });
    });

    test('publishing waits for the new session', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        h.autoConnect = true;
        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        LocalMediaPublication? mic;
        alice.localParticipant.publishMicrophone().then((p) => mic = p);
        pump();
        expect(mic, isNull);
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(mic!.publication.session, same(alice.session));
        expect(h.announced('alice')!.tracks.keys, [mic!.trackName]);
        // The re-session connected the new session for the waiting publish
        // before it was pushed (docs/design.md §8.1, Publishing late), even
        // with RoomOptions.connectEarly off.
        expect(
          [
            for (final c in h.broker.calls)
              if (c.sessionId == alice.session.sessionId) c.operation,
          ],
          ['datachannels/establish', 'renegotiate', 'tracks/new'],
        );
        alice.leave();
        pump();
      });
    });

    test('remote publishers moving during the outage are pulled once, from '
        'their current session, without retries', () {
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        final events = _record(alice);
        h.broker.trackKinds['dave-1/dave-mic'] = 'audio';
        h.broker.trackKinds['dave-2/dave-mic'] = 'audio';
        final dave = InMemorySignaling(h.hub);
        dave.join(
          'room',
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-1',
            tracks: const {'dave-mic': _mic},
          ),
        );
        pump();
        expect(h.pullsOf(alice), ['dave-1/dave-mic']);

        h.pcOf(alice).emitConnectionState(_failed);
        pump();
        dave.update(
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-2',
            tracks: const {'dave-mic': _mic},
          ),
        );
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(h.pullsOf(alice), ['dave-2/dave-mic']);
        expect(events.whereType<TrackSubscriptionFailedEvent>(), isEmpty);
        final daveMic = alice.participant('dave')!.microphone!;
        expect(daveMic.subscription!.remoteSessionId, 'dave-2');
        expect(daveMic.subscriptionState, SfuTrackState.active);
        async.elapse(const Duration(minutes: 1));
        pump();
        expect(h.pullsOf(alice), hasLength(1), reason: 'no retries');
        alice.leave();
        dave.dispose();
        pump();
      });
    });

    test('pull retries while a publisher\'s new session serves nothing yet '
        'add no transceivers, mids or subscriptions', () {
      // Seen on devices: a phone re-sessioned and announced its new session
      // before its peer connection was up (its Wi-Fi was gone; it later
      // fell over to cellular). The subscriber pulled each track again and
      // again, every pull a 200 with no renegotiation, until the phone's
      // media path came up. The SFU answers such a pull with a per-track
      // error (`not_found_track_error`, no mid). Each retry must leave
      // nothing behind on the subscriber's session.
      _fake((async, pump) {
        final alice = join(pump, 'alice');
        const cam = TrackInfo(
          kind: TrackKind.video,
          source: TrackSource.camera,
        );
        h.broker.trackKinds['dave-1/dave-mic'] = 'audio';
        h.broker.trackKinds['dave-2/dave-mic'] = 'audio';
        final dave = InMemorySignaling(h.hub);
        dave.join(
          'room',
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-1',
            tracks: const {'dave-mic': _mic, 'dave-cam': cam},
          ),
        );
        pump();
        final daveCam = alice.participant('dave')!.camera!;
        wait(pump, daveCam.subscribe());
        final daveMic = alice.participant('dave')!.microphone!;
        expect(daveMic.subscriptionState, SfuTrackState.active);
        final pc = h.pcOf(alice);
        expect(pc.transceivers, hasLength(2));

        // Dave's new session answers not_found_track_error six times per
        // track; the seventh pull of each works.
        final failuresLeft = {'dave-mic': 6, 'dave-cam': 6};
        final pulledMids = [
          daveMic.subscription!.mid!,
          daveCam.subscription!.mid!,
        ];
        final sfu = h.broker.onNewTracks!;
        h.broker.onNewTracks = (sessionId, request) async {
          final isPull = request.sessionDescription == null;
          if (isPull &&
              request.tracks.every(
                (t) =>
                    t.sessionId == 'dave-2' && failuresLeft[t.trackName]! > 0,
              )) {
            for (final t in request.tracks) {
              failuresLeft[t.trackName!] = failuresLeft[t.trackName]! - 1;
            }
            return TracksResponse(
              tracks: [
                for (final t in request.tracks)
                  TrackResult(
                    location: TrackLocation.remote,
                    sessionId: t.sessionId,
                    trackName: t.trackName,
                    errorCode: 'not_found_track_error',
                    errorDescription:
                        'Make sure the publisher peer is connected and '
                        'sending packets for this track',
                  ),
              ],
            );
          }
          final response = await sfu(sessionId, request);
          if (isPull) {
            pulledMids.addAll([
              for (final r in response.tracks)
                if (r.mid != null && !r.hasError) r.mid!,
            ]);
          }
          return response;
        };
        final events = _record(alice);

        dave.update(
          ParticipantState(
            participantId: 'dave',
            sessionId: 'dave-2',
            tracks: const {'dave-mic': _mic, 'dave-cam': cam},
          ),
        );
        pump();
        async.elapse(const Duration(seconds: 30));
        pump();

        final fromNew = [
          for (final p in h.pullsOf(alice))
            if (p.startsWith('dave-2/')) p,
        ];
        expect(
          fromNew.where((p) => p.startsWith('dave-2/dave-mic')),
          hasLength(7),
        );
        expect(
          fromNew.where((p) => p.startsWith('dave-2/dave-cam')),
          hasLength(7),
        );
        expect(events.whereType<TrackSubscriptionFailedEvent>(), hasLength(12));
        expect(failuresLeft.values, everyElement(lessThanOrEqualTo(0)));

        // Both tracks are pulled from Dave's new session, once each.
        expect(daveMic.subscriptionState, SfuTrackState.active);
        expect(daveCam.subscriptionState, SfuTrackState.active);
        expect(daveMic.subscription!.remoteSessionId, 'dave-2');
        expect(daveCam.subscription!.remoteSessionId, 'dave-2');
        expect(alice.session.subscriptions, hasLength(2));
        // Only the successful pulls made transceivers (2 old, 2 new) and
        // renegotiated; the failed ones added none.
        expect(pc.transceivers, hasLength(4));
        expect(pulledMids, hasLength(4));
        // The SFU keeps exactly the current pulls open: every other mid it
        // ever assigned to this session was closed.
        final open = {...pulledMids}..removeAll(h.closesOf(alice));
        expect(open, {daveMic.subscription!.mid, daveCam.subscription!.mid});
        expect(
          h.closesOf(alice),
          hasLength(2),
          reason: 'the two pulls from the old session',
        );

        alice.leave();
        dave.dispose();
        pump();
      });
    });
  });

  test('debugSimulateConnectionFailure fails the session and the room '
      'recovers', () {
    _fake((async, pump) {
      final alice = join(pump, 'alice');
      final events = _record(alice);
      final pc = h.pcOf(alice);
      alice.debugSimulateConnectionFailure();
      pump();
      expect(pc.closed, isTrue);
      expect(
        (events.whereType<RoomSessionFailedEvent>().single.failure
                as SfuPeerConnectionFailed)
            .kind,
        PeerConnectionFailureKind.simulated,
      );
      async.elapse(const Duration(seconds: 1));
      pump();
      expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
      alice.leave();
      pump();
      expect(() => alice.debugSimulateConnectionFailure(), throwsStateError);
    });
  });
}
