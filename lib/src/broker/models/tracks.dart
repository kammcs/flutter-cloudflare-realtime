import 'common.dart';
import 'json.dart';

/// How the SFU picks a simulcast layer, for both
/// [SimulcastConfig.priorityOrdering] and [SimulcastConfig.ridNotAvailable].
enum SimulcastOrdering {
  /// Don't switch layers (the SFU's default).
  none,

  /// Sort RIDs a–z, where `a` is the most desirable, and step through them.
  asciibetical,
}

/// Simulcast preferences for a pulled track.
///
/// Wire shape:
/// `{"preferredRid": "a", "priorityOrdering"?: "none" | "asciibetical",
/// "ridNotAvailable"?: "none" | "asciibetical"}`.
class SimulcastConfig {
  /// Creates simulcast preferences.
  const SimulcastConfig({
    required this.preferredRid,
    this.priorityOrdering,
    this.ridNotAvailable,
  });

  /// Parses the wire shape. Unknown ordering values parse as null.
  factory SimulcastConfig.fromJson(Map<String, Object?> json) =>
      SimulcastConfig(
        preferredRid: reqString(json, 'preferredRid'),
        priorityOrdering: optEnum(
          json,
          'priorityOrdering',
          SimulcastOrdering.values,
        ),
        ridNotAvailable: optEnum(
          json,
          'ridNotAvailable',
          SimulcastOrdering.values,
        ),
      );

  /// The RID (encoding name) the subscriber wants, such as `a`, `b` or `c`.
  final String preferredRid;

  /// What the SFU does when there isn't enough bandwidth for
  /// [preferredRid]. Null leaves the SFU default (`none`).
  final SimulcastOrdering? priorityOrdering;

  /// What the SFU does when the publisher stops sending the current or
  /// preferred RID. Null leaves the SFU default (`none`).
  final SimulcastOrdering? ridNotAvailable;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'preferredRid': preferredRid};
    putIfNotNull(json, 'priorityOrdering', priorityOrdering?.name);
    putIfNotNull(json, 'ridNotAvailable', ridNotAvailable?.name);
    return json;
  }

  @override
  String toString() =>
      'SimulcastConfig(preferredRid: $preferredRid, '
      'priorityOrdering: ${priorityOrdering?.name}, '
      'ridNotAvailable: ${ridNotAvailable?.name})';
}

/// A track in a `tracks/new` or `tracks/update` request (the SFU's
/// `TrackObject`).
///
/// Use [TrackObject.local] to push and [TrackObject.remote] to pull. The
/// unnamed constructor exposes every field the SFU accepts.
class TrackObject {
  /// Creates a track object with any combination of fields.
  const TrackObject({
    this.location,
    this.mid,
    this.sessionId,
    this.trackName,
    this.kind,
    this.bidirectionalMediaStream,
    this.simulcast,
  });

  /// Pushes the local track on transceiver [mid] under [trackName].
  const TrackObject.local({required String this.mid, required this.trackName})
    : location = TrackLocation.local,
      sessionId = null,
      kind = null,
      bidirectionalMediaStream = null,
      simulcast = null;

  /// Pulls [trackName] from the publisher's session [sessionId].
  ///
  /// Pass [mid] in `tracks/update` to name the existing transceiver, and
  /// [simulcast] to choose a layer of a simulcast track.
  const TrackObject.remote({
    required String this.sessionId,
    required this.trackName,
    this.mid,
    this.simulcast,
  }) : location = TrackLocation.remote,
       kind = null,
       bidirectionalMediaStream = null;

  /// Parses the wire shape.
  factory TrackObject.fromJson(Map<String, Object?> json) => TrackObject(
    location: optEnum(json, 'location', TrackLocation.values),
    mid: optString(json, 'mid'),
    sessionId: optString(json, 'sessionId'),
    trackName: optString(json, 'trackName'),
    kind: optString(json, 'kind'),
    bidirectionalMediaStream: optBool(json, 'bidirectionalMediaStream'),
    simulcast: optObject(json, 'simulcast', SimulcastConfig.fromJson),
  );

  /// `local` to push, `remote` to pull.
  final TrackLocation? location;

  /// The transceiver's `mid`. It can also be `#<trackName>` to reference an
  /// existing transceiver by track name.
  final String? mid;

  /// The publisher's session ID. Set for remote tracks only.
  final String? sessionId;

  /// The track's name.
  final String? trackName;

  /// A transceiver kind hint (`audio` or `video`). Required when the SFU
  /// generates the offer.
  final String? kind;

  /// Makes the transceiver bidirectional. Works only when the SFU generates
  /// the offer.
  final bool? bidirectionalMediaStream;

  /// Simulcast preferences for a pulled track.
  final SimulcastConfig? simulcast;

