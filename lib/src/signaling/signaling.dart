/// @docImport 'in_memory_signaling.dart';
library;

import 'participant_state.dart';

/// The app-provided presence transport that a room runs on.
///
/// The Cloudflare SFU has no rooms or presence, so the app supplies them:
/// each participant announces its [ParticipantState] (its SFU session and
/// the tracks it publishes), and learns everyone else's. Implement this on
/// any transport with presence, such as Supabase Realtime, Firebase or your
/// own WebSocket server. [InMemorySignaling] is a ready-made implementation
/// for tests and local demos.
///
/// One instance represents one participant's connection, in at most one room
/// at a time.
///
/// ## Contract
///
/// - [join] enters a room and announces `self`. Calling it while already in
///   a room is an error.
/// - [update] replaces the announced state. It must keep the same
///   `participantId`. Calling it before [join] is an error.
/// - [participants] emits the full list of the *other* participants in the
///   room whenever it changes: someone joins, updates or leaves. It never
///   includes this participant's own entry. It should replay the current
///   list to each new listener (the way a `BehaviorSubject` does), emit an
///   empty list while not in a room, and avoid emitting unchanged lists.
/// - [leave] withdraws this participant's state, and the list becomes empty.
///   It is safe to call when not in a room. After [leave], [join] may be
///   called again.
/// - `participantId`s are unique within a room. Implementations should skip
///   remote entries they can't parse rather than fail the stream.
///
/// Presence data is only as trustworthy as the transport. The broker, not
/// signaling, enforces who may pull which session (see the broker contract
/// in `docs/design.md`).
abstract interface class Signaling {
  /// Joins [roomId] and announces [self] to the other participants.
  Future<void> join(String roomId, ParticipantState self);

  /// Replaces this participant's announced state with [self].
  Future<void> update(ParticipantState self);

  /// The other participants in the room, excluding this one.
  Stream<List<ParticipantState>> get participants;

  /// Leaves the current room, if any.
  Future<void> leave();
}
