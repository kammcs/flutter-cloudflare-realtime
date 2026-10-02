part of 'room.dart';

/// The room's active-speaker detection (`docs/design.md` §7): an
/// [ActiveSpeakerMonitor] polling the current session's stats through a
/// [RoomAudioLevelSource].
///
/// It polls for as long as the room is joined (unless
/// [RoomOptions.activeSpeaker] is `null`), not only while someone listens:
/// the synchronous getters ([Room.currentActiveSpeakers],
/// [RemoteParticipant.isSpeaking]) must be right without a listener, and
/// the detector's smoothing and hold times need a continuous series of
/// samples. A poll costs one `getStats()` call every
/// [ActiveSpeakerConfig.pollInterval], and none at all while there is no
/// audio to measure (see [RoomAudioLevelSource]).
class _RoomSpeakers {
  _RoomSpeakers(this._room) {
    final localId = _room.localParticipant.participantId;
    levels = RoomAudioLevelSource(
      session: () => _room._session,
      remoteAudio: _remoteAudio,
      localParticipantId: localId,
      localTrackId: _microphoneTrackId,
    );
    // `clock` so tests can run the detector on fake time.
    final stopwatch = clock.stopwatch()..start();
    monitor = ActiveSpeakerMonitor(
      source: levels,
      config: _room.options.activeSpeaker ?? const ActiveSpeakerConfig(),
      localParticipantId: localId,
      clock: () => stopwatch.elapsed,
    );
  }

  final Room _room;
  late final RoomAudioLevelSource levels;
  late final ActiveSpeakerMonitor monitor;
  StreamSubscription<LocalParticipant>? _localChanges;

  bool get enabled => _room.options.activeSpeaker != null;

  void start() {
    if (!enabled || _room._left) return;
    _syncLocalMuted();
    _localChanges = _room.localParticipant.changes.listen(
      (_) => _syncLocalMuted(),
    );
    monitor.start();
  }

  /// The room's session was replaced: read the new one from the next poll.
  void rebind() => levels.rebind();

  void removeParticipant(String participantId) =>
      monitor.removeParticipant(participantId);

  /// Stops polling; nobody is speaking any more.
  void stop() => monitor.stop();

  Future<void> dispose() async {
    monitor.stop();
    final changes = _localChanges;
    _localChanges = null;
    unawaited(changes?.cancel());
    await monitor.dispose();
  }

  void _syncLocalMuted() {
    monitor.localMuted = _room.localParticipant.microphone?.muted ?? true;
  }

  String? _microphoneTrackId() =>
      _room.localParticipant.microphone?.publication.track?.id;

  Iterable<RoomAudioTrack> _remoteAudio() sync* {
    for (final remote in _room._remotes.values) {
      for (final publication in remote._publications.values) {
        // Screen-share audio isn't someone speaking.
        if (publication.source != TrackSource.microphone) continue;
        final subscription = publication._subscription;
        if (subscription == null) continue;
        yield (participantId: remote.participantId, subscription: subscription);
      }
    }
  }
}

/// Room hooks for the session lifecycle (roadmap M5).
extension _RoomSessionHooks on Room {
  /// Call after replacing [Room._session] with a new session.
  ///
  /// Everything else follows the new session by itself: stats polling reads
  /// [Room._session] on every poll and rebuilds its reader when the session
  /// changed; layer selection sends `tracks/update` for pulls on whatever
  /// session they are on, and re-applies the chosen layer after each
  /// (re)pull. This only makes the switch immediate.
  void _onSessionReplaced() {
    _speakers.rebind();
    _stats.rebind();
  }
}