  /// The wire shape. Null fields are omitted.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'location', location?.name);
    putIfNotNull(json, 'mid', mid);
    putIfNotNull(json, 'sessionId', sessionId);
    putIfNotNull(json, 'trackName', trackName);
    putIfNotNull(json, 'kind', kind);
    putIfNotNull(json, 'bidirectionalMediaStream', bidirectionalMediaStream);
    putIfNotNull(json, 'simulcast', simulcast?.toJson());
    return json;
  }

  @override
  String toString() =>
      'TrackObject(location: ${location?.name}, mid: $mid, '
      'sessionId: $sessionId, trackName: $trackName)';
}

/// One track's result in a `tracks/new`, `tracks/update` or `tracks/close`
/// response.
///
/// The request can succeed while this track failed: check [hasError].
/// A `tracks/close` result usually carries only [mid] and any error.
class TrackResult with SfuErrorFields {
  /// Creates a track result.
  const TrackResult({
    this.location,
    this.mid,
    this.sessionId,
    this.trackName,
    this.kind,
    this.simulcast,
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory TrackResult.fromJson(Map<String, Object?> json) => TrackResult(
    location: optEnum(json, 'location', TrackLocation.values),
    mid: optString(json, 'mid'),
    sessionId: optString(json, 'sessionId'),
    trackName: optString(json, 'trackName'),
    kind: optString(json, 'kind'),
    simulcast: optObject(json, 'simulcast', SimulcastConfig.fromJson),
    errorCode: optString(json, 'errorCode'),
    errorDescription: optString(json, 'errorDescription'),
  );

  /// `local` or `remote`, when the SFU echoes it.
  final TrackLocation? location;

  /// The transceiver's `mid` on this session. For a pull, map it to the
  /// transceiver that carries the remote track.
  final String? mid;

  /// The publisher's session ID, for remote tracks.
  final String? sessionId;

  /// The track's name.
  final String? trackName;

  /// The transceiver kind, when the SFU returns it.
  final String? kind;

  /// The simulcast preferences the SFU applied, when it returns them.
  final SimulcastConfig? simulcast;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The wire shape. Null fields are omitted.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'location', location?.name);
    putIfNotNull(json, 'mid', mid);
    putIfNotNull(json, 'sessionId', sessionId);
    putIfNotNull(json, 'trackName', trackName);
    putIfNotNull(json, 'kind', kind);
    putIfNotNull(json, 'simulcast', simulcast?.toJson());
    putErrorFields(json, this);
    return json;
  }

  @override
  String toString() =>
      'TrackResult(mid: $mid, trackName: $trackName, sessionId: $sessionId, '
      'errorCode: $errorCode)';
}

/// The body of `POST sessions/{id}/tracks/new`.
///
/// One request pushes (all [TrackObject.local]) or pulls (all
/// [TrackObject.remote]), never both. A pull batch can name several
/// publishers.
class TracksRequest {
  /// Creates a `tracks/new` request.
  ///
  /// A push carries the local [sessionDescription] offer. A pull usually has
  /// none: the SFU answers with an offer and `requiresImmediateRenegotiation`.
  const TracksRequest({
    required this.tracks,
    this.sessionDescription,
    this.autoDiscover,
  });

  /// Parses the wire shape.
  factory TracksRequest.fromJson(Map<String, Object?> json) => TracksRequest(
    tracks: optList(json, 'tracks', TrackObject.fromJson),
    sessionDescription: optObject(
      json,
      'sessionDescription',
      SessionDescription.fromJson,
    ),
    autoDiscover: optBool(json, 'autoDiscover'),
  );

  /// The tracks to push or pull.
  final List<TrackObject> tracks;

  /// The local offer, for a push.
  final SessionDescription? sessionDescription;

  /// Asks the SFU to name any new track in the offer itself.
  final bool? autoDiscover;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'tracks': [for (final t in tracks) t.toJson()],
    };
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    putIfNotNull(json, 'autoDiscover', autoDiscover);
    return json;
  }
}

/// The body of `PUT sessions/{id}/tracks/update`.
///
/// Used to change a pulled track's simulcast layer, or to reuse a
/// transceiver for another track: pass [TrackObject.remote] with the
/// existing `mid`.
class UpdateTracksRequest {
  /// Creates a `tracks/update` request.
  const UpdateTracksRequest({required this.tracks, this.sessionDescription});

  /// Parses the wire shape.
  factory UpdateTracksRequest.fromJson(Map<String, Object?> json) =>
      UpdateTracksRequest(
        tracks: optList(json, 'tracks', TrackObject.fromJson),
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
      );

  /// The tracks to update, each identified by its `mid`.
  final List<TrackObject> tracks;

