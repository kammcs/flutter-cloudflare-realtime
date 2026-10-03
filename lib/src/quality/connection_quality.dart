import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../signaling/participant_state.dart';
import 'call_stats.dart';

/// How well a participant's media gets through (`docs/design.md` §7.1).
///
/// Ordered from worst to best, after [unknown]: compare with [index] or
/// [isAtLeast].
enum ConnectionQuality {
  /// Not measured yet (just joined, nothing received from them yet), or
  /// not measurable now (this client is reconnecting).
  unknown,

  /// Nothing gets through: this client is reconnecting or disconnected,
  /// or a remote participant's media stopped while they are still in the
  /// room.
  lost,

  /// Noticeable trouble: loss, delay or jitter high enough to break up
  /// audio or freeze video, or too little bandwidth to send video.
  poor,

  /// Usable, with some loss, delay, jitter or a bandwidth-limited sender.
  good,

  /// No measurable trouble.
  excellent;

  /// Whether this is [other] or better. [unknown] is below everything.
  bool isAtLeast(ConnectionQuality other) => index >= other.index;
}

/// The limits of one [ConnectionQuality] level: a measurement at or below
/// every limit is at least that level.
@immutable
final class QualityThresholds {
  /// Creates the limits.
  const QualityThresholds({
    required this.roundTripTime,
    required this.packetLoss,
    required this.jitter,
    required this.freezeRatio,
  });

  /// The round-trip time to the SFU (local participant only).
  final Duration roundTripTime;

  /// The fraction of packets lost, `0..1`.
  final double packetLoss;

  /// The audio interarrival jitter.
  final Duration jitter;

  /// The fraction of the time a received video was frozen, `0..1` (remote
  /// participants only).
  final double freezeRatio;

  @override
  bool operator ==(Object other) =>
      other is QualityThresholds &&
      other.roundTripTime == roundTripTime &&
      other.packetLoss == packetLoss &&
      other.jitter == jitter &&
      other.freezeRatio == freezeRatio;

  @override
  int get hashCode =>
      Object.hash(roundTripTime, packetLoss, jitter, freezeRatio);

  @override
  String toString() =>
      'QualityThresholds(rtt ${roundTripTime.inMilliseconds} ms, '
      'loss ${packetLoss * 100} %, jitter ${jitter.inMilliseconds} ms, '
      'frozen ${freezeRatio * 100} %)';
}

/// How connection quality is rated (`docs/design.md` §7.1).
@immutable
final class ConnectionQualityOptions {
  /// Creates a configuration; the defaults are explained in design.md.
  const ConnectionQualityOptions({
    this.excellent = const QualityThresholds(
      roundTripTime: Duration(milliseconds: 150),
      packetLoss: 0.01,
      jitter: Duration(milliseconds: 20),
      freezeRatio: 0,
    ),
    this.good = const QualityThresholds(
      roundTripTime: Duration(milliseconds: 300),
      packetLoss: 0.05,
      jitter: Duration(milliseconds: 50),
      freezeRatio: 0.1,
    ),
    this.minOutgoingVideoBitrate = 150000,
    this.degradeAfter = const Duration(seconds: 4),
    this.improveAfter = const Duration(seconds: 6),
    this.lostAfter = const Duration(seconds: 5),
  });

  /// The limits for [ConnectionQuality.excellent].
  final QualityThresholds excellent;

  /// The limits for [ConnectionQuality.good]; anything worse is
  /// [ConnectionQuality.poor].
  final QualityThresholds good;

  /// Below this outgoing bandwidth estimate (bits per second) while sending
  /// video, the local participant is [ConnectionQuality.poor]: not even
  /// the lowest simulcast layer and audio fit.
  final int minOutgoingVideoBitrate;

  /// How long measurements must stay below the current level before it
  /// drops.
  final Duration degradeAfter;

  /// How long measurements must stay above the current level before it
  /// rises. Longer than [degradeAfter], so a recovering link doesn't flap.
  final Duration improveAfter;

  /// How long a remote participant's media may stop (nothing received on
  /// any of their pulled, unmuted tracks) before they are
  /// [ConnectionQuality.lost].
  final Duration lostAfter;

  @override
  bool operator ==(Object other) =>
      other is ConnectionQualityOptions &&
      other.excellent == excellent &&
      other.good == good &&
      other.minOutgoingVideoBitrate == minOutgoingVideoBitrate &&
      other.degradeAfter == degradeAfter &&
      other.improveAfter == improveAfter &&
      other.lostAfter == lostAfter;

  @override
  int get hashCode => Object.hash(
    excellent,
    good,
    minOutgoingVideoBitrate,
    degradeAfter,
    improveAfter,
    lostAfter,
  );
}

/// Typed stats and connection quality in a room (`RoomOptions.stats`).
@immutable
final class RoomStatsOptions {
  /// Creates the options.
  const RoomStatsOptions({
    this.interval = const Duration(seconds: 2),
    this.connectionQuality = const ConnectionQualityOptions(),
  });

