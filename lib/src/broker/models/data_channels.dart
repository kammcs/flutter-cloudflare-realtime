import 'common.dart';
import 'json.dart';

/// A DataChannel in a `datachannels/*` request (the SFU's
/// `DataChannelObject`).
///
/// The publisher picks one delivery policy per named channel ([ordered],
/// and at most one of [maxRetransmits] / [maxPacketLifeTime]). Every
/// subscriber must mirror it, in its request and in its own
/// `createDataChannel` call.
class DataChannelObject {
  /// Creates a DataChannel object with any combination of fields.
  ///
  /// Throws an [ArgumentError] if both [maxRetransmits] and
  /// [maxPacketLifeTime] are set.
  DataChannelObject({
    this.location,
    this.dataChannelName,
    this.sessionId,
    this.ordered,
    this.maxRetransmits,
    this.maxPacketLifeTime,
    this.waitForAck,
    this.canReply,
    this.id,
  }) {
    if (maxRetransmits != null && maxPacketLifeTime != null) {
      throw ArgumentError(
        'Set at most one of maxRetransmits and maxPacketLifeTime.',
      );
    }
  }

  /// Publishes the channel [dataChannelName] from this session.
  ///
  /// Omit [maxRetransmits] and [maxPacketLifeTime] for reliable delivery.
  factory DataChannelObject.local(
    String dataChannelName, {
    bool? ordered,
    int? maxRetransmits,
    int? maxPacketLifeTime,
  }) => DataChannelObject(
    location: TrackLocation.local,
    dataChannelName: dataChannelName,
    ordered: ordered,
    maxRetransmits: maxRetransmits,
    maxPacketLifeTime: maxPacketLifeTime,
  );

  /// Subscribes to [dataChannelName] published by session [sessionId].
  ///
  /// [canReply] lets this subscriber send back to the publisher; only one
  /// subscriber per channel can hold it. [waitForAck] holds delivery until
  /// this subscriber sends its first message on the channel.
  factory DataChannelObject.remote({
    required String sessionId,
    required String dataChannelName,
    bool? ordered,
    int? maxRetransmits,
    int? maxPacketLifeTime,
    bool? waitForAck,
    bool? canReply,
  }) => DataChannelObject(
    location: TrackLocation.remote,
    sessionId: sessionId,
    dataChannelName: dataChannelName,
    ordered: ordered,
    maxRetransmits: maxRetransmits,
    maxPacketLifeTime: maxPacketLifeTime,
    waitForAck: waitForAck,
    canReply: canReply,
  );

  /// Identifies a channel by its [id] on this session, as
  /// `datachannels/close` expects.
  factory DataChannelObject.withId(int id) => DataChannelObject(id: id);

  /// Parses the wire shape.
  factory DataChannelObject.fromJson(Map<String, Object?> json) =>
      DataChannelObject(
        location: optEnum(json, 'location', TrackLocation.values),
        dataChannelName: optString(json, 'dataChannelName'),
        sessionId: optString(json, 'sessionId'),
        ordered: optBool(json, 'ordered'),
        maxRetransmits: optInt(json, 'maxRetransmits'),
        maxPacketLifeTime: optInt(json, 'maxPacketLifeTime'),
        waitForAck: optBool(json, 'waitForAck'),
        canReply: optBool(json, 'canReply'),
        id: optInt(json, 'id'),
      );

  /// `local` to publish, `remote` to subscribe.
  final TrackLocation? location;

  /// The channel's name.
  final String? dataChannelName;

  /// The publisher's session ID. Set for remote channels only.
  final String? sessionId;

  /// In-order delivery. The SFU treats a missing value as true.
  final bool? ordered;

  /// Retransmissions after the first send. `0` means none, which differs
  /// from omitting it.
  final int? maxRetransmits;

  /// Transport time budget in milliseconds for (re)transmitting a message.
  final int? maxPacketLifeTime;

  /// Remote only: hold delivery until this subscriber sends an ack message.
  final bool? waitForAck;

  /// Remote only: allow this subscriber to reply to the publisher.
  final bool? canReply;

  /// The channel ID on this session, used to close it.
  final int? id;

