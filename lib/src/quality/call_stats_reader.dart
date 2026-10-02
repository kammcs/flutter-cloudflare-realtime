import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import '../signaling/participant_state.dart';
import 'call_stats.dart';

/// A local published track to find in the reports: its `mid` on the
/// current session and the ID of the track it sends (null while muted).
typedef LocalTrackRef = ({
  String trackName,
  TrackKind kind,
  TrackSource source,
  String? mid,
  String? trackId,
});

/// A pulled remote track to find in the reports.
typedef RemoteTrackRef = ({
  String id,
  String participantId,
  String trackName,
  TrackKind kind,
  TrackSource source,
  String? mid,
  String? trackId,
  String? rid,
});

/// Turns raw `getStats()` reports into [RoomStats] (`docs/design.md` §7.1).
///
/// - **Mapping.** A local track's `outbound-rtp` reports (one per simulcast
///   layer) are found by `mid`, else through the `media-source` whose
///   `trackIdentifier` is the sent track (`mediaSourceId`). Each one's
///   `remote-inbound-rtp` (the SFU's receiver reports) by `remoteId`, else
///   `localId`, else `ssrc`. A remote track's `inbound-rtp` by `mid`, else
///   by `trackIdentifier`. Codecs by `codecId`. The connection is the
///   transport's `selectedCandidatePairId`, else the pair marked
///   `selected` (Firefox), else the nominated, succeeded pair that carried
///   the most bytes.
/// - **Rates** come from the change of each report's counters since the
///   previous [read] (per report `id`, which stays the same for one RTP
///   stream). The interval is the reports' own `timestamp` difference when
///   it is plausible (µs on native platforms, ms on the web; within a
///   factor of two of the wall time between the reads), else the wall time
///   from [elapsed]. A counter that went down (a reset) gives no rate.
/// - **Missing values are `null`.** Numbers may arrive as numbers or as
///   numeric strings; `kind` may be `mediaType` on older platforms.
///
/// Call [reset] when the reports start coming from another peer
/// connection (the room replaced its session), so no rate mixes the two.
///
/// Internal: not exported from the package barrel.
class CallStatsReader {
  /// Creates a reader. [elapsed] is a monotonic clock (tests pass fake
  /// time); [now] stamps the snapshots.
  CallStatsReader({
    required this._elapsed,
    DateTime Function()? now,
    this.timestampsInMicroseconds = !kIsWeb,
  }) : _now = now ?? DateTime.now;

  final Duration Function() _elapsed;
  final DateTime Function() _now;

  /// Whether report timestamps are in microseconds (native libwebrtc)
  /// rather than milliseconds (browsers).
  final bool timestampsInMicroseconds;

  final Map<String, _Previous> _previous = {};
  Duration? _lastRead;

  /// Forgets every previous counter: the next [read] has no rates.
  void reset() {
    _previous.clear();
    _lastRead = null;
  }

  /// Builds a snapshot from [reports], for the [local] and [remote] tracks.
  RoomStats read(
    List<StatsReport> reports, {
    List<LocalTrackRef> local = const [],
    List<RemoteTrackRef> remote = const [],
  }) {
    final at = _elapsed();
    final byId = {for (final r in reports) r.id: r};
    final rates = _Rates(this, at);
    final snapshot = RoomStats(
      timestamp: _now(),
      interval: _lastRead == null ? null : at - _lastRead!,
      connection: _connection(reports, byId, rates),
      local: {
        for (final ref in local)
          ref.trackName: ?_local(ref, reports, byId, rates),
      },
      remote: {
        for (final ref in remote) ref.id: ?_remote(ref, reports, byId, rates),
      },
      reports: List.unmodifiable(reports),
    );
    // Keep only what was seen, so the map doesn't grow across renegotiations.
    _previous
      ..removeWhere((id, _) => !rates.seen.contains(id))
      ..addAll(rates.next);
    _lastRead = at;
    return snapshot;
  }

  // ---------------------------------------------------------------------------
  // The connection
  // ---------------------------------------------------------------------------