  /// How often the room reads `getStats()` while someone listens to
  /// `Room.stats` (or a publication's `stats`), and for connection
  /// quality.
  final Duration interval;

  /// How connection quality is rated, or `null` to turn it off: then the
  /// room reads stats only while someone listens to them, and every
  /// participant's quality stays [ConnectionQuality.unknown].
  final ConnectionQualityOptions? connectionQuality;

  @override
  bool operator ==(Object other) =>
      other is RoomStatsOptions &&
      other.interval == interval &&
      other.connectionQuality == connectionQuality;

  @override
  int get hashCode => Object.hash(interval, connectionQuality);
}

// -----------------------------------------------------------------------------
// Rating (internal)
// -----------------------------------------------------------------------------

/// What one stats interval measured for one participant. `null` fields
/// weren't measured.
///
/// Internal: not exported from the package barrel.
@immutable
class QualitySample {
  /// Creates a sample.
  const QualitySample({
    this.roundTripTime,
    this.packetLoss,
    this.jitter,
    this.freezeRatio,
    this.bandwidthLimited = false,
    this.starved = false,
  });

  /// The round-trip time.
  final Duration? roundTripTime;

  /// The fraction of packets lost.
  final double? packetLoss;

  /// The audio jitter.
  final Duration? jitter;

  /// The fraction of the interval a video was frozen.
  final double? freezeRatio;

  /// A sending video layer is limited by bandwidth.
  final bool bandwidthLimited;

  /// Video is being sent with less bandwidth than the lowest layer needs.
  final bool starved;

  /// Whether anything was measured.
  bool get isEmpty =>
      roundTripTime == null &&
      packetLoss == null &&
      jitter == null &&
      freezeRatio == null &&
      !bandwidthLimited &&
      !starved;

  @override
  String toString() =>
      'QualitySample(rtt: ${roundTripTime?.inMilliseconds}, loss: $packetLoss, '
      'jitter: ${jitter?.inMilliseconds}, frozen: $freezeRatio'
      '${bandwidthLimited ? ', bandwidth-limited' : ''}'
      '${starved ? ', starved' : ''})';
}

/// Rates a [QualitySample]: the worst metric decides. Returns `null` when
/// nothing was measured.
///
/// Internal: not exported from the package barrel.
ConnectionQuality? rateQuality(
  QualitySample sample,
  ConnectionQualityOptions config,
) {
  if (sample.isEmpty) return null;
  if (sample.starved) return ConnectionQuality.poor;
  bool within(QualityThresholds t) =>
      (sample.roundTripTime == null ||
          sample.roundTripTime! <= t.roundTripTime) &&
      (sample.packetLoss == null || sample.packetLoss! <= t.packetLoss) &&
      (sample.jitter == null || sample.jitter! <= t.jitter) &&
      (sample.freezeRatio == null || sample.freezeRatio! <= t.freezeRatio);
  if (within(config.excellent) && !sample.bandwidthLimited) {
    return ConnectionQuality.excellent;
  }
  if (within(config.good)) return ConnectionQuality.good;
  return ConnectionQuality.poor;
}

/// One participant's quality over time, with hysteresis
/// (`docs/design.md` §7.1):
///
/// - The first rating (from [ConnectionQuality.unknown]) and any rating
///   after [ConnectionQuality.lost] apply at once.
/// - [ConnectionQuality.lost] applies at once (its own timeout,
///   [ConnectionQualityOptions.lostAfter], is the caller's).
/// - Otherwise a lower level applies once ratings have stayed below the
///   current level for [ConnectionQualityOptions.degradeAfter], and a higher
///   one once they have stayed above it for
///   [ConnectionQualityOptions.improveAfter]. The new level is the
///   **closest** to the current one among those ratings, so a link that
///   alternates between good and poor while excellent drops to good. A
///   rating back at the current level, or on the other side, restarts the
///   count.
/// - No rating (nothing measured) keeps the level and the counts.
///
/// Internal: not exported from the package barrel.
class QualityTracker {
  /// Creates a tracker at [ConnectionQuality.unknown].
  QualityTracker(this.config);

  /// The timings.
  final ConnectionQualityOptions config;

  ConnectionQuality _current = ConnectionQuality.unknown;
  Duration _below = Duration.zero;
  Duration _above = Duration.zero;
  ConnectionQuality? _belowBest;
  ConnectionQuality? _aboveWorst;

  /// The current level.
  ConnectionQuality get current => _current;

  /// Feeds the rating of an interval of length [interval]; returns the
  /// level afterwards.
  ConnectionQuality add(ConnectionQuality? rating, Duration interval) {
    if (rating == null || rating == ConnectionQuality.unknown) return _current;
    if (rating == ConnectionQuality.lost ||
        _current == ConnectionQuality.unknown ||
        _current == ConnectionQuality.lost) {
      return set(rating);
    }
    if (rating == _current) {
      _clearCounts();
    } else if (rating.index < _current.index) {
      _above = Duration.zero;
      _aboveWorst = null;
      _below += interval;
      _belowBest = _belowBest == null
          ? rating
          : ConnectionQuality.values[math.max(_belowBest!.index, rating.index)];
      if (_below >= config.degradeAfter) return set(_belowBest!);
    } else {
      _below = Duration.zero;
      _belowBest = null;
      _above += interval;
      _aboveWorst = _aboveWorst == null
          ? rating
          : ConnectionQuality.values[math.min(
              _aboveWorst!.index,
              rating.index,
            )];
      if (_above >= config.improveAfter) return set(_aboveWorst!);
    }
    return _current;
  }

