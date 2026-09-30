import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../signaling/participant_state.dart';

const DeepCollectionEquality _deepEquality = DeepCollectionEquality();

/// How one participant's announced state changed between two lists.
///
/// Internal: not exported from the package barrel.
@immutable
class ParticipantChange {
  /// Compares [previous] and [current], which must have the same
  /// `participantId`.
  ParticipantChange(this.previous, this.current)
    : assert(previous.participantId == current.participantId),
      addedTracks = _added(previous.tracks, current.tracks),
      removedTracks = _added(current.tracks, previous.tracks),
      changedTracks = _changed(previous.tracks, current.tracks);

  /// The state before.
  final ParticipantState previous;

  /// The state now.
  final ParticipantState current;

  /// Tracks that appeared, by name. A track whose kind or source changed
  /// under the same name counts as removed and added.
  final Map<String, TrackInfo> addedTracks;

  /// Tracks that went away, by name, with their last [TrackInfo].
  final Map<String, TrackInfo> removedTracks;

  /// Tracks that stayed but changed otherwise (for example [TrackInfo.muted]
  /// or [TrackInfo.simulcast]), by name, with their new [TrackInfo].
  final Map<String, TrackInfo> changedTracks;

  /// The participant's ID.
  String get participantId => current.participantId;

  /// Whether the participant moved to another SFU session (for example
  /// after reconnecting). Their tracks must be pulled from the new one.
  bool get sessionChanged => previous.sessionId != current.sessionId;

  /// Whether the participant's metadata changed.
  bool get metadataChanged =>
      !_deepEquality.equals(previous.metadata, current.metadata);

  /// Whether anything changed.
  bool get hasChanges =>
      sessionChanged ||
      metadataChanged ||
      addedTracks.isNotEmpty ||
      removedTracks.isNotEmpty ||
      changedTracks.isNotEmpty;

  static bool _sameTrack(TrackInfo a, TrackInfo b) =>
      a.kind == b.kind && a.source == b.source;

  // Tracks in [to] that [from] doesn't have (as the same track).
  static Map<String, TrackInfo> _added(
    Map<String, TrackInfo> from,
    Map<String, TrackInfo> to,
  ) => Map.unmodifiable({
    for (final MapEntry(:key, :value) in to.entries)
      if (from[key] case final before
          when before == null || !_sameTrack(before, value))
        key: value,
  });

  static Map<String, TrackInfo> _changed(
    Map<String, TrackInfo> from,
    Map<String, TrackInfo> to,
  ) => Map.unmodifiable({
    for (final MapEntry(:key, :value) in to.entries)
      if (from[key] case final before?
          when _sameTrack(before, value) && before != value)
        key: value,
  });

  @override
  String toString() =>
      'ParticipantChange($participantId'
      '${sessionChanged ? ', session ${previous.sessionId} -> ${current.sessionId}' : ''}'
      '${addedTracks.isEmpty ? '' : ', +${addedTracks.keys}'}'
      '${removedTracks.isEmpty ? '' : ', -${removedTracks.keys}'}'
      '${changedTracks.isEmpty ? '' : ', ~${changedTracks.keys}'}'
      '${metadataChanged ? ', metadata' : ''})';
}

/// The difference between two successive participant lists from
/// `Signaling.participants`.
///
/// Internal: not exported from the package barrel.
@immutable
class ParticipantsDiff {
  /// Creates a diff.
  const ParticipantsDiff({
    this.joined = const [],
    this.left = const [],
    this.updated = const [],
  });

  /// Participants that appeared, in the order of the new list.
  final List<ParticipantState> joined;

  /// Participants that went away, with their last state, in the order of the
  /// old list.
  final List<ParticipantState> left;

  /// Participants whose state changed, in the order of the new list.
  final List<ParticipantChange> updated;

  /// Whether nothing changed.
  bool get isEmpty => joined.isEmpty && left.isEmpty && updated.isEmpty;

  @override
  String toString() =>
      'ParticipantsDiff(joined: ${[for (final p in joined) p.participantId]}, '
      'left: ${[for (final p in left) p.participantId]}, updated: $updated)';
}

/// Keeps the participants a room can use: those with an SFU session. Later
/// entries win over earlier ones with the same `participantId`.
///
/// Internal: not exported from the package barrel.
Map<String, ParticipantState> usableParticipants(
  Iterable<ParticipantState> participants,
) => {
  for (final p in participants)
    if (p.sessionId != null) p.participantId: p,
};

/// Diffs two participant lists by `participantId`.
///
/// Participants without a `sessionId` are ignored, as if absent: one whose
/// session goes away counts as having left, and one who gets a session
/// counts as having joined. If a list names a participant twice, the later
/// entry wins.
///
/// Internal: not exported from the package barrel.
ParticipantsDiff diffParticipants(
  Iterable<ParticipantState> previous,
  Iterable<ParticipantState> next,
) {
  final before = usableParticipants(previous);
  final after = usableParticipants(next);
  final joined = <ParticipantState>[];
  final updated = <ParticipantChange>[];
  for (final MapEntry(key: id, value: current) in after.entries) {
    final old = before[id];
    if (old == null) {
      joined.add(current);
    } else if (old != current) {
      final change = ParticipantChange(old, current);
      if (change.hasChanges) updated.add(change);
    }
  }
  return ParticipantsDiff(
    joined: List.unmodifiable(joined),
    left: List.unmodifiable([
      for (final MapEntry(key: id, value: old) in before.entries)
        if (!after.containsKey(id)) old,
    ]),
    updated: List.unmodifiable(updated),
  );
}