  /// The wire shape. Null fields are omitted.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'location', location?.name);
    putIfNotNull(json, 'dataChannelName', dataChannelName);
    putIfNotNull(json, 'sessionId', sessionId);
    putIfNotNull(json, 'ordered', ordered);
    putIfNotNull(json, 'maxRetransmits', maxRetransmits);
    putIfNotNull(json, 'maxPacketLifeTime', maxPacketLifeTime);
    putIfNotNull(json, 'waitForAck', waitForAck);
    putIfNotNull(json, 'canReply', canReply);
    putIfNotNull(json, 'id', id);
    return json;
  }

  @override
  String toString() =>
      'DataChannelObject(location: ${location?.name}, '
      'dataChannelName: $dataChannelName, sessionId: $sessionId, id: $id)';
}

/// One DataChannel's result in a `datachannels/*` response.
///
/// Open the channel with
/// `createDataChannel(name, negotiated: true, id: id)`, using this [id]:
/// the publisher's and the subscriber's IDs can differ. Check [hasError]
/// first.
class DataChannelResult with SfuErrorFields {
  /// Creates a DataChannel result.
  const DataChannelResult({
    this.location,
    this.dataChannelName,
    this.sessionId,
    this.ordered,
    this.maxRetransmits,
    this.maxPacketLifeTime,
    this.waitForAck,
    this.canReply,
    this.id,
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory DataChannelResult.fromJson(Map<String, Object?> json) =>
      DataChannelResult(
        location: optEnum(json, 'location', TrackLocation.values),
        dataChannelName: optString(json, 'dataChannelName'),
        sessionId: optString(json, 'sessionId'),
        ordered: optBool(json, 'ordered'),
        maxRetransmits: optInt(json, 'maxRetransmits'),
        maxPacketLifeTime: optInt(json, 'maxPacketLifeTime'),
        waitForAck: optBool(json, 'waitForAck'),
        canReply: optBool(json, 'canReply'),
        id: optInt(json, 'id'),
        errorCode: optString(json, 'errorCode'),
        errorDescription: optString(json, 'errorDescription'),
      );

  /// `local` or `remote`.
  final TrackLocation? location;

  /// The channel's name.
  final String? dataChannelName;

  /// The publisher's session ID, for remote channels. Identify the sender by
  /// this, never by the payload.
  final String? sessionId;

  /// In-order delivery, if echoed.
  final bool? ordered;

  /// Retransmission limit, if echoed.
  final int? maxRetransmits;

  /// Packet lifetime in milliseconds, if echoed.
  final int? maxPacketLifeTime;

  /// Whether delivery waits for an ack, if echoed.
  final bool? waitForAck;

  /// Whether this subscriber may reply, if echoed.
  final bool? canReply;

  /// The negotiated channel ID on this session.
  final int? id;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The wire shape. Null fields are omitted.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{};
    putIfNotNull(json, 'location', location?.name);
    putIfNotNull(json, 'dataChannelName', dataChannelName);
    putIfNotNull(json, 'sessionId', sessionId);
    putIfNotNull(json, 'ordered', ordered);
    putIfNotNull(json, 'maxRetransmits', maxRetransmits);
    putIfNotNull(json, 'maxPacketLifeTime', maxPacketLifeTime);
    putIfNotNull(json, 'waitForAck', waitForAck);
    putIfNotNull(json, 'canReply', canReply);
    putIfNotNull(json, 'id', id);
    putErrorFields(json, this);
    return json;
  }

  @override
  String toString() =>
      'DataChannelResult(dataChannelName: $dataChannelName, '
      'sessionId: $sessionId, id: $id, errorCode: $errorCode)';
}

/// The body of `POST sessions/{id}/datachannels/establish`, which sets up
/// the SCTP transport by pulling the SFU's `server-events` channel.
class EstablishDataChannelsRequest {
  /// Creates an establish request.
  ///
  /// [dataChannel] defaults to a remote pull of `server-events`, the only
  /// channel this endpoint accepts. Without [sessionDescription], the SFU
  /// replies with an offer and `requiresImmediateRenegotiation`.
  EstablishDataChannelsRequest({
    DataChannelObject? dataChannel,
    this.sessionDescription,
  }) : dataChannel =
           dataChannel ??
           DataChannelObject(
             location: TrackLocation.remote,
             dataChannelName: serverEventsChannelName,
           );

