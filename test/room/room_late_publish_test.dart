// M10: a publish that comes long after joining (a permission prompt, a
// screen-share picker) must survive the SFU expiring a session whose peer
// connection never connected (docs/design.md §8.1, "Publishing late").

import 'dart:math' as math;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/reconnect/backoff.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

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

const _backoff = ReconnectOptions(
  backoff: BackoffOptions(
    initialDelay: Duration(seconds: 1),
    maxDelay: Duration(seconds: 4),
    maxAttempts: 3,
    maxElapsed: null,
  ),
);

/// Without the early connect: the session stays unconnected until the
/// first push, as the SFU then expires it.
const _late = RoomOptions(connectEarly: false, reconnect: _backoff);

/// [_late], with backoff delays of at most 10 ms, for tests in real time.
const _lateFast = RoomOptions(
  connectEarly: false,
  reconnect: ReconnectOptions(
    backoff: BackoffOptions(
      initialDelay: Duration(milliseconds: 5),
      maxDelay: Duration(milliseconds: 10),
      maxAttempts: 3,
      maxElapsed: null,
    ),
  ),
);

/// The default: the session connects at join.
const _early = RoomOptions(reconnect: _backoff);

SessionGoneException _gone(String operation, String sessionId) =>
    SessionGoneException(
      operation: operation,
      sessionId: sessionId,
      statusCode: 410,
      errorCode: 'session_error',
      errorDescription: 'Session appears to be disconnected',
    );

bool _isPush(TracksRequest request) => request.sessionDescription != null;

