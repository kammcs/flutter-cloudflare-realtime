import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCPeerConnection, StatsReport;

/// Reads the current audio level of each participant.
///
/// The active-speaker poller calls [getAudioLevels] every
/// `ActiveSpeakerConfig.pollInterval`. Implementations return participant ID
/// to level, `0..1`; a participant without a reading is simply absent.
///
/// Internal: not exported from the package barrel.
abstract interface class AudioLevelSource {
  /// Returns the audio level of each participant with a reading now.
  Future<Map<String, double>> getAudioLevels();
}

/// Identifies one received audio stream in a `getStats()` report.
@immutable
class InboundAudioStream {
  /// Creates an identifier.
  const InboundAudioStream({this.trackIdentifier, this.mid});

  /// The receiving `MediaStreamTrack`'s ID (`trackIdentifier`), if
  /// reported.
  final String? trackIdentifier;

  /// The transceiver's `mid`, if reported. For pulled SFU tracks, this is
  /// the `mid` the `tracks/new` response returned.
  final String? mid;

  @override
  bool operator ==(Object other) =>
      other is InboundAudioStream &&
      other.trackIdentifier == trackIdentifier &&
      other.mid == mid;

  @override
  int get hashCode => Object.hash(trackIdentifier, mid);

  @override
  String toString() => 'InboundAudioStream(track: $trackIdentifier, mid: $mid)';
}

/// Maps a received audio stream to the participant it belongs to, or
/// `null` to ignore it (an unknown stream, or screen-share audio, which
/// shouldn't count as speaking).
typedef InboundAudioResolver = String? Function(InboundAudioStream stream);

/// An [AudioLevelSource] that reads WebRTC `getStats()` reports.
///
/// - **Remote participants:** `inbound-rtp` reports with `kind: "audio"`.
///   [participantFor] maps each one's `trackIdentifier`/`mid` to a
///   participant. When several streams map to one participant, the loudest
///   wins.
/// - **Local participant:** `media-source` reports with `kind: "audio"`,
///   under [localParticipantId]. If [localTrackId] returns an ID, only the
///   matching source counts (so screen-share audio doesn't); otherwise the
///   loudest audio source does.
///
/// **Level.** A report's `audioLevel` is used when present. Otherwise the
/// level is derived from the growth of `totalAudioEnergy` and
/// `totalSamplesDuration` since the previous poll, as
/// `sqrt(ΔtotalAudioEnergy / ΔtotalSamplesDuration)` (the RMS of
/// `audioLevel` over the interval, per the W3C stats spec). That needs two
/// polls, so the first poll of such a stream has no reading; if the
/// duration didn't grow (no audio arrived), the level is 0.
///
/// **What `flutter_webrtc` 1.6.x reports** (checked against 1.6.2+hotfix.3
/// and `dart_webrtc` 1.8.2):
///
/// - All platforms return the standard W3C stats: `type`, then the
///   members in `values` (native platforms copy libwebrtc's members,
///   the web copies the browser's `RTCStatsReport` entries).
/// - Native libwebrtc (Android, iOS, macOS, Windows, Linux) has
///   `audioLevel`, `totalAudioEnergy` and `totalSamplesDuration` on
///   audio `inbound-rtp` and `media-source`, plus `trackIdentifier` and
///   `mid` on `inbound-rtp`. The legacy `track` stats type is gone.
/// - Browsers vary: Chrome and Safari match libwebrtc; Firefox has
///   historically lacked `audioLevel` on some report types, which is what
///   the energy fallback is for.
/// - Report `timestamp`s differ in unit between native (µs) and web (ms),
///   so this class never uses them.
/// - A muted local microphone may have no `media-source` report at all
///   (the sender has no track after `replaceTrack(null)`), or report
///   silence (a disabled track). "Speaking while muted" then needs the
///   Room to keep a live track attached somewhere; see design.md §7.
///
/// Internal: not exported from the package barrel.
class StatsAudioLevelSource implements AudioLevelSource {
  /// Creates a source that reads stats from [getStats].
  StatsAudioLevelSource({
    required Future<List<StatsReport>> Function() getStats,
    required this.participantFor,
    this.localParticipantId,
    this.localTrackId,
  }) : _getStats = getStats;

  /// Creates a source that reads [peerConnection]'s stats.
  factory StatsAudioLevelSource.peerConnection(
    RTCPeerConnection peerConnection, {
    required InboundAudioResolver participantFor,
    String? localParticipantId,
    String? Function()? localTrackId,
  }) => StatsAudioLevelSource(
    getStats: peerConnection.getStats,
    participantFor: participantFor,
    localParticipantId: localParticipantId,
    localTrackId: localTrackId,
  );

  final Future<List<StatsReport>> Function() _getStats;

  /// Maps received audio streams to participants.
  final InboundAudioResolver participantFor;

  /// The key for the local microphone level, or `null` to skip it.
  final String? localParticipantId;

  /// Returns the local microphone track's ID, to pick its `media-source`.
  final String? Function()? localTrackId;

  final Map<String, ({double energy, double duration})> _previous = {};

  @override
  Future<Map<String, double>> getAudioLevels() async {
    final reports = await _getStats();
    final levels = <String, double>{};
    final seen = <String>{};
    final localId = localParticipantId;
    final wantedLocalTrack = localTrackId?.call();

    void put(String participant, double level) {
      final current = levels[participant];
      if (current == null || level > current) levels[participant] = level;
    }

    for (final report in reports) {
      final values = report.values;
      if (_string(values['kind'] ?? values['mediaType']) != 'audio') continue;
      switch (report.type) {
        case 'inbound-rtp':
          seen.add(report.id);
          final level = _levelOf(report);
          if (level == null) continue;
          final participant = participantFor(
            InboundAudioStream(
              trackIdentifier: _string(values['trackIdentifier']),
              mid: _string(values['mid']),
            ),
          );
          if (participant != null) put(participant, level);
        case 'media-source':
          seen.add(report.id);
          final level = _levelOf(report);
          if (level == null || localId == null) continue;
          if (wantedLocalTrack != null &&
              _string(values['trackIdentifier']) != wantedLocalTrack) {
            continue;
          }
          put(localId, level);
      }
    }
    _previous.removeWhere((id, _) => !seen.contains(id));
    return levels;
  }

  double? _levelOf(StatsReport report) {
    final values = report.values;
    final energy = _double(values['totalAudioEnergy']);
    final duration = _double(values['totalSamplesDuration']);
    final previous = _previous[report.id];
    if (energy != null && duration != null) {
      _previous[report.id] = (energy: energy, duration: duration);
    }

    final audioLevel = _double(values['audioLevel']);
    if (audioLevel != null) return audioLevel.clamp(0.0, 1.0);

    if (energy == null || duration == null || previous == null) return null;
    final dDuration = duration - previous.duration;
    final dEnergy = energy - previous.energy;
    if (dDuration <= 0 || dEnergy < 0) return 0;
    return math.sqrt(dEnergy / dDuration).clamp(0.0, 1.0);
  }

  static String? _string(Object? value) => value is String ? value : null;

  static double? _double(Object? value) {
    if (value is num && value.isFinite) return value.toDouble();
    return null;
  }
}
