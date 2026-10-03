/// @docImport 'room.dart';
library;

import '../quality/audio_level_source.dart';
import '../session/sfu_session.dart';

/// A pulled remote audio track that counts for active-speaker detection:
/// its participant and its session-level subscription.
typedef RoomAudioTrack = ({
  String participantId,
  RemoteTrackSubscription subscription,
});

/// The [Room]'s [AudioLevelSource]: reads the **current** SFU session's
/// `getStats()` and maps the reports to participants.
///
/// - **Binding.** The session is read on every poll. When it returns another
///   session than the last poll (roadmap M5 replaced it), the stats reader
///   is rebuilt, so energy baselines from the old peer connection never mix
///   with the new one's. [rebind] forces that.
/// - **Remote levels:** audio `inbound-rtp` reports, matched by `mid`, then
///   by `trackIdentifier`, against the room's remote audio: only subscriptions on the
///   current session count, so a `mid` the SFU reused maps to the current
///   pull. Screen-share audio should be left out.
/// - **Local level:** the audio `media-source` of the local microphone
///   track, under [localParticipantId]. While its track ID is `null` (no
///   microphone, or muted: the sender has no track), there is no local
///   level, so other local audio (such as screen-share audio) never counts
///   as the local participant speaking.
/// - Nothing to measure (no remote audio pulled and no microphone sending):
///   returns no levels without calling `getStats`. A closed or failed
///   session gives no levels either.
///
/// Internal: not exported from the package barrel.
class RoomAudioLevelSource implements AudioLevelSource {
  /// Creates a source over the room's current session, as returned by
  /// `session`; `remoteAudio` lists the pulled microphones and
  /// `localTrackId` returns the local microphone track's ID.
  RoomAudioLevelSource({
    required SfuSession? Function() session,
    required Iterable<RoomAudioTrack> Function() remoteAudio,
    this.localParticipantId,
    String? Function()? localTrackId,
  }) : _session = session,
       _remoteAudio = remoteAudio,
       _localTrackId = localTrackId;

  final SfuSession? Function() _session;
  final Iterable<RoomAudioTrack> Function() _remoteAudio;
  final String? Function()? _localTrackId;

  /// The key of the local microphone's level.
  final String? localParticipantId;

  SfuSession? _bound;
  StatsAudioLevelSource? _stats;
  final Map<String, String> _byMid = {};
  final Map<String, String> _byTrack = {};

  /// The session the last poll read, if any.
  SfuSession? get boundSession => _bound;

  /// Drops the stats reader, so the next poll starts afresh on whatever
  /// session is current. Called when the room's session is replaced.
  void rebind() {
    _bound = null;
    _stats = null;
  }

  @override
  Future<Map<String, double>> getAudioLevels() async {
    final session = _session();
    if (session == null || !session.isUsable) return const {};
    var stats = _stats;
    if (stats == null || !identical(session, _bound)) {
      _bound = session;
      stats = _stats = StatsAudioLevelSource(
        getStats: session.getStats,
        participantFor: _resolve,
        localParticipantId: localParticipantId,
        localTrackId: _localTrackId,
      );
    }

    _byMid.clear();
    _byTrack.clear();
    for (final (:participantId, :subscription) in _remoteAudio()) {
      if (!identical(subscription.session, session)) continue;
      final mid = subscription.mid;
      if (mid != null) _byMid[mid] = participantId;
      final trackId = subscription.track?.id;
      if (trackId != null) _byTrack[trackId] = participantId;
    }
    final localTrack = _localTrackId?.call();
    if (_byMid.isEmpty && _byTrack.isEmpty && localTrack == null) {
      return const {};
    }

    final levels = await stats.getAudioLevels();
    final localId = localParticipantId;
    if (localTrack == null && localId != null && levels.containsKey(localId)) {
      return {...levels}..remove(localId);
    }
    return levels;
  }

  String? _resolve(InboundAudioStream stream) {
    final mid = stream.mid;
    if (mid != null) {
      final participant = _byMid[mid];
      if (participant != null) return participant;
    }
    final trackId = stream.trackIdentifier;
    return trackId == null ? null : _byTrack[trackId];
  }
}
