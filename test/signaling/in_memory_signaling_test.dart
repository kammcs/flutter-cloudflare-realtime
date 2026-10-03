import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records every list a [Signaling.participants] stream emits, as ID lists.
class _Recorder {
  _Recorder(Signaling signaling) {
    _sub = signaling.participants.listen((list) {
      states.add(list);
      emissions.add([for (final p in list) p.participantId]);
    }, onDone: () => done = true);
  }

  late final StreamSubscription<List<ParticipantState>> _sub;
  final List<List<ParticipantState>> states = [];
  final List<List<String>> emissions = [];
  bool done = false;

  List<String> get latest => emissions.last;

  Future<void> cancel() => _sub.cancel();
}

ParticipantState _p(String id, {String? sessionId}) =>
    ParticipantState(participantId: id, sessionId: sessionId);

void main() {
  late InMemorySignalingHub hub;
  late InMemorySignaling alice;
  late InMemorySignaling bob;
  late InMemorySignaling carol;

  setUp(() {
    hub = InMemorySignalingHub();
    alice = InMemorySignaling(hub);
    bob = InMemorySignaling(hub);
    carol = InMemorySignaling(hub);
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await carol.dispose();
  });

  test('emits an empty list before joining', () async {
    final rec = _Recorder(alice);
    await pumpEventQueue();
    expect(rec.emissions, [<String>[]]);
    expect(alice.roomId, isNull);
    expect(alice.self, isNull);
  });

  test('a lone participant sees nobody, not itself', () async {
    final rec = _Recorder(alice);
    await alice.join('room', _p('alice'));
    await pumpEventQueue();
    expect(rec.emissions, [<String>[]]);
    expect(alice.roomId, 'room');
    expect(alice.self, _p('alice'));
    expect(hub.participantsIn('room'), [_p('alice')]);
  });

  test('join: participants see each other, never themselves', () async {
    final recA = _Recorder(alice);
    final recB = _Recorder(bob);
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    await pumpEventQueue();
    expect(recA.emissions, [
      <String>[],
      ['bob'],
    ]);
    expect(recB.emissions, [
      <String>[],
      ['alice'],
    ]);
  });

  test('late joiner sees existing participants in join order', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    await carol.join('room', _p('carol'));
    final rec = _Recorder(carol);
    await pumpEventQueue();
    expect(rec.emissions, [
      ['alice', 'bob'],
    ]);
  });

  test('late listener gets the current list replayed', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    await pumpEventQueue();
    expect(await alice.participants.first, [_p('bob')]);
  });

  test('update propagates the new state to others only', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    final recA = _Recorder(alice);
    final recB = _Recorder(bob);
    await pumpEventQueue();

    const cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);
    final updated = _p('alice', sessionId: 's1').copyWith(tracks: {'c': cam});
    await alice.update(updated);
    await pumpEventQueue();

    expect(recB.states, [
      [_p('alice')],
      [updated],
    ]);
    expect(recA.emissions, [
      ['bob'],
    ]);
    expect(alice.self, updated);
    expect(hub.participantsIn('room'), [updated, _p('bob')]);
  });

  test('an update keeps the participant in its join position', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    await carol.join('room', _p('carol'));
    await alice.update(_p('alice', sessionId: 's1'));
    await pumpEventQueue();
    expect(await carol.participants.first, [
      _p('alice', sessionId: 's1'),
      _p('bob'),
    ]);
  });

  test('an unchanged update emits nothing', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob', sessionId: 's'));
    final rec = _Recorder(alice);
    await bob.update(_p('bob', sessionId: 's'));
    await pumpEventQueue();
    expect(rec.emissions, [
      ['bob'],
    ]);
  });

  test(
    'leave removes the participant for others and empties its list',
    () async {
      await alice.join('room', _p('alice'));
      await bob.join('room', _p('bob'));
      await carol.join('room', _p('carol'));
      final recA = _Recorder(alice);
      final recB = _Recorder(bob);
      await pumpEventQueue();

      await bob.leave();
      await pumpEventQueue();

      expect(recA.emissions, [
        ['bob', 'carol'],
        ['carol'],
      ]);
      expect(recB.emissions, [
        ['alice', 'carol'],
        <String>[],
      ]);
      expect(bob.roomId, isNull);
      expect(bob.self, isNull);
      expect(hub.participantsIn('room'), [_p('alice'), _p('carol')]);
    },
  );

  test('rooms are isolated', () async {
    final recA = _Recorder(alice);
    final recC = _Recorder(carol);
    await alice.join('one', _p('alice'));
    await bob.join('one', _p('bob'));
    await carol.join('two', _p('carol'));
    await bob.update(_p('bob', sessionId: 's'));
    await pumpEventQueue();

    expect(recA.latest, ['bob']);
    expect(recC.emissions, [<String>[]]);
    expect(hub.participantsIn('two'), [_p('carol')]);
    expect(hub.roomIds, unorderedEquals(['one', 'two']));
  });

  test('the same participantId may be used in different rooms', () async {
    await alice.join('one', _p('same'));
    await bob.join('two', _p('same'));
    expect(hub.participantsIn('one'), [_p('same')]);
    expect(hub.participantsIn('two'), [_p('same')]);
  });

  test('a duplicate participantId in one room is rejected', () async {
    await alice.join('room', _p('alice'));
    await expectLater(bob.join('room', _p('alice')), throwsStateError);
    expect(bob.roomId, isNull);
    expect(hub.participantsIn('room'), [_p('alice')]);
  });

  test('joining twice is an error', () async {
    await alice.join('room', _p('alice'));
    await expectLater(alice.join('other', _p('alice')), throwsStateError);
    expect(alice.roomId, 'room');
  });

  test('update before join is an error', () async {
    await expectLater(alice.update(_p('alice')), throwsStateError);
  });

  test('update may not change the participantId', () async {
    await alice.join('room', _p('alice'));
    await expectLater(alice.update(_p('mallory')), throwsArgumentError);
    expect(alice.self, _p('alice'));
  });

  test('leave when not in a room is a no-op', () async {
    await alice.leave();
    await alice.join('room', _p('alice'));
    await alice.leave();
    await alice.leave();
    expect(alice.roomId, isNull);
  });

  test('a room disappears when its last member leaves', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    await alice.leave();
    expect(hub.roomIds, ['room']);
    await bob.leave();
    expect(hub.roomIds, isEmpty);
    expect(hub.participantsIn('room'), isEmpty);
  });

  test('a participant can rejoin, in another room', () async {
    await bob.join('two', _p('bob'));
    final rec = _Recorder(alice);
    await alice.join('one', _p('alice'));
    await alice.leave();
    await alice.join('two', _p('alice'));
    await pumpEventQueue();
    expect(rec.emissions, [
      <String>[],
      ['bob'],
    ]);
  });

  test('emitted lists are unmodifiable', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    final list = await alice.participants.first;
    expect(() => list.add(_p('x')), throwsUnsupportedError);
    expect(() => hub.participantsIn('room').clear(), throwsUnsupportedError);
  });

  test('participants is a broadcast stream', () {
    expect(alice.participants.isBroadcast, isTrue);
  });

  test('dispose leaves, completes the stream and blocks further use', () async {
    await alice.join('room', _p('alice'));
    await bob.join('room', _p('bob'));
    final recA = _Recorder(alice);
    final recB = _Recorder(bob);
    await pumpEventQueue();

    await alice.dispose();
    await pumpEventQueue();

    expect(recA.done, isTrue);
    expect(recB.latest, isEmpty);
    expect(hub.participantsIn('room'), [_p('bob')]);
    await expectLater(alice.join('room', _p('alice')), throwsStateError);
    await expectLater(alice.update(_p('alice')), throwsStateError);
    await alice.leave();
    await alice.dispose();
  });
}
