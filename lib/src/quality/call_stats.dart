import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import '../signaling/participant_state.dart';

/// Typed WebRTC statistics of a room (`docs/design.md` §7.1), taken from
/// one `getStats()` call on the room's session.
///
/// Counters (`packetsSent`, `bytesReceived`, ...) are the totals the
/// platform reports. Rates (`bitrate`, `packetLoss`, `concealment`, ...)
/// are computed from the change since the previous snapshot of the same
/// session, so the first snapshot after joining or a reconnection has
/// none. A value the platform doesn't report is `null`, never 0.
///
/// [reports] keeps the raw reports for anything not modelled here.
@immutable
final class RoomStats {
  /// Creates a snapshot.
  const RoomStats({
    required this.timestamp,
    this.interval,
    this.connection,
    this.local = const {},
    this.remote = const {},
    this.reports = const [],
  });

  /// When the snapshot was taken (`package:clock`'s `clock.now()`).
  final DateTime timestamp;

  /// The time since the previous snapshot of the same session, which the
  /// rates cover; `null` for the first one.
  final Duration? interval;

  /// The transport: the selected ICE candidate pair. `null` before the
  /// session has connected.
  final ConnectionStats? connection;

  /// The local participant's published tracks, by
  /// `LocalMediaPublication.trackName`. A track without reports (not
  /// pushed yet) is left out.
  final Map<String, LocalTrackStats> local;

  /// The pulled remote tracks, by `RemoteTrackPublication.id`
  /// (`participantId/trackName`). Only tracks pulled on the current
  /// session, and with reports, are present.
  final Map<String, RemoteTrackStats> remote;

  /// The raw reports this snapshot was built from.
  final List<StatsReport> reports;

  /// The remote tracks of [participantId].
  Iterable<RemoteTrackStats> remoteOf(String participantId) =>
      remote.values.where((t) => t.participantId == participantId);

  @override
  String toString() =>
      'RoomStats(${connection ?? 'no connection'}, '
      'local: ${local.values.toList()}, remote: ${remote.values.toList()})';
}

/// How an ICE candidate was found (RFC 8445): `host` (a local address),
/// `srflx` (the address a STUN server saw), `prflx` (learned from the
/// peer's checks) or `relay` (a TURN server).
enum IceCandidateType {
  /// An address of a local interface.
  host,

  /// The public address a STUN server saw (server reflexive).
  srflx,

  /// An address learned from the other side's connectivity checks (peer
  /// reflexive).
  prflx,

  /// An address on a TURN server, which relays all the media.
  relay;

  /// Parses a report's `candidateType`, or `null` when unknown.
  static IceCandidateType? parse(Object? value) => switch (value) {
    'host' => host,
    'srflx' => srflx,
    'prflx' => prflx,
    'relay' => relay,
    _ => null,
  };
}

/// One end of the selected ICE candidate pair (`local-candidate` or
/// `remote-candidate`). Addresses are left out; they are in the raw
/// reports.
@immutable
final class IceCandidateStats {
  /// Creates the stats.
  const IceCandidateStats({
    this.type,
    this.protocol,
    this.relayProtocol,
    this.networkType,
  });

  /// How the candidate was found.
  final IceCandidateType? type;

  /// The transport: `udp` or `tcp`.
  final String? protocol;

  /// For a local relay candidate, how this client reaches the TURN server:
  /// `udp`, `tcp` or `tls`.
  final String? relayProtocol;

  /// The local network's type when the platform says (`wifi`, `cellular`,
  /// `ethernet`, `vpn`, `unknown`); browsers mostly don't.
  final String? networkType;

  /// Whether the media goes through a TURN relay at this end.
  bool get isRelay => type == IceCandidateType.relay;

  @override
  String toString() =>
      '${type?.name ?? '?'}/${protocol ?? '?'}'
      '${relayProtocol == null ? '' : ' via $relayProtocol'}';
}

/// The transport to the SFU: the selected ICE candidate pair.
@immutable
final class ConnectionStats {
  /// Creates the stats.
  const ConnectionStats({
    this.roundTripTime,
    this.availableOutgoingBitrate,
    this.availableIncomingBitrate,
    this.localCandidate,
    this.remoteCandidate,
    this.bytesSent,
    this.bytesReceived,
    this.sendBitrate,
    this.receiveBitrate,
  });

  /// The latest round-trip time to the SFU, from STUN checks on the pair
  /// (`currentRoundTripTime`).
  final Duration? roundTripTime;

  /// What the sender's bandwidth estimate allows, in bits per second.
  final int? availableOutgoingBitrate;

  /// The receive-side estimate, in bits per second. libwebrtc and most
  /// browsers leave it out.
  final int? availableIncomingBitrate;

  /// This client's end of the pair.
  final IceCandidateStats? localCandidate;

  /// The SFU's end of the pair.
  final IceCandidateStats? remoteCandidate;

