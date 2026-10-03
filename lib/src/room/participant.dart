part of 'room.dart';

/// A participant in a [Room]: this client ([LocalParticipant]) or another
/// one ([RemoteParticipant]). What both have in common.
sealed class Participant {
  /// The participant's ID, unique in the room.
  String get participantId;

  /// The app data announced with the participant, such as a display name.
  Map<String, Object?>? get metadata;

  /// Whether the participant is speaking now ([Room.activeSpeakersChanges]).
  bool get isSpeaking;

  /// How well the participant's media gets through (`docs/design.md`
  /// §7.1): for this client, its own connection to the SFU; for others,
  /// what arrives from them. [ConnectionQuality.unknown] until measured,
  /// and always when [RoomStatsOptions.connectionQuality] is `null`.
  ConnectionQuality get connectionQuality;

  /// [connectionQuality], replaying the current value to each new
  /// listener, then its changes ([ParticipantConnectionQualityChangedEvent]).
  /// Completes when the participant leaves (or after [Room.leave]).
  Stream<ConnectionQuality> get connectionQualityChanges;
}
