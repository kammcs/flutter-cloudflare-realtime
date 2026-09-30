import 'common.dart';
import 'json.dart';
import 'tracks.dart';

/// A `POST sessions/new` request.
///
/// With no [sessionDescription], the SFU returns a session ID without
/// starting WebRTC negotiation. partytracks creates sessions this way, then
/// pushes its first track with the offer. An unconnected session can expire
/// before its first track or DataChannel operation.
class NewSessionRequest {
  /// Creates a `sessions/new` request.
  const NewSessionRequest({this.sessionDescription, this.correlationId});

  /// Parses the JSON body. [correlationId] travels in the query string, so it
  /// is not part of the body.
  factory NewSessionRequest.fromJson(Map<String, Object?> json) =>
      NewSessionRequest(
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
      );

  /// An optional initial offer.
  final SessionDescription? sessionDescription;

  /// An optional diagnostic label, sent as the `correlationId` query
  /// parameter. It is not an idempotency key.
  final String? correlationId;

  /// Whether the request has a JSON body at all.
  bool get hasBody => sessionDescription != null;

  /// The JSON body (without [correlationId], which goes in the query).
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    return json;
  }
}

/// The response of `POST sessions/new`.
class NewSessionResponse with SfuErrorFields {
  /// Creates a new-session response.
  const NewSessionResponse({
    required this.sessionId,
    this.sessionDescription,
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape. Throws a [FormatException] without a
  /// `sessionId`.
  factory NewSessionResponse.fromJson(Map<String, Object?> json) =>
      NewSessionResponse(
        sessionId: reqString(json, 'sessionId'),
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
        errorCode: optString(json, 'errorCode'),
        errorDescription: optString(json, 'errorDescription'),
      );

  /// The new session's ID. Other participants pull this session's tracks
  /// by it, so share it through signaling.
  final String sessionId;

  /// The SFU's answer, when the request carried an offer.
  final SessionDescription? sessionDescription;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'sessionId': sessionId};
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    putErrorFields(json, this);
    return json;
  }

  @override
  String toString() => 'NewSessionResponse(sessionId: $sessionId)';
}

/// A media track in `GET sessions/{id}`.
class SessionTrackState {
  /// Creates a track state.
  const SessionTrackState({
    this.location,
    this.mid,
    this.sessionId,
    this.trackName,
    this.kind,
    this.simulcast,
    this.status = ResourceStatus.unknown,
  });

  /// Parses the wire shape.
  factory SessionTrackState.fromJson(Map<String, Object?> json) =>
      SessionTrackState(
        location: optEnum(json, 'location', TrackLocation.values),
        mid: optString(json, 'mid'),
        sessionId: optString(json, 'sessionId'),
        trackName: optString(json, 'trackName'),
        kind: optString(json, 'kind'),
        simulcast: optObject(json, 'simulcast', SimulcastConfig.fromJson),
        status:
            optEnum(json, 'status', ResourceStatus.values) ??
            ResourceStatus.unknown,
      );

  /// `local` (pushed) or `remote` (pulled).
  final TrackLocation? location;

  /// The transceiver's `mid`.
  final String? mid;

  /// The publisher's session ID, for remote tracks.
  final String? sessionId;

  /// The track's name.
  final String? trackName;

  /// The transceiver kind, if returned.
  final String? kind;

  /// Simulcast preferences, if returned.
  final SimulcastConfig? simulcast;

  /// The track's status. Closed tracks can stay listed as `inactive`.
  final ResourceStatus status;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'location', location?.name);
    putIfNotNull(json, 'mid', mid);
    putIfNotNull(json, 'sessionId', sessionId);
    putIfNotNull(json, 'trackName', trackName);
    putIfNotNull(json, 'kind', kind);
    putIfNotNull(json, 'simulcast', simulcast?.toJson());
    if (status != ResourceStatus.unknown) json['status'] = status.name;
    return json;
  }
}

/// A DataChannel in `GET sessions/{id}`.
class SessionDataChannelState {
  /// Creates a DataChannel state.
  const SessionDataChannelState({
    this.location,
    this.sessionId,
    this.dataChannelName,
    this.id,
    this.status = ResourceStatus.unknown,
  });

  /// Parses the wire shape.
  factory SessionDataChannelState.fromJson(Map<String, Object?> json) =>
      SessionDataChannelState(
        location: optEnum(json, 'location', TrackLocation.values),
        sessionId: optString(json, 'sessionId'),
        dataChannelName: optString(json, 'dataChannelName'),
        id: optInt(json, 'id'),
        status:
            optEnum(json, 'status', ResourceStatus.values) ??
            ResourceStatus.unknown,
      );

  /// `local` (published) or `remote` (subscribed).
  final TrackLocation? location;

  /// The publisher's session ID, for remote channels.
  final String? sessionId;

  /// The channel's name.
  final String? dataChannelName;

  /// The channel ID on this session.
  final int? id;

  /// The channel's status.
  final ResourceStatus status;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'location', location?.name);
    putIfNotNull(json, 'sessionId', sessionId);
    putIfNotNull(json, 'dataChannelName', dataChannelName);
    putIfNotNull(json, 'id', id);
    if (status != ResourceStatus.unknown) json['status'] = status.name;
    return json;
  }
}

/// The response of `GET sessions/{id}`: the session's tracks and
/// DataChannels. It contains no SDP.
class SessionState with SfuErrorFields {
  /// Creates a session state.
  const SessionState({
    this.tracks = const [],
    this.dataChannels = const [],
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory SessionState.fromJson(Map<String, Object?> json) => SessionState(
    tracks: optList(json, 'tracks', SessionTrackState.fromJson),
    dataChannels: optList(
      json,
      'dataChannels',
      SessionDataChannelState.fromJson,
    ),
    errorCode: optString(json, 'errorCode'),
    errorDescription: optString(json, 'errorDescription'),
  );

  /// The session's media tracks.
  final List<SessionTrackState> tracks;

  /// The session's DataChannels.
  final List<SessionDataChannelState> dataChannels;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'tracks': [for (final t in tracks) t.toJson()],
      'dataChannels': [for (final d in dataChannels) d.toJson()],
    };
    putErrorFields(json, this);
    return json;
  }
}
