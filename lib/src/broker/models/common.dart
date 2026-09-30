import 'json.dart';

/// The type of an SDP [SessionDescription].
enum SdpType {
  /// An SDP offer.
  offer,

  /// An SDP answer.
  answer,
}

/// An SDP offer or answer, as the SFU API sends and receives it.
///
/// Wire shape: `{"type": "offer" | "answer", "sdp": "..."}`.
///
/// [toString] reports only the type and the SDP length: SDP carries ICE
/// credentials and fingerprints, and must never be logged.
class SessionDescription {
  /// Creates a session description.
  const SessionDescription({required this.type, required this.sdp});

  /// Creates an offer.
  const SessionDescription.offer(this.sdp) : type = SdpType.offer;

  /// Creates an answer.
  const SessionDescription.answer(this.sdp) : type = SdpType.answer;

  /// Parses the wire shape.
  ///
  /// Throws a [FormatException] if `type` or `sdp` is missing or invalid.
  factory SessionDescription.fromJson(Map<String, Object?> json) {
    final type = optEnum(json, 'type', SdpType.values);
    if (type == null) {
      throw const FormatException('Missing or unknown SDP "type".');
    }
    return SessionDescription(type: type, sdp: reqString(json, 'sdp'));
  }

  /// Whether this is an offer or an answer.
  final SdpType type;

  /// The SDP text.
  final String sdp;

  /// The wire shape.
  Map<String, Object?> toJson() => {'type': type.name, 'sdp': sdp};

  @override
  String toString() =>
      'SessionDescription(type: ${type.name}, sdp: ${sdp.length} chars)';
}

/// Whether a track or DataChannel is published by this session (`local`) or
/// pulled from another session (`remote`).
enum TrackLocation {
  /// Published by this session.
  local,

  /// Pulled from another session.
  remote,
}

/// The status of a track or DataChannel in `GET sessions/{id}`.
enum ResourceStatus {
  /// A media track that hasn't closed or become unavailable, or an open
  /// DataChannel.
  active,

  /// A closed or unavailable media track, or a DataChannel that is no longer
  /// connecting or open.
  inactive,

  /// A DataChannel that is still connecting.
  initializing,

  /// A value this version of the package doesn't know.
  unknown,
}

/// The `errorCode` / `errorDescription` pair that SFU responses carry, both
/// on the whole response and on each track or DataChannel result.
///
/// A successful HTTP response can still carry errors on individual items, so
/// check [hasError] on each item.
mixin SfuErrorFields {
  /// The machine-readable error code, such as `close_track_error`, or null.
  String? get errorCode;

  /// The human-readable error description, or null.
  String? get errorDescription;

  /// Whether this response or item reports an error.
  bool get hasError => errorCode != null;
}

/// Adds the error fields of [value] to [json].
void putErrorFields(Map<String, Object?> json, SfuErrorFields value) {
  putIfNotNull(json, 'errorCode', value.errorCode);
  putIfNotNull(json, 'errorDescription', value.errorDescription);
}
