import 'package:flutter/foundation.dart';

import '../util/state_stream.dart';
import 'participant_state.dart';
import 'signaling.dart';

/// A shared, in-process presence server for [InMemorySignaling].
///
/// Every [InMemorySignaling] created with the same hub sees the others in
/// the same room. A hub holds any number of rooms; a room exists while it
/// has members.
///
/// ```dart
/// final hub = InMemorySignalingHub();
/// final alice = InMemorySignaling(hub);
/// final bob = InMemorySignaling(hub);
/// await alice.join('room-1', ParticipantState(participantId: 'alice'));
/// await bob.join('room-1', ParticipantState(participantId: 'bob'));
/// // alice.participants now emits [bob]; bob.participants emits [alice].
/// ```
class InMemorySignalingHub {
  /// Creates a hub with no rooms.
  InMemorySignalingHub();

  // roomId -> members, in join order.
  final Map<String, Map<InMemorySignaling, ParticipantState>> _rooms = {};

  /// The IDs of rooms that currently have members.
  Iterable<String> get roomIds => List.unmodifiable(_rooms.keys);

  /// Every participant in [roomId], in join order. Empty if nobody is there.
  List<ParticipantState> participantsIn(String roomId) =>
      List.unmodifiable(_rooms[roomId]?.values ?? const []);

  void _join(String roomId, InMemorySignaling member, ParticipantState self) {
    final room = _rooms[roomId] ?? {};
    if (room.values.any((p) => p.participantId == self.participantId)) {
      throw StateError(
        'Participant "${self.participantId}" is already in room "$roomId".',
      );
    }
    _rooms[roomId] = room..[member] = self;
    _broadcast(room);
  }

  void _update(String roomId, InMemorySignaling member, ParticipantState self) {
    final room = _rooms[roomId]!;
    room[member] = self;
    _broadcast(room);
  }

  void _leave(String roomId, InMemorySignaling member) {
    final room = _rooms[roomId]!;
    room.remove(member);
    if (room.isEmpty) {
      _rooms.remove(roomId);
    } else {
      _broadcast(room);
    }
  }

  void _broadcast(Map<InMemorySignaling, ParticipantState> room) {
    for (final member in room.keys) {
      member._publish([
        for (final MapEntry(key: other, :value) in room.entries)
          if (!identical(other, member)) value,
      ]);
    }
  }
}

/// A [Signaling] implementation that runs entirely in memory.
///
/// Use it in tests and local demos: create one [InMemorySignalingHub] and
/// one [InMemorySignaling] per simulated participant. Calls complete without
/// any real I/O, and [participants] delivers changes asynchronously, in
/// order, like a real transport would.
///
/// Beyond the [Signaling] contract, [join] throws a [StateError] if another
/// member of the room already uses the same `participantId`, and [update]
/// throws an [ArgumentError] if the `participantId` changes.
class InMemorySignaling implements Signaling {
  /// Creates a participant connection on [hub].
  InMemorySignaling(this.hub);

  /// The hub this connection shares with the other participants.
  final InMemorySignalingHub hub;

  final StateStream<List<ParticipantState>> _participants = StateStream(
    const [],
    equals: listEquals,
  );

  String? _roomId;
  ParticipantState? _self;
  bool _disposed = false;

  /// The room this connection is in, or `null`.
  String? get roomId => _roomId;

  /// The state this connection last announced, or `null` when not in a room.
  ParticipantState? get self => _self;

  @override
  Stream<List<ParticipantState>> get participants => _participants.stream;

  @override
  Future<void> join(String roomId, ParticipantState self) async {
    _checkNotDisposed();
    if (_roomId != null) {
      throw StateError('Already in room "$_roomId". Call leave() first.');
    }
    hub._join(roomId, this, self);
    _roomId = roomId;
    _self = self;
  }

  @override
  Future<void> update(ParticipantState self) async {
    _checkNotDisposed();
    final roomId = _roomId;
    final current = _self;
    if (roomId == null || current == null) {
      throw StateError('Not in a room. Call join() first.');
    }
    if (self.participantId != current.participantId) {
      throw ArgumentError.value(
        self.participantId,
        'self.participantId',
        'must stay "${current.participantId}"',
      );
    }
    _self = self;
    hub._update(roomId, this, self);
  }

  @override
  Future<void> leave() async {
    final roomId = _roomId;
    if (roomId == null) return;
    _roomId = null;
    _self = null;
    hub._leave(roomId, this);
    _participants.set(const []);
  }

  /// Leaves the room, if any, and completes [participants].
  ///
  /// The instance can't be used afterwards. Calling it again has no effect.
  Future<void> dispose() async {
    if (_disposed) return;
    await leave();
    _disposed = true;
    await _participants.close();
  }

  void _publish(List<ParticipantState> others) =>
      _participants.set(List.unmodifiable(others));

  void _checkNotDisposed() {
    if (_disposed) throw StateError('This InMemorySignaling was disposed.');
  }
}