  ConnectionStats? _connection(
    List<StatsReport> reports,
    Map<String, StatsReport> byId,
    _Rates rates,
  ) {
    StatsReport? pair;
    for (final r in reports) {
      if (r.type != 'transport') continue;
      final found = byId[str(r.values['selectedCandidatePairId'])];
      if (found != null) {
        pair = found;
        break;
      }
    }
    if (pair == null) {
      for (final r in reports) {
        if (r.type == 'candidate-pair' &&
            boolean(r.values['selected']) == true) {
          pair = r;
          break;
        }
      }
    }
    if (pair == null) {
      var best = -1;
      for (final r in reports) {
        if (r.type != 'candidate-pair') continue;
        final v = r.values;
        if (boolean(v['nominated']) != true || str(v['state']) != 'succeeded') {
          continue;
        }
        final bytes =
            (integer(v['bytesSent']) ?? 0) + (integer(v['bytesReceived']) ?? 0);
        if (bytes > best) {
          best = bytes;
          pair = r;
        }
      }
    }
    if (pair == null) return null;
    final v = pair.values;
    IceCandidateStats? candidate(Object? id) {
      final report = byId[str(id)];
      if (report == null) return null;
      final c = report.values;
      return IceCandidateStats(
        type: IceCandidateType.parse(c['candidateType']),
        protocol: str(c['protocol']),
        relayProtocol: str(c['relayProtocol']),
        networkType: str(c['networkType']),
      );
    }

    final bytesSent = integer(v['bytesSent']);
    final bytesReceived = integer(v['bytesReceived']);
    final r = rates.of(pair, const ['bytesSent', 'bytesReceived']);
    return ConnectionStats(
      roundTripTime: seconds(v['currentRoundTripTime']),
      availableOutgoingBitrate: integer(v['availableOutgoingBitrate']),
      availableIncomingBitrate: integer(v['availableIncomingBitrate']),
      localCandidate: candidate(v['localCandidateId']),
      remoteCandidate: candidate(v['remoteCandidateId']),
      bytesSent: bytesSent,
      bytesReceived: bytesReceived,
      sendBitrate: r.bitrate('bytesSent'),
      receiveBitrate: r.bitrate('bytesReceived'),
    );
  }

  // ---------------------------------------------------------------------------
  // Local tracks
  // ---------------------------------------------------------------------------

  LocalTrackStats? _local(
    LocalTrackRef ref,
    List<StatsReport> reports,
    Map<String, StatsReport> byId,
    _Rates rates,
  ) {
    final kind = ref.kind.name;
    StatsReport? source;
    if (ref.trackId case final trackId?) {
      for (final r in reports) {
        if (r.type == 'media-source' &&
            str(r.values['trackIdentifier']) == trackId) {
          source = r;
          break;
        }
      }
    }
    final outbound = [
      for (final r in reports)
        if (r.type == 'outbound-rtp' &&
            kindOf(r) == kind &&
            ((ref.mid != null && str(r.values['mid']) == ref.mid) ||
                (source != null &&
                    str(r.values['mediaSourceId']) == source.id)))
          r,
    ];
    if (outbound.isEmpty) return null;
    outbound.sort(_layerOrder);
    return LocalTrackStats(
      trackName: ref.trackName,
      kind: ref.kind,
      source: ref.source,
      layers: [for (final r in outbound) _layer(r, reports, byId, rates)],
      audioLevel: ref.kind == TrackKind.audio && source != null
          ? decimal(source.values['audioLevel'])
          : null,
    );
  }

  static int _layerOrder(StatsReport a, StatsReport b) {
    final ia = integer(a.values['encodingIndex']);
    final ib = integer(b.values['encodingIndex']);
    if (ia != null && ib != null && ia != ib) return ia.compareTo(ib);
    final ra = str(a.values['rid']);
    final rb = str(b.values['rid']);
    if (ra != null && rb != null) return ra.compareTo(rb);
    if (ra != null) return -1;
    if (rb != null) return 1;
    return 0;
  }

  OutboundLayerStats _layer(
    StatsReport report,
    List<StatsReport> reports,
    Map<String, StatsReport> byId,
    _Rates rates,
  ) {
    final v = report.values;
    final remote = _remoteInbound(report, reports, byId);
    final rv = remote?.values;
    final r = rates.of(report, const [
      'bytesSent',
      'framesSent',
      'framesEncoded',
    ]);
    final fps =
        decimal(v['framesPerSecond']) ??
        r.perSecond('framesSent') ??
        r.perSecond('framesEncoded');
    return OutboundLayerStats(
      rid: str(v['rid']),
      active: boolean(v['active']),
      codec: _codec(v, byId),
      bitrate: r.bitrate('bytesSent'),
      targetBitrate: integer(v['targetBitrate']),
      width: integer(v['frameWidth']),
      height: integer(v['frameHeight']),
      framesPerSecond: fps,
      qualityLimitationReason: QualityLimitationReason.parse(
        v['qualityLimitationReason'],
      ),
      packetsSent: integer(v['packetsSent']),
      bytesSent: integer(v['bytesSent']),
      retransmittedPacketsSent: integer(v['retransmittedPacketsSent']),
      framesEncoded: integer(v['framesEncoded']),
      keyFramesEncoded: integer(v['keyFramesEncoded']),
      nackCount: integer(v['nackCount']),
      pliCount: integer(v['pliCount']),
      firCount: integer(v['firCount']),
      encoderImplementation: str(v['encoderImplementation']),
      roundTripTime: rv == null ? null : seconds(rv['roundTripTime']),
      packetsLost: rv == null ? null : integer(rv['packetsLost']),
      fractionLost: rv == null ? null : decimal(rv['fractionLost']),
      jitter: rv == null ? null : seconds(rv['jitter']),
    );
  }

