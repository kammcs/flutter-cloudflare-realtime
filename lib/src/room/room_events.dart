part of 'room.dart';

/// Something that happened in a [Room], delivered on [Room.events].
///
/// Streams such as [Room.participants] and [Room.connectionState] carry the
/// same information as state; events are for reacting to changes (a toast
/// when someone joins, a sound when a track is muted).
sealed class RoomEvent {
  const RoomEvent();
}

/// A remote participant appeared: they joined, or got an SFU session.
final class ParticipantJoinedEvent extends RoomEvent {
  /// Creates the event.
  const ParticipantJoinedEvent(this.participant);

  /// Who joined.
  final RemoteParticipant participant;

  @override
  String toString() => 'ParticipantJoinedEvent(${participant.participantId})';
}

/// A remote participant went away: they left, or lost their SFU session.
final class ParticipantLeftEvent extends RoomEvent {
  /// Creates the event.
  const ParticipantLeftEvent(this.participant);

  /// Who left. Their publications are closed.
  final RemoteParticipant participant;

  @override
  String toString() => 'ParticipantLeftEvent(${participant.participantId})';
}

/// A remote participant's announced state changed.
final class ParticipantUpdatedEvent extends RoomEvent {
  /// Creates the event.
  const ParticipantUpdatedEvent(
    this.participant, {
    this.sessionChanged = false,
    this.metadataChanged = false,
    this.tracksChanged = false,
  });

  /// Who changed.
  final RemoteParticipant participant;

  /// Whether they moved to a new SFU session (they reconnected). The room
  /// pulls their subscribed tracks from the new session.
  final bool sessionChanged;

  /// Whether their metadata changed.
  final bool metadataChanged;

  /// Whether tracks were added, removed, muted or unmuted.
  final bool tracksChanged;

  @override
  String toString() =>
      'ParticipantUpdatedEvent(${participant.participantId}'
      '${sessionChanged ? ', session' : ''}'
      '${metadataChanged ? ', metadata' : ''}'
      '${tracksChanged ? ', tracks' : ''})';
}

/// A remote participant published a track.
final class TrackPublishedEvent extends RoomEvent {
  /// Creates the event.
  const TrackPublishedEvent(this.publication);

  /// The new track.
  final RemoteTrackPublication publication;

  /// Who published it.
  RemoteParticipant get participant => publication.participant;

  @override
  String toString() => 'TrackPublishedEvent(${publication.id})';
}

/// A remote participant unpublished a track (or left). Its subscription is
/// closed.
final class TrackUnpublishedEvent extends RoomEvent {
  /// Creates the event.
  const TrackUnpublishedEvent(this.publication);

  /// The track that went away.
  final RemoteTrackPublication publication;

  /// Who published it.
  RemoteParticipant get participant => publication.participant;

  @override
  String toString() => 'TrackUnpublishedEvent(${publication.id})';
}

/// A remote track was muted or unmuted by its publisher.
final class TrackMutedEvent extends RoomEvent {
  /// Creates the event.
  const TrackMutedEvent(this.publication, {required this.muted});

  /// The track.
  final RemoteTrackPublication publication;

  /// Whether it is muted now.
  final bool muted;

  @override
  String toString() => 'TrackMutedEvent(${publication.id}, muted: $muted)';
}

/// A remote track was pulled, or pulled again (for example from the
/// publisher's new session): [track] is ready to render.
final class TrackSubscribedEvent extends RoomEvent {
  /// Creates the event.
  const TrackSubscribedEvent(this.publication, this.track);

  /// The track's publication.
  final RemoteTrackPublication publication;

  /// The received track and a stream holding it.
  final RenderableTrack track;

  @override
  String toString() => 'TrackSubscribedEvent(${publication.id})';
}

/// Pulling a remote track failed. The room retries (see
/// [RoomOptions.pullRetry]); [willRetry] says whether it will.
final class TrackSubscriptionFailedEvent extends RoomEvent {
  /// Creates the event.
  const TrackSubscriptionFailedEvent(
    this.publication,
    this.error, {
    required this.willRetry,
  });

  /// The track's publication.
  final RemoteTrackPublication publication;

  /// What failed, typically an [SfuTrackException] or a broker exception.
  final Object error;

  /// Whether the room will try again by itself.
  final bool willRetry;

  @override
  String toString() =>
      'TrackSubscriptionFailedEvent(${publication.id}, $error, '
      'willRetry: $willRetry)';
}

/// The local participant published a track, and it was announced.
final class LocalTrackPublishedEvent extends RoomEvent {
  /// Creates the event.
  const LocalTrackPublishedEvent(this.publication);

  /// The new publication.
  final LocalMediaPublication publication;

  @override
  String toString() => 'LocalTrackPublishedEvent(${publication.trackName})';
}

/// The local participant unpublished a track (or a screen share ended).
final class LocalTrackUnpublishedEvent extends RoomEvent {
  /// Creates the event.
  const LocalTrackUnpublishedEvent(this.publication);

  /// The closed publication.
  final LocalMediaPublication publication;

  @override
  String toString() => 'LocalTrackUnpublishedEvent(${publication.trackName})';
}

/// [Room.connectionState] changed.
final class RoomConnectionStateChangedEvent extends RoomEvent {
  /// Creates the event.
  const RoomConnectionStateChangedEvent(this.state);

  /// The new state.
  final RoomConnectionState state;

  @override
  String toString() => 'RoomConnectionStateChangedEvent(${state.name})';
}

/// The room's SFU session failed. The room is
/// [RoomConnectionState.disconnected] (until roadmap M5 reconnects
/// automatically); see [Room.failure].
final class RoomSessionFailedEvent extends RoomEvent {
  /// Creates the event.
  const RoomSessionFailedEvent(this.failure);

  /// Why the session failed.
  final SfuSessionFailure failure;

  @override
  String toString() => 'RoomSessionFailedEvent($failure)';
}

/// A background operation failed without breaking the room, for example a
/// signaling update. The room keeps going and tries again on the next
/// change.
final class RoomErrorEvent extends RoomEvent {
  /// Creates the event.
  const RoomErrorEvent(this.operation, this.error);

  /// What was being done, such as `signaling.update`.
  final String operation;

  /// The error.
  final Object error;

  @override
  String toString() => 'RoomErrorEvent($operation, $error)';
}