  /// Parses the wire shape.
  factory EstablishDataChannelsRequest.fromJson(Map<String, Object?> json) =>
      EstablishDataChannelsRequest(
        dataChannel: optObject(json, 'dataChannel', DataChannelObject.fromJson),
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
      );

  /// The name of the SFU's built-in events channel.
  static const serverEventsChannelName = 'server-events';

  /// The channel to pull, normally `server-events`.
  final DataChannelObject dataChannel;

  /// An optional local offer with an `application` media section.
  final SessionDescription? sessionDescription;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'dataChannel': dataChannel.toJson()};
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    return json;
  }
}

/// The response of `POST sessions/{id}/datachannels/establish`.
class EstablishDataChannelsResponse with SfuErrorFields {
  /// Creates an establish response.
  const EstablishDataChannelsResponse({
    this.requiresImmediateRenegotiation = false,
    this.sessionDescription,
    this.dataChannel,
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory EstablishDataChannelsResponse.fromJson(Map<String, Object?> json) =>
      EstablishDataChannelsResponse(
        requiresImmediateRenegotiation:
            optBool(json, 'requiresImmediateRenegotiation') ?? false,
        sessionDescription: optObject(
          json,
          'sessionDescription',
          SessionDescription.fromJson,
        ),
        dataChannel: optObject(json, 'dataChannel', DataChannelResult.fromJson),
        errorCode: optString(json, 'errorCode'),
        errorDescription: optString(json, 'errorDescription'),
      );

  /// When true, [sessionDescription] is an SFU offer to answer through
  /// `renegotiate`.
  final bool requiresImmediateRenegotiation;

  /// The SFU's offer or answer.
  final SessionDescription? sessionDescription;

  /// The `server-events` channel and its ID on this session.
  final DataChannelResult? dataChannel;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'requiresImmediateRenegotiation': requiresImmediateRenegotiation,
    };
    putIfNotNull(json, 'sessionDescription', sessionDescription?.toJson());
    putIfNotNull(json, 'dataChannel', dataChannel?.toJson());
    putErrorFields(json, this);
    return json;
  }
}

/// The body of `datachannels/new`, `datachannels/update` and
/// `datachannels/close`: `{"dataChannels": [...]}`.
class DataChannelsRequest {
  /// Creates a DataChannels request.
  const DataChannelsRequest({required this.dataChannels});

  /// Parses the wire shape.
  factory DataChannelsRequest.fromJson(Map<String, Object?> json) =>
      DataChannelsRequest(
        dataChannels: optList(json, 'dataChannels', DataChannelObject.fromJson),
      );

  /// The channels to publish, subscribe, update or close.
  final List<DataChannelObject> dataChannels;

  /// The wire shape.
  Map<String, Object?> toJson() => {
    'dataChannels': [for (final d in dataChannels) d.toJson()],
  };
}

/// The response of `datachannels/new`, `datachannels/update` and
/// `datachannels/close`.
class DataChannelsResponse with SfuErrorFields {
  /// Creates a DataChannels response.
  const DataChannelsResponse({
    this.dataChannels = const [],
    this.errorCode,
    this.errorDescription,
  });

  /// Parses the wire shape.
  factory DataChannelsResponse.fromJson(Map<String, Object?> json) =>
      DataChannelsResponse(
        dataChannels: optList(json, 'dataChannels', DataChannelResult.fromJson),
        errorCode: optString(json, 'errorCode'),
        errorDescription: optString(json, 'errorDescription'),
      );

  /// Per-channel results.
  final List<DataChannelResult> dataChannels;

  @override
  final String? errorCode;

  @override
  final String? errorDescription;

  /// The channel results that carry an error.
  Iterable<DataChannelResult> get dataChannelErrors =>
      dataChannels.where((d) => d.hasError);

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{
      'dataChannels': [for (final d in dataChannels) d.toJson()],
    };
    putErrorFields(json, this);
    return json;
  }
}
