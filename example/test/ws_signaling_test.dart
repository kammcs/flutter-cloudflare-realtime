import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/ws_signaling.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_web_socket.dart';

final alice = ParticipantState(participantId: 'alice');
final bob = ParticipantState(
  participantId: 'bob',
  sessionId: 'sess-b',
  tracks: {
    'cam': const TrackInfo(kind: TrackKind.video, source: TrackSource.camera),
  },
  metadata: {'displayName': 'Bob'},
);
final carol = ParticipantState(participantId: 'carol');

void main() {
  late List<FakeWebSocketChannel> channels;
  late List<Object> errors;

  setUp(() {
    channels = [];
    errors = [];
  });

  WsSignaling make() => WsSignaling(
    url: Uri.parse('ws://dev.test/signaling?token=t'),
    connect: (url) {
      final channel = FakeWebSocketChannel(url);
      channels.add(channel);
      return channel;
    },
    onError: errors.add,
  );

  /// Joins [room] as [self] through a new fake socket, acknowledging it.
  FakeWebSocketChannel joinOk(
    FakeAsync async,
    WsSignaling s, {
    String room = 'r',
    ParticipantState? self,
  }) {
    var done = false;
    s.join(room, self ?? alice).then((_) => done = true);
    async.flushMicrotasks();
    final channel = channels.last..open();
    async.flushMicrotasks();
    final join = channel.sent.last;
    channel.receive({'type': 'ack', 'id': join['id']});
    async.flushMicrotasks();
    expect(done, isTrue);
    return channel;
  }

  void list(
    FakeWebSocketChannel channel,
    List<Object?> participants, {
    String room = 'r',
  }) => channel.receive({
    'type': 'participants',
    'roomId': room,
    'participants': participants,
  });

  /// The error [future] fails with, after running microtasks.
  Object? errorOf(FakeAsync async, Future<void> future) {
    Object? error;
    future.catchError((Object e) => error = e);
    async.flushMicrotasks();
    return error;
  }

  List<Object?> json(List<ParticipantState> states) => [
    for (final s in states) s.toJson(),
  ];

  group('join', () {
    test('opens the socket, sends the join and waits for the ack', () {
      fakeAsync((async) {
        final s = make();
        final statuses = <WsSignalingStatus>[];
        s.statusChanges.listen(statuses.add);
        var done = false;
        s.join('r', alice).then((_) => done = true);
        async.flushMicrotasks();

        expect(channels, hasLength(1));
        expect(channels[0].url, Uri.parse('ws://dev.test/signaling?token=t'));
        expect(channels[0].sent, isEmpty);
        expect(s.status, WsSignalingStatus.connecting);

        channels[0].open();
        async.flushMicrotasks();
        expect(s.status, WsSignalingStatus.connected);
        expect(channels[0].sent, [
          {
            'type': 'join',
            'id': 1,
            'roomId': 'r',
            'participant': alice.toJson(),
          },
        ]);
        expect(done, isFalse);

        channels[0].receive({'type': 'ack', 'id': 1});
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(s.roomId, 'r');
        expect(statuses, [
          WsSignalingStatus.idle,
          WsSignalingStatus.connecting,
          WsSignalingStatus.connected,
        ]);
      });
    });

    test('throws when already in a room', () {
      fakeAsync((async) {
        final s = make();
        joinOk(async, s);
        expect(errorOf(async, s.join('r2', alice)), isStateError);
      });
    });

    test('fails with the server error and resets', () {
      fakeAsync((async) {
        final s = make();
        Object? error;
        s.join('r', alice).catchError((Object e) => error = e);
        async.flushMicrotasks();
        channels[0].open();
        async.flushMicrotasks();
        channels[0].receive({
          'type': 'error',
          'id': 1,
          'code': 'bad_request',
          'message': 'nope',
        });
        async.flushMicrotasks();

        expect(
          error,
          isA<WsSignalingException>().having(
            (e) => e.code,
            'code',
            'bad_request',
          ),
        );
        expect(s.roomId, isNull);
        expect(s.status, WsSignalingStatus.idle);
        expect(channels[0].sink.closed, isTrue);
        // It can join again.
        joinOk(async, s);
        expect(channels, hasLength(2));
      });
    });

    test('fails for good on a bad token (close 4401)', () {
      fakeAsync((async) {
        final s = make();
        Object? error;
        s.join('r', alice).catchError((Object e) => error = e);
        async.flushMicrotasks();
        channels[0].open();
        async.flushMicrotasks();
        channels[0].receive({'type': 'error', 'code': 'unauthorized'});
        channels[0].drop(WsSignaling.closeUnauthorized);
        async.flushMicrotasks();

        expect(
          error,
          isA<WsSignalingException>().having(
            (e) => e.code,
            'code',
            'unauthorized',
          ),
        );
        expect(s.status, WsSignalingStatus.closed);
        async.elapse(const Duration(minutes: 1));
        expect(channels, hasLength(1));
        expect(errors, isEmpty);
      });
    });

    test('keeps retrying an unreachable server until the join times out', () {
      fakeAsync((async) {
        final s = make();
        Object? error;
        s.join('r', alice).catchError((Object e) => error = e);
        async.flushMicrotasks();
        channels.last.failToOpen();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 500));
        expect(channels, hasLength(2));
        channels.last.failToOpen();
        async.flushMicrotasks();

        async.elapse(const Duration(seconds: 15));
        expect(error, isA<TimeoutException>());
        expect(s.roomId, isNull);
        expect(s.status, WsSignalingStatus.idle);
        final count = channels.length;
        async.elapse(const Duration(minutes: 1));
        expect(channels, hasLength(count));
      });
    });

    test('leave() during a pending join fails the join', () {
      fakeAsync((async) {
        final s = make();
        Object? error;
        s.join('r', alice).catchError((Object e) => error = e);
        async.flushMicrotasks();
        s.leave();
        async.flushMicrotasks();
        expect(error, isStateError);
        expect(s.status, WsSignalingStatus.idle);
      });
    });
  });

  group('participants', () {
    test('lists the others, skipping self and unparseable entries', () {
      fakeAsync((async) {
        final s = make();
        final lists = <List<ParticipantState>>[];
        s.participants.listen(lists.add);
        final channel = joinOk(async, s);

        list(channel, [
          alice.toJson(),
          bob.toJson(),
          {'participantId': 42},
          'junk',
          {'participantId': 'x', 'tracks': 'nope'},
          {...carol.toJson(), 'futureField': true},
        ]);
        async.flushMicrotasks();
        expect(lists, [
          <ParticipantState>[],
          [bob, carol],
        ]);
      });
    });

    test('ignores unchanged lists, other rooms and malformed messages', () {
      fakeAsync((async) {
        final s = make();
        final lists = <List<ParticipantState>>[];
        s.participants.listen(lists.add);
        final channel = joinOk(async, s);

        list(channel, json([alice, bob]));
        list(channel, json([bob, alice]).reversed.toList());
        list(channel, json([alice, carol]), room: 'other');
        channel
          ..receiveRaw('not json')
          ..receiveRaw([1, 2, 3])
          ..receiveRaw('[1]')
          ..receive({'type': 'participants', 'roomId': 'r'});
        async.flushMicrotasks();
        expect(lists, [
          <ParticipantState>[],
          [bob],
        ]);
      });
    });

    test('replays the current list to new listeners', () {
      fakeAsync((async) {
        final s = make();
        final channel = joinOk(async, s);
        list(channel, json([alice, bob]));
        async.flushMicrotasks();

        List<ParticipantState>? first;
        s.participants.first.then((l) => first = l);
        async.flushMicrotasks();
        expect(first, [bob]);
      });
    });
  });

  group('update', () {
    test('sends the new state', () {
      fakeAsync((async) {
        final s = make();
        final channel = joinOk(async, s);
        final next = alice.copyWith(sessionId: 's1');
        s.update(next);
        async.flushMicrotasks();
        expect(channel.sent.last, {
          'type': 'update',
          'id': 2,
          'participant': next.toJson(),
        });
        expect(s.self, next);
      });
    });

    test('checks the contract', () {
      fakeAsync((async) {
        final s = make();
        expect(errorOf(async, s.update(alice)), isStateError);
        joinOk(async, s);
        expect(
          errorOf(async, s.update(ParticipantState(participantId: 'mallory'))),
          isArgumentError,
        );
      });
    });

    test('reports a refused update through onError', () {
      fakeAsync((async) {
        final s = make();
        final channel = joinOk(async, s);
        s.update(alice.copyWith(sessionId: 's1'));
        channel.receive({
          'type': 'error',
          'id': 2,
          'code': 'bad_request',
          'message': 'x',
        });
        async.flushMicrotasks();
        expect(errors.single, isA<WsSignalingException>());
        expect(s.roomId, 'r');
      });
    });
  });

  group('leave', () {
    test('sends leave, closes the socket and clears the list', () {
      fakeAsync((async) {
        final s = make();
        final lists = <List<ParticipantState>>[];
        s.participants.listen(lists.add);
        final channel = joinOk(async, s);
        list(channel, json([alice, bob]));
        async.flushMicrotasks();

        s.leave();
        async.flushMicrotasks();
        expect(channel.sent.last, {'type': 'leave', 'id': 2});
        expect(channel.sink.closed, isTrue);
        expect(s.status, WsSignalingStatus.idle);
        expect(s.roomId, isNull);
        expect(lists.last, isEmpty);

        // Messages from the old socket are ignored.
        list(channel, json([bob]));
        async.flushMicrotasks();
        expect(lists.last, isEmpty);

        // Safe to call again; join works again on a new socket.
        s.leave();
        joinOk(async, s, room: 'r2');
        expect(channels, hasLength(2));
      });
    });
  });

  group('reconnection', () {
    test('reconnects with backoff and rejoins with the latest state', () {
      fakeAsync((async) {
        final s = make();
        final lists = <List<ParticipantState>>[];
        s.participants.listen(lists.add);
        final first = joinOk(async, s);
        list(first, json([alice, bob]));
        async.flushMicrotasks();

        first.drop();
        async.flushMicrotasks();
        expect(s.status, WsSignalingStatus.reconnecting);
        // The list survives a blip.
        expect(lists.last, [bob]);

        // Updates while disconnected are kept for the rejoin.
        final next = alice.copyWith(sessionId: 'new-session');
        s.update(next);

        async.elapse(const Duration(milliseconds: 499));
        expect(channels, hasLength(1));
        async.elapse(const Duration(milliseconds: 1));
        expect(channels, hasLength(2));

        // Failures back off: 1 s, then 2 s.
        channels.last.failToOpen();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 999));
        expect(channels, hasLength(2));
        async.elapse(const Duration(milliseconds: 1));
        expect(channels, hasLength(3));
        channels.last.failToOpen();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 1999));
        expect(channels, hasLength(3));
        async.elapse(const Duration(milliseconds: 1));
        expect(channels, hasLength(4));

        final fresh = channels.last..open();
        async.flushMicrotasks();
        expect(s.status, WsSignalingStatus.connected);
        final join = fresh.sent.single;
        expect(join['type'], 'join');
        expect(join['roomId'], 'r');
        expect(join['participant'], next.toJson());

        fresh.receive({'type': 'ack', 'id': join['id']});
        list(fresh, json([next, carol]));
        async.flushMicrotasks();
        expect(lists.last, [carol]);

        // A successful rejoin resets the backoff.
        fresh.drop();
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 500));
        expect(channels, hasLength(5));
      });
    });

    test('caps the backoff', () {
      fakeAsync((async) {
        final s = make();
        joinOk(async, s).drop();
        async.flushMicrotasks();
        for (var i = 0; i < 8; i++) {
          async.elapse(const Duration(seconds: 10));
          channels.last.failToOpen();
          async.flushMicrotasks();
        }
        final count = channels.length;
        async.elapse(const Duration(seconds: 10));
        expect(channels, hasLength(count + 1));
        expect(s.status, WsSignalingStatus.reconnecting);
      });
    });

    test('pings, and replaces a socket that goes silent', () {
      fakeAsync((async) {
        final s = make();
        final channel = joinOk(async, s);

        async.elapse(const Duration(seconds: 4));
        expect(channel.sent.last, {'type': 'ping'});
        channel.receive({'type': 'pong'});
        async.flushMicrotasks();

        // 9 s after the pong: still fine.
        async.elapse(const Duration(seconds: 9));
        expect(s.status, WsSignalingStatus.connected);
        expect(channels, hasLength(1));

        // 10 s of silence: dead. Close it and reconnect.
        async.elapse(const Duration(seconds: 1));
        expect(s.status, WsSignalingStatus.reconnecting);
        expect(channel.sink.closed, isTrue);
        async.elapse(const Duration(milliseconds: 500));
        expect(channels, hasLength(2));
      });
    });

    test('stops for good when another connection replaces this one', () {
      fakeAsync((async) {
        final s = make();
        final lists = <List<ParticipantState>>[];
        s.participants.listen(lists.add);
        final channel = joinOk(async, s);
        list(channel, json([alice, bob]));
        async.flushMicrotasks();

        channel
          ..receive({'type': 'error', 'code': 'replaced', 'message': 'x'})
          ..drop(WsSignaling.closeReplaced);
        async.flushMicrotasks();

        expect(s.status, WsSignalingStatus.closed);
        expect(s.roomId, isNull);
        expect(lists.last, isEmpty);
        expect(
          errors.single,
          isA<WsSignalingException>().having((e) => e.code, 'code', 'replaced'),
        );
        async.elapse(const Duration(minutes: 1));
        expect(channels, hasLength(1));
      });
    });

    test('treats a connector that throws like a failed connection', () {
      fakeAsync((async) {
        var calls = 0;
        final s = WsSignaling(
          url: Uri.parse('ws://dev.test/signaling'),
          connect: (url) {
            calls++;
            throw ArgumentError('bad url');
          },
          joinTimeout: const Duration(seconds: 2),
        );
        Object? error;
        s.join('r', alice).catchError((Object e) => error = e);
        async.elapse(const Duration(seconds: 2));
        expect(calls, greaterThan(1));
        expect(error, isA<TimeoutException>());
      });
    });
  });

  test('dispose leaves and completes the streams', () {
    fakeAsync((async) {
      final s = make();
      var participantsDone = false;
      var statusDone = false;
      s.participants.listen(null, onDone: () => participantsDone = true);
      s.statusChanges.listen(null, onDone: () => statusDone = true);
      final channel = joinOk(async, s);
      s.dispose();
      async.flushMicrotasks();
      expect(channel.sent.last['type'], 'leave');
      expect(participantsDone, isTrue);
      expect(statusDone, isTrue);
      expect(errorOf(async, s.join('r', alice)), isStateError);
    });
  });
}