  /// Sets the level now, without hysteresis.
  ConnectionQuality set(ConnectionQuality quality) {
    _current = quality;
    _clearCounts();
    return quality;
  }

  void _clearCounts() {
    _below = Duration.zero;
    _above = Duration.zero;
    _belowBest = null;
    _aboveWorst = null;
  }
}

/// Builds the local participant's [QualitySample] from a snapshot: the
/// selected pair's round-trip time (else the SFU's receiver reports), the
/// loss and audio jitter the SFU reports for what is sent, a video layer
/// limited by bandwidth, and an outgoing estimate below
/// [ConnectionQualityOptions.minOutgoingVideoBitrate] while sending video.
///
/// Internal: not exported from the package barrel.
QualitySample localQualitySample(
  RoomStats stats,
  ConnectionQualityOptions config,
) {
  Duration? rtt = stats.connection?.roundTripTime;
  Duration? jitter;
  var lossWeighted = 0.0;
  var weight = 0;
  var bandwidthLimited = false;
  var sendingVideo = false;
  for (final track in stats.local.values) {
    for (final layer in track.layers) {
      final sending = (layer.bitrate ?? 0) > 0;
      final layerRtt = layer.roundTripTime;
      if (rtt == null && layerRtt != null && layerRtt > Duration.zero) {
        rtt = layerRtt;
      }
      if (!sending) continue;
      if (layer.fractionLost case final lost?) {
        // Weighted by bitrate, so a quiet audio stream's one lost packet
        // doesn't outweigh a video's thousands.
        final w = math.max(1, layer.bitrate! ~/ 1000);
        lossWeighted += lost * w;
        weight += w;
      }
      if (track.kind == TrackKind.audio && layer.jitter != null) {
        jitter = jitter == null || layer.jitter! > jitter
            ? layer.jitter
            : jitter;
      }
      if (track.kind == TrackKind.video) {
        sendingVideo = true;
        if (layer.qualityLimitationReason ==
            QualityLimitationReason.bandwidth) {
          bandwidthLimited = true;
        }
      }
    }
  }
  final available = stats.connection?.availableOutgoingBitrate;
  return QualitySample(
    roundTripTime: rtt == Duration.zero ? null : rtt,
    packetLoss: weight == 0 ? null : lossWeighted / weight,
    jitter: jitter,
    bandwidthLimited: bandwidthLimited,
    starved:
        sendingVideo &&
        available != null &&
        available < config.minOutgoingVideoBitrate,
  );
}

/// Builds a remote participant's [QualitySample] from their pulled tracks
/// in a snapshot ([tracks]; with [previous], the same tracks in the
/// previous snapshot, for packet counts): the loss over all their packets,
/// the worst audio jitter, and the worst share of the interval a video was
/// frozen. Video jitter is left out: frames go out in bursts, which
/// inflates it without hurting anyone.
///
/// Internal: not exported from the package barrel.
QualitySample remoteQualitySample(
  Iterable<RemoteTrackStats> tracks,
  Map<String, RemoteTrackStats> previous,
  Duration? interval,
) {
  var lost = 0;
  var received = 0;
  var counted = false;
  Duration? jitter;
  double? frozen;
  for (final track in tracks) {
    final before = previous[track.publicationId];
    if (before != null) {
      final dReceived = _delta(track.packetsReceived, before.packetsReceived);
      final dLost = _delta(track.packetsLost, before.packetsLost);
      if (dReceived != null && dLost != null && dReceived >= 0) {
        counted = true;
        received += dReceived;
        lost += math.max(0, dLost);
      }
    }
    final flowing = (track.bitrate ?? 0) > 0;
    if (track.kind == TrackKind.audio && flowing && track.jitter != null) {
      jitter = jitter == null || track.jitter! > jitter ? track.jitter : jitter;
    }
    if (track.kind == TrackKind.video &&
        flowing &&
        before != null &&
        interval != null &&
        interval > Duration.zero) {
      final now = track.totalFreezesDuration;
      final then = before.totalFreezesDuration;
      if (now != null && then != null && now >= then) {
        final ratio = ((now - then).inMicroseconds / interval.inMicroseconds)
            .clamp(0.0, 1.0)
            .toDouble();
        frozen = frozen == null ? ratio : math.max(frozen, ratio);
      }
    }
  }
  final total = lost + received;
  return QualitySample(
    packetLoss: !counted || total == 0 ? null : lost / total,
    jitter: jitter,
    freezeRatio: frozen,
  );
}

int? _delta(int? now, int? before) =>
    now == null || before == null ? null : now - before;