  StatsReport? _remoteInbound(
    StatsReport outbound,
    List<StatsReport> reports,
    Map<String, StatsReport> byId,
  ) {
    final remoteId = str(outbound.values['remoteId']);
    if (remoteId != null) {
      final found = byId[remoteId];
      if (found != null && found.type == 'remote-inbound-rtp') return found;
    }
    final ssrc = outbound.values['ssrc'];
    for (final r in reports) {
      if (r.type != 'remote-inbound-rtp') continue;
      if (str(r.values['localId']) == outbound.id) return r;
    }
    if (ssrc == null) return null;
    for (final r in reports) {
      if (r.type == 'remote-inbound-rtp' && '${r.values['ssrc']}' == '$ssrc') {
        return r;
      }
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Remote tracks
  // ---------------------------------------------------------------------------

  RemoteTrackStats? _remote(
    RemoteTrackRef ref,
    List<StatsReport> reports,
    Map<String, StatsReport> byId,
    _Rates rates,
  ) {
    final kind = ref.kind.name;
    StatsReport? inbound;
    if (ref.mid case final mid?) {
      for (final r in reports) {
        if (r.type == 'inbound-rtp' &&
            kindOf(r) == kind &&
            str(r.values['mid']) == mid) {
          inbound = r;
          break;
        }
      }
    }
    if (inbound == null && ref.trackId != null) {
      for (final r in reports) {
        if (r.type == 'inbound-rtp' &&
            kindOf(r) == kind &&
            str(r.values['trackIdentifier']) == ref.trackId) {
          inbound = r;
          break;
        }
      }
    }
    if (inbound == null) return null;
    final v = inbound.values;
    final r = rates.of(inbound, const [
      'bytesReceived',
      'packetsReceived',
      'packetsLost',
      'framesDecoded',
      'concealedSamples',
      'totalSamplesReceived',
    ]);
    double? loss;
    final dLost = r.delta('packetsLost');
    final dReceived = r.delta('packetsReceived');
    if (dLost != null && dReceived != null) {
      final lost = dLost < 0 ? 0 : dLost;
      final total = lost + dReceived;
      loss = total <= 0 ? 0 : lost / total;
    }
    double? concealment;
    final dConcealed = r.delta('concealedSamples');
    final dSamples = r.delta('totalSamplesReceived');
    if (dConcealed != null && dSamples != null) {
      concealment = dSamples <= 0
          ? null
          : (dConcealed / dSamples).clamp(0.0, 1.0).toDouble();
    }
    return RemoteTrackStats(
      publicationId: ref.id,
      participantId: ref.participantId,
      trackName: ref.trackName,
      kind: ref.kind,
      source: ref.source,
      rid: ref.rid,
      codec: _codec(v, byId),
      bitrate: r.bitrate('bytesReceived'),
      width: integer(v['frameWidth']),
      height: integer(v['frameHeight']),
      framesPerSecond:
          decimal(v['framesPerSecond']) ?? r.perSecond('framesDecoded'),
      packetsReceived: integer(v['packetsReceived']),
      packetsLost: integer(v['packetsLost']),
      bytesReceived: integer(v['bytesReceived']),
      packetLoss: loss,
      jitter: seconds(v['jitter']),
      framesDecoded: integer(v['framesDecoded']),
      keyFramesDecoded: integer(v['keyFramesDecoded']),
      framesDropped: integer(v['framesDropped']),
      freezeCount: integer(v['freezeCount']),
      totalFreezesDuration: seconds(v['totalFreezesDuration']),
      nackCount: integer(v['nackCount']),
      pliCount: integer(v['pliCount']),
      firCount: integer(v['firCount']),
      audioLevel: decimal(v['audioLevel']),
      totalSamplesReceived: integer(v['totalSamplesReceived']),
      concealedSamples: integer(v['concealedSamples']),
      concealmentEvents: integer(v['concealmentEvents']),
      concealment: concealment,
      decoderImplementation: str(v['decoderImplementation']),
    );
  }

  static String? _codec(
    Map<dynamic, dynamic> values,
    Map<String, StatsReport> byId,
  ) {
    final codec = byId[str(values['codecId'])];
    if (codec == null || codec.type != 'codec') return null;
    return str(codec.values['mimeType']);
  }

  // ---------------------------------------------------------------------------
  // Value parsing
  // ---------------------------------------------------------------------------

  /// The report's media kind: `kind`, or the older `mediaType`.
  static String? kindOf(StatsReport report) =>
      str(report.values['kind'] ?? report.values['mediaType']);

  /// A string, or `null`.
  static String? str(Object? value) => value is String ? value : null;

  /// A finite number from a number or a numeric string, or `null`.
  static num? number(Object? value) {
    final n = switch (value) {
      final num n => n,
      final String s => num.tryParse(s),
      _ => null,
    };
    return n == null || !n.isFinite ? null : n;
  }

  /// An integer (rounded), or `null`.
  static int? integer(Object? value) => number(value)?.round();

  /// A double, or `null`.
  static double? decimal(Object? value) => number(value)?.toDouble();

  /// A boolean from a bool or `'true'`/`'false'`, or `null`.
  static bool? boolean(Object? value) => switch (value) {
    final bool b => b,
    'true' => true,
    'false' => false,
    _ => null,
  };

  /// A duration from a number of seconds (W3C stats use seconds), or `null`.
  static Duration? seconds(Object? value) {
    final s = decimal(value);
    if (s == null || s < 0) return null;
    return Duration(microseconds: (s * 1e6).round());
  }
}

/// The counters of one report at one read.
class _Previous {
  _Previous(this.at, this.timestamp, this.counters);

  final Duration at;
  final double timestamp;
  final Map<String, num> counters;
}

/// Rates for the reports of one read.
class _Rates {
  _Rates(this._reader, this._at);

  final CallStatsReader _reader;
  final Duration _at;

  /// The report IDs seen in this read.
  final Set<String> seen = {};

  /// What to remember for the next read.
  final Map<String, _Previous> next = {};

  _ReportRates of(StatsReport report, List<String> counters) {
    seen.add(report.id);
    final now = <String, num>{
      for (final name in counters)
        name: ?CallStatsReader.number(report.values[name]),
    };
    final existing = next[report.id];
    next[report.id] = _Previous(_at, report.timestamp, {
      ...?existing?.counters,
      ...now,
    });
    final previous = _reader._previous[report.id];
    if (previous == null) return _ReportRates(null, now, const {});
    return _ReportRates(
      _interval(previous, report.timestamp),
      now,
      previous.counters,
    );
  }

  /// Seconds between [previous] and now: the reports' timestamps when
  /// plausible, else the wall time.
  double? _interval(_Previous previous, double timestamp) {
    final wall = (_at - previous.at).inMicroseconds / 1e6;
    if (wall <= 0) return null;
    if (timestamp > 0 && previous.timestamp > 0) {
      final unit = _reader.timestampsInMicroseconds ? 1e6 : 1e3;
      final reported = (timestamp - previous.timestamp) / unit;
      if (reported > wall / 2 && reported < wall * 2) return reported;
    }
    return wall;
  }
}

class _ReportRates {
  _ReportRates(this._seconds, this._now, this._before);

  final double? _seconds;
  final Map<String, num> _now;
  final Map<String, num> _before;

  /// The counter's growth since the previous read, or `null` (no previous
  /// read, missing, or reset).
  num? delta(String name) {
    final now = _now[name];
    final before = _before[name];
    if (now == null || before == null || _seconds == null) return null;
    // packetsLost may legitimately go down (duplicates); other counters
    // going down means a reset.
    if (now < before && name != 'packetsLost') return null;
    return now - before;
  }

  /// The counter's growth per second.
  double? perSecond(String name) {
    final d = delta(name);
    final s = _seconds;
    if (d == null || s == null || s <= 0) return null;
    return d / s;
  }

  /// A byte counter's growth in bits per second.
  int? bitrate(String name) {
    final rate = perSecond(name);
    return rate == null ? null : (rate * 8).round();
  }
}