/// Runs [body] in fake time, with `pump` to settle microtasks and
/// zero-duration timers (the session's batching). [setUp] runs inside the
/// fake zone, so the fakes' streams complete in fake time too.
void _fake(
  void Function() setUp,
  void Function(FakeAsync async, void Function() pump) body,
) {
  fakeAsync((async) {
    setUp();
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

  setUp(() => Backoff.debugDefaultRandom = _MaxRandom.new);

  tearDown(() => Backoff.debugDefaultRandom = null);

  void fake(void Function(FakeAsync async, void Function() pump) body) =>
      _fake(() => h = RoomHarness(), body);

  Room join(void Function() pump, String id, RoomOptions options) {
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

  /// Makes every push on the sessions in [expired] fail with a 410, as the
  /// SFU does for a session that expired before its first push.
  void expire(Set<String> expired) {
    final original = h.broker.onNewTracks!;
    h.broker.onNewTracks = (sessionId, request) async {
      if (_isPush(request) && expired.contains(sessionId)) {
        h.broker.goneSessions.add(sessionId);
        throw _gone('tracks/new', sessionId);
      }
      return original(sessionId, request);
    };
  }

  group('a publish whose session is gone', () {
    test('re-sessions once and completes on the new session; peers see the '
        'new session with the track', () {
      fake((async, pump) {
        final alice = join(pump, 'alice', _late);
        final bob = join(pump, 'bob', _late);
        final first = alice.session;
        expire({first.sessionId});
        final events = record(alice);
        // Peer connections created from now on (the re-session's) connect
        // once negotiated.
        h.autoConnect = true;

        // The user answers the permission prompt late.
        async.elapse(const Duration(seconds: 30));
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
        expect(alice.isReconnecting, isTrue);
        expect(mic, isNull);

        async.elapse(const Duration(seconds: 1)); // The backoff delay.
        pump();

        expect(error, isNull);
        expect(mic, isNotNull);
        final second = alice.session;
        expect(second.sessionId, isNot(first.sessionId));
        expect(first.isClosed, isTrue);
        expect(h.broker.forgotten, contains(first.sessionId));
        expect(mic!.publication.session, same(second));
        expect(mic!.publication.state, SfuTrackState.active);
        expect(mic!.isPublished, isTrue);
        expect(mic!.mediaSource.isBroadcasting, isTrue);
        expect(h.media.userMediaCalls, hasLength(1), reason: 'one capture');
        expect(alice.localParticipant.trackPublications, [mic]);

        expect(
          events.whereType<RoomReconnectingEvent>().single.reason,
          ReconnectReason.sessionGone,
        );
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
        expect(
          events.whereType<LocalTrackPublishedEvent>().single.publication,
          mic,
        );
        expect(alice.connectionState, RoomConnectionState.connected);

        // Announced once, on the new session; the old one never carried it.
        final announced = h.announced('alice')!;
        expect(announced.sessionId, second.sessionId);
        expect(announced.tracks.keys, [mic!.trackName]);
        final bobSeesAlice = bob.participant('alice')!;
        expect(bobSeesAlice.sessionId, second.sessionId);
        final bobAliceMic = bobSeesAlice.microphone!;
        expect(bobAliceMic.subscriptionState, SfuTrackState.active);
        expect(h.pullsOf(bob), ['${second.sessionId}/${mic!.trackName}']);

        alice.leave();
        bob.leave();
        pump();
      });
    });

    test('the retry is pushed once the new session has connected, so peers '
        'can pull it', () {
      // late_publish_test on a Pixel, without connectEarly: Bob never
      // pulled Alice's video. The re-session left the new session
      // unconnected, so the retried push was its first negotiation, and
      // the SFU sometimes never serves a track pushed that way: every pull,
      // from any session, answers `not_found_track_error`, while the SFU
      // lists the track active and receives its media (about 1 in 150 such
      // pushes on the device; never once the session had connected).
      // Modelled at its worst: every push onto an unconnected session.
      fake((async, pump) {
        final alice = join(pump, 'alice', _late);
        final bob = join(pump, 'bob', _late);
        final first = alice.session;
        expire({first.sessionId});
        h.autoConnect = true;

        final unpullable = <String>{};
        final sfu = h.broker.onNewTracks!;
        h.broker.onNewTracks = (sessionId, request) async {
          if (_isPush(request)) {
            final connected =
                h.pcBySession[sessionId]?.connectionState ==
                RTCPeerConnectionState.RTCPeerConnectionStateConnected;
            if (!connected) {
              unpullable.addAll([
                for (final t in request.tracks) '$sessionId/${t.trackName}',
              ]);
            }
            return sfu(sessionId, request);
          }
          if (request.tracks.any(
            (t) => unpullable.contains('${t.sessionId}/${t.trackName}'),
          )) {
            return TracksResponse(
              tracks: [
                for (final t in request.tracks)
                  TrackResult(
                    location: TrackLocation.remote,
                    sessionId: t.sessionId,
                    trackName: t.trackName,
                    errorCode: 'not_found_track_error',
                  ),
              ],
            );
          }
          return sfu(sessionId, request);
        };

        async.elapse(const Duration(seconds: 30));
        LocalMediaPublication? mic;
        alice.localParticipant.publishMicrophone().then((p) => mic = p);
        pump();
        async.elapse(const Duration(seconds: 1)); // The backoff delay.
        pump();

        final second = alice.session;
        expect(mic!.publication.session, same(second));
        expect(
          [
            for (final c in h.broker.calls)
              if (c.sessionId == second.sessionId) c.operation,
          ],
          ['datachannels/establish', 'renegotiate', 'tracks/new'],
          reason: 'the new session is connected before the retried push',
        );
        expect(
          unpullable,
          isNot(
            contains(
              '${second.sessionId}/'
              '${mic!.trackName}',
            ),
          ),
        );

        async.elapse(const Duration(seconds: 5));
        pump();
        final bobAliceMic = bob.participant('alice')!.microphone!;
        expect(bobAliceMic.subscriptionState, SfuTrackState.active);
        expect(bobAliceMic.subscription!.remoteSessionId, second.sessionId);

        alice.leave();
        bob.leave();
        pump();
      });
    });

    // These three run in real time: disposing a device source that the
    // room created doesn't complete in fake time.
    test('surfaces the error when the new session is gone too', () async {
      final h = RoomHarness();
      final alice = await h.join('alice', options: _lateFast);
      h.autoConnect = true;
      // Every session expires before its push.
      final original = h.broker.onNewTracks!;
      h.broker.onNewTracks = (sessionId, request) async {
        if (_isPush(request)) {
          h.broker.goneSessions.add(sessionId);
          throw _gone('tracks/new', sessionId);
        }
        return original(sessionId, request);
      };

      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(isA<SessionGoneException>()),
      );
      // One retry: a push on the first session, one on the re-session's.
      expect([
        for (final c in h.broker.callsTo('tracks/new'))
          if (_isPush(c.request! as TracksRequest)) c.sessionId,
      ], hasLength(2));
      expect(alice.localParticipant.trackPublications, isEmpty);
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(
        h.media.streams.single.track.stopped,
        isTrue,
        reason: 'the capture the room started is released',
      );
      await alice.leave();
    });

    test('surfaces the error when automatic reconnection is off', () async {
      final h = RoomHarness();
      final alice = await h.join(
        'alice',
        options: const RoomOptions(
          connectEarly: false,
          reconnect: ReconnectOptions.disabled,
        ),
      );
      final first = alice.session;
      final original = h.broker.onNewTracks!;
      h.broker.onNewTracks = (sessionId, request) async {
        if (_isPush(request)) throw _gone('tracks/new', sessionId);
        return original(sessionId, request);
      };
      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(isA<SessionGoneException>()),
      );
      expect(alice.session, same(first));
      expect(alice.connectionState, RoomConnectionState.disconnected);
      await alice.leave();
    });

    test('a per-track rejection is not retried', () async {
      final h = RoomHarness();
      final alice = await h.join('alice', options: _lateFast);
      h.broker.onNewTracks = (sessionId, request) async => TracksResponse(
        sessionDescription: SessionDescription.answer(
          'answer:${request.sessionDescription!.sdp}',
        ),
        tracks: [
          for (final t in request.tracks)
            TrackResult(
              mid: t.mid,
              trackName: t.trackName,
              errorCode: 'invalid_track',
            ),
        ],
      );
      final first = alice.session;
      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(isA<SfuTrackException>()),
      );
      expect(alice.session, same(first));
      expect(alice.isReconnecting, isFalse);
      expect(h.broker.callsTo('tracks/new'), hasLength(1));
      await alice.leave();
    });

    test('publishes in flight together share one re-session', () {
      fake((async, pump) {
        final alice = join(pump, 'alice', _late);
        final first = alice.session.sessionId;
        expire({first});
        h.autoConnect = true;
        final events = record(alice);
        LocalMediaPublication? mic;
        LocalMediaPublication? cam;
        alice.localParticipant.publishMicrophone().then((p) => mic = p);
        alice.localParticipant.publishCamera().then((p) => cam = p);
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();

        expect(mic, isNotNull);
        expect(cam, isNotNull);
        expect(events.whereType<RoomReconnectingEvent>(), hasLength(1));
        expect(mic!.publication.session, same(alice.session));
        expect(cam!.publication.session, same(alice.session));
        expect(h.announced('alice')!.tracks.keys.toSet(), {
          mic!.trackName,
          cam!.trackName,
        });
        alice.leave();
        pump();
      });
    });

    test('a DataChannel publish is retried the same way', () {
      fake((async, pump) {
        final alice = join(pump, 'alice', _late);
        final first = alice.session.sessionId;
        h.autoConnect = true;
        h.broker.onEstablishDataChannels = (sessionId, request) async {
          if (sessionId == first) {
            throw _gone('datachannels/establish', sessionId);
          }
          return h.broker.defaultEstablishDataChannels(sessionId, request);
        };
        LocalDataChannel? channel;
        alice.data.publish('chat').then((c) => channel = c);
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(channel, isNotNull);
        expect(channel!.session, same(alice.session));
        expect(alice.session.sessionId, isNot(first));
        alice.leave();
        pump();
      });
    });
  });

  group('connectEarly', () {
    test('joining connects the session before anything is published', () {
      fake((async, pump) {
        h.autoConnect = true;
        final states = <RoomConnectionState>[];
        Room? alice;
        h.join('alice', options: _early).then((r) {
          alice = r;
          // The state the room was returned in, then its changes.
          r.connectionStateChanges.listen(states.add);
        });
        pump();

        final sessionId = alice!.session.sessionId;
        expect(
          [
            for (final c in h.broker.calls)
              if (c.sessionId == sessionId) c.operation,
          ],
          ['datachannels/establish', 'renegotiate'],
        );
        expect(alice!.session.hasNegotiated, isTrue);
        expect(states.last, RoomConnectionState.connected);
        expect(states, isNot(contains(RoomConnectionState.reconnecting)));

        // A publish long after joining stays on the same session.
        async.elapse(const Duration(seconds: 30));
        LocalMediaPublication? mic;
        alice!.localParticipant.publishMicrophone().then((p) => mic = p);
        pump();
        expect(mic!.publication.session, same(alice!.session));
        expect(alice!.session.sessionId, sessionId);
        alice!.leave();
        pump();
      });
    });

    test('a joined room is connecting until the peer connection connects', () {
      fake((async, pump) {
        final alice = join(pump, 'alice', _early);
        expect(alice.connectionState, RoomConnectionState.connecting);
        h
            .pcOf(alice)
            .emitConnectionState(
              RTCPeerConnectionState.RTCPeerConnectionStateConnected,
            );
        pump();
        expect(alice.connectionState, RoomConnectionState.connected);
        alice.leave();
        pump();
      });
    });

    test('a session already gone at join is replaced at once', () {
      fake((async, pump) {
        h.autoConnect = true;
        // The first session expires while the peer connection is created
        // (a slow first createPeerConnection on a loaded machine).
        h.broker.onEstablishDataChannels = (sessionId, request) async {
          if (sessionId == 'session-1') {
            throw _gone('datachannels/establish', sessionId);
          }
          return h.broker.defaultEstablishDataChannels(sessionId, request);
        };
        final alice = join(pump, 'alice', _early);
        final events = record(alice);
        expect(alice.isReconnecting, isTrue);
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(alice.session.sessionId, 'session-2');
        expect(alice.session.hasNegotiated, isTrue);
        expect(alice.connectionState, RoomConnectionState.connected);
        expect(events.whereType<RoomReconnectedEvent>(), hasLength(1));
        expect(h.announced('alice')!.sessionId, 'session-2');
        alice.leave();
        pump();
      });
    });

    test('another failure at join is reported and the room carries on', () {
      fake((async, pump) {
        h.broker.onEstablishDataChannels = (_, _) async =>
            throw const BrokerNetworkException(
              operation: 'datachannels/establish',
            );
        final alice = join(pump, 'alice', _early);
        expect(alice.session.isUsable, isTrue);
        expect(alice.connectionState, RoomConnectionState.connected);
        h.broker.onEstablishDataChannels = null;
        LocalMediaPublication? mic;
        alice.localParticipant.publishMicrophone().then((p) => mic = p);
        pump();
        expect(mic!.publication.state, SfuTrackState.active);
        alice.leave();
        pump();
      });
    });

    test('a re-session with nothing to move connects the new session', () {
      fake((async, pump) {
        h.autoConnect = true;
        final alice = join(pump, 'alice', _early);
        final first = alice.session;
        alice.debugSimulateConnectionFailure();
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        final second = alice.session;
        expect(second, isNot(same(first)));
        expect(h.callsOf(alice, 'datachannels/establish'), hasLength(1));
        expect(second.hasNegotiated, isTrue);
        expect(alice.connectionState, RoomConnectionState.connected);
        alice.leave();
        pump();
      });
    });
  });
}