  /// Bytes sent on the pair (all media, RTCP and DataChannels).
  final int? bytesSent;

  /// Bytes received on the pair.
  final int? bytesReceived;

  /// [bytesSent] over the last interval, in bits per second.
  final int? sendBitrate;

  /// [bytesReceived] over the last interval, in bits per second.
  final int? receiveBitrate;

  /// Whether the media goes through a TURN relay.
  bool get isRelayed =>
      (localCandidate?.isRelay ?? false) || (remoteCandidate?.isRelay ?? false);

  @override
  String toString() =>
      'ConnectionStats(rtt: ${roundTripTime?.inMilliseconds} ms, '
      'out: ${availableOutgoingBitrate ?? '?'} bps, '
      '$localCandidate -> $remoteCandidate)';
}

/// Why the encoder sends less than it was asked to
/// (`qualityLimitationReason`).
enum QualityLimitationReason {
  /// Not limited.
  none,

  /// The CPU can't keep up.
  cpu,

  /// The bandwidth estimate is too low.
  bandwidth,

  /// Something else.
  other;

  /// Parses a report's value, or `null` when unknown.
  static QualityLimitationReason? parse(Object? value) => switch (value) {
    'none' => none,
    'cpu' => cpu,
    'bandwidth' => bandwidth,
    'other' => other,
    _ => null,
  };
}

/// One sent RTP stream (`outbound-rtp`): a simulcast layer of a video, or
/// a whole single-encoding track. The SFU's view of it comes from its RTCP
/// receiver reports (`remote-inbound-rtp`).
@immutable
final class OutboundLayerStats {
  /// Creates the stats.
  const OutboundLayerStats({
    this.rid,
    this.active,
    this.codec,
    this.bitrate,
    this.targetBitrate,
    this.width,
    this.height,
    this.framesPerSecond,
    this.qualityLimitationReason,
    this.packetsSent,
    this.bytesSent,
    this.retransmittedPacketsSent,
    this.framesEncoded,
    this.keyFramesEncoded,
    this.nackCount,
    this.pliCount,
    this.firCount,
    this.encoderImplementation,
    this.roundTripTime,
    this.packetsLost,
    this.fractionLost,
    this.jitter,
  });

  /// The simulcast RID (`a`, `b`, `c`), or `null` for a single encoding.
  final String? rid;

  /// Whether the encoding is enabled.
  final bool? active;

  /// The codec's MIME type, such as `video/VP8` or `audio/opus`.
  final String? codec;

  /// The payload sent over the last interval (RTP payload and padding, no
  /// headers), in bits per second.
  final int? bitrate;

  /// What the encoder aims for now, in bits per second (not every
  /// platform reports it).
  final int? targetBitrate;

  /// The encoded frame width.
  final int? width;

  /// The encoded frame height.
  final int? height;

  /// Encoded frames per second.
  final double? framesPerSecond;

  /// Why this layer sends less than asked, if it does.
  final QualityLimitationReason? qualityLimitationReason;

  /// RTP packets sent, retransmissions included.
  final int? packetsSent;

  /// Payload bytes sent.
  final int? bytesSent;

  /// Packets sent again after a NACK.
  final int? retransmittedPacketsSent;

  /// Frames encoded.
  final int? framesEncoded;

  /// Key frames encoded.
  final int? keyFramesEncoded;

  /// NACKs received: requests to resend lost packets.
  final int? nackCount;

  /// Picture loss indications received: requests for a key frame.
  final int? pliCount;

  /// Full intra requests received: requests for a key frame.
  final int? firCount;

  /// The encoder in use (such as `libvpx`), where the platform says.
  final String? encoderImplementation;

  /// The round-trip time the SFU's last receiver report gave.
  final Duration? roundTripTime;

  /// Packets the SFU reports lost, in total.
  final int? packetsLost;

  /// The fraction of packets lost in the SFU's last report interval, `0..1`.
  final double? fractionLost;

  /// The interarrival jitter the SFU measured.
  final Duration? jitter;

  @override
  String toString() =>
      '${rid ?? '-'}: ${width ?? '?'}x${height ?? '?'}'
      '@${framesPerSecond?.toStringAsFixed(0) ?? '?'} '
      '${bitrate == null ? '?' : '${bitrate! ~/ 1000}'} kbps'
      '${qualityLimitationReason == null || qualityLimitationReason == QualityLimitationReason.none ? '' : ' (${qualityLimitationReason!.name})'}';
}

/// A local published track's stats: its sent streams, one per simulcast
/// layer.
@immutable
final class LocalTrackStats {
  /// Creates the stats.
  const LocalTrackStats({
    required this.trackName,
    required this.kind,
    required this.source,
    this.layers = const [],
    this.audioLevel,
  });

  /// The publication's track name.
  final String trackName;

  /// Audio or video.
  final TrackKind kind;

  /// What the track captures.
  final TrackSource source;