  /// An optional local session description.
  final SessionDescription? sessionDescription;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'tracks': [for (final t in tracks) t.toJson()],
    };
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    return json;
  }
}

/// The body of `PUT sessions/{id}/tracks/close`.
///
/// Wire shape: `{"tracks": [{"mid": "7"}], "sessionDescription"?: {...},
/// "force": false}`.
class CloseTracksRequest {
  /// Creates a `tracks/close` request.
  ///
  /// With `force: false` (a negotiated close), stop the transceivers, create
  /// and set a local offer, and pass it as [sessionDescription]; then apply
  /// the answer in the response. With `force: true`, no SDP is exchanged.
  CloseTracksRequest({
    required List<String> mids,
    this.sessionDescription,
    this.force = false,
  }) : mids = List.unmodifiable(mids) {
    if (mids.isEmpty) {
      throw ArgumentError.value(mids, 'mids', 'must not be empty');
    }
    if (!force && sessionDescription == null) {
      throw ArgumentError.value(
        null,
        'sessionDescription',
        'is required when force is false',
      );
    }
  }

  /// Parses the wire shape.
  factory CloseTracksRequest.fromJson(Map<String, Object?> json) =>
      CloseTracksRequest(
        mids: [
          for (final t in optList(json, 'tracks', (t) => t))
            reqString(t, 'mid'),
        ],
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
        force: optBool(json, 'force') ?? false,
      );

  /// The `mid`s of the transceivers to close on this session.
  final List<String> mids;

  /// The local offer, for a negotiated close.
  final SessionDescription? sessionDescription;

  /// Whether to close without an SDP exchange.
  final bool force;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'tracks': [
        for (final mid in mids) {'mid': mid},
      ],
      'force': force,
    };
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    return json;
  }
}

/// The response of `tracks/new`, `tracks/update` and `tracks/close`.
///
/// Check [hasError] for a request-level error and each entry of [tracks]
/// for per-track errors (see [trackErrors]).
class TracksResponse with SfuErrorFields {
  /// Creates a tracks response.
  const TracksResponse({
    this.requiresImmediateRenegotiation = false,
    this.sessionDescription,
    this.tracks = const [],
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory TracksResponse.fromJson(Map<String, Object?> json) => TracksResponse(
    requiresImmediateRenegotiation:
        optBool(json, 'requiresImmediateRenegotiation') ?? false,
    sessionDescription: optObject(
      json,
      'sessionDescription',
      SessionDescription.fromJson,
    ),
    tracks: optList(json, 'tracks', TrackResult.fromJson),
    errorCode: optString(json, 'errorCode'),
    errorDescription: optString(json, 'errorDescription'),
  );

  /// When true, [sessionDescription] is an offer from the SFU: set it as the
  /// remote description, create an answer, and send it with `renegotiate`
  /// before the next mutation.
  final bool requiresImmediateRenegotiation;

  /// The SFU's answer (to a pushed offer or a negotiated close) or offer
  /// (when [requiresImmediateRenegotiation] is true). Absent after a forced
  /// close or an update.
  final SessionDescription? sessionDescription;

  /// Per-track results.
  final List<TrackResult> tracks;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The track results that carry an error.
  Iterable<TrackResult> get trackErrors => tracks.where((t) => t.hasError);

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'requiresImmediateRenegotiation': requiresImmediateRenegotiation,
      'tracks': [for (final t in tracks) t.toJson()],
    };
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    putErrorFields(json, this);
    return json;
  }
}

/// The body of `PUT sessions/{id}/renegotiate`: the local answer to an offer
/// the SFU sent with `requiresImmediateRenegotiation`.
class RenegotiateRequest {
  /// Creates a renegotiation request.
  const RenegotiateRequest({required this.sessionDescription});

  /// Parses the wire shape.
  factory RenegotiateRequest.fromJson(Map<String, Object?> json) =>
      RenegotiateRequest(
        sessionDescription: SessionDescription.fromJson(
          jsonObject(json['sessionDescription'], 'sessionDescription'),
        ),
      );

  /// The local answer.
  final SessionDescription sessionDescription;

  /// The wire shape.
  Map<String, Object?> toJson() => {
    'sessionDescription': sessionDescription.toJson(),
  };
}

/// The response of `PUT sessions/{id}/renegotiate`. Usually empty.
class RenegotiateResponse with SfuErrorFields {
  /// Creates a renegotiation response.
  const RenegotiateResponse({
    this.sessionDescription,
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory RenegotiateResponse.fromJson(Map<String, Object?> json) =>
      RenegotiateResponse(
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
        errorCode: optString(json, 'errorCode'),
        errorDescription: optString(json, 'errorDescription'),
      );

  /// A session description, if the SFU returns one.
  final SessionDescription? sessionDescription;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    putErrorFields(json, this);
    return json;
  }
}