  /// The sent streams, highest layer first (by encoding index, else by
  /// RID); one entry with a `null` RID for a single-encoding track.
  final List<OutboundLayerStats> layers;

  /// The captured audio level, `0..1` (audio, while not muted).
  final double? audioLevel;

  /// The layer with [rid], if sent.
  OutboundLayerStats? layer(String rid) {
    for (final layer in layers) {
      if (layer.rid == rid) return layer;
    }
    return null;
  }

  /// The codec's MIME type, such as `video/VP8`.
  String? get codec {
    for (final layer in layers) {
      if (layer.codec != null) return layer.codec;
    }
    return null;
  }

  /// The layers' bitrates added up, in bits per second.
  int? get bitrate => _sum((l) => l.bitrate);

  /// The layers' packets added up.
  int? get packetsSent => _sum((l) => l.packetsSent);

  /// The layers' payload bytes added up.
  int? get bytesSent => _sum((l) => l.bytesSent);

  int? _sum(int? Function(OutboundLayerStats layer) value) {
    int? total;
    for (final layer in layers) {
      final v = value(layer);
      if (v != null) total = (total ?? 0) + v;
    }
    return total;
  }

  @override
  String toString() => 'LocalTrackStats($trackName, ${codec ?? '?'}, $layers)';
}

/// A pulled remote track's stats (`inbound-rtp`).
@immutable
final class RemoteTrackStats {
  /// Creates the stats.
  const RemoteTrackStats({
    required this.publicationId,
    required this.participantId,
    required this.trackName,
    required this.kind,
    required this.source,
    this.rid,
    this.codec,
    this.bitrate,
    this.width,
    this.height,
    this.framesPerSecond,
    this.packetsReceived,
    this.packetsLost,
    this.bytesReceived,
    this.packetLoss,
    this.jitter,
    this.framesDecoded,
    this.keyFramesDecoded,
    this.framesDropped,
    this.freezeCount,
    this.totalFreezesDuration,
    this.nackCount,
    this.pliCount,
    this.firCount,
    this.audioLevel,
    this.totalSamplesReceived,
    this.concealedSamples,
    this.concealmentEvents,
    this.concealment,
    this.decoderImplementation,
  });

  /// The `RemoteTrackPublication.id`: `participantId/trackName`.
  final String publicationId;

  /// Who publishes the track.
  final String participantId;

  /// The track's SFU name.
  final String trackName;

  /// Audio or video.
  final TrackKind kind;

  /// What the track captures.
  final TrackSource source;

  /// The simulcast RID the pull asks for, if any.
  final String? rid;

  /// The codec's MIME type, such as `video/VP8`.
  final String? codec;

  /// The payload received over the last interval, in bits per second.
  final int? bitrate;

  /// The decoded frame width.
  final int? width;

  /// The decoded frame height.
  final int? height;

  /// Decoded frames per second.
  final double? framesPerSecond;

  /// RTP packets received.
  final int? packetsReceived;

  /// Packets lost in total (as RTP counts them: may dip with duplicates).
  final int? packetsLost;

  /// Payload bytes received.
  final int? bytesReceived;

  /// The fraction of packets lost over the last interval, `0..1`.
  final double? packetLoss;

  /// The interarrival jitter.
  final Duration? jitter;

  /// Frames decoded.
  final int? framesDecoded;

  /// Key frames decoded.
  final int? keyFramesDecoded;

  /// Frames dropped before decoding or rendering.
  final int? framesDropped;

  /// Video freezes (no frame for much longer than usual), where the
  /// platform counts them.
  final int? freezeCount;

  /// The total time frozen.
  final Duration? totalFreezesDuration;

  /// NACKs sent: requests to resend lost packets.
  final int? nackCount;

  /// Picture loss indications sent.
  final int? pliCount;

  /// Full intra requests sent.
  final int? firCount;

  /// The received audio level, `0..1`.
  final double? audioLevel;

  /// Audio samples received.
  final int? totalSamplesReceived;

  /// Audio samples the receiver made up to hide lost or late packets.
  final int? concealedSamples;

  /// How many times concealment started.
  final int? concealmentEvents;

  /// The fraction of audio samples concealed over the last interval,
  /// `0..1`.
  final double? concealment;

  /// The decoder in use, where the platform says.
  final String? decoderImplementation;

  @override
  String toString() =>
      'RemoteTrackStats($publicationId, ${codec ?? '?'}'
      '${rid == null ? '' : ' @$rid'}, '
      '${kind == TrackKind.video ? '${width ?? '?'}x${height ?? '?'}@${framesPerSecond?.toStringAsFixed(0) ?? '?'} ' : ''}'
      '${bitrate == null ? '?' : '${bitrate! ~/ 1000}'} kbps, '
      'loss ${packetLoss == null ? '?' : '${(packetLoss! * 100).toStringAsFixed(1)} %'})';
}
