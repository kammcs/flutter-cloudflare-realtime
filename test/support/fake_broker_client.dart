import 'dart:async';

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';

/// One call recorded by [FakeBrokerClient].
class BrokerCall {
  BrokerCall(this.operation, {this.sessionId, this.request});

  /// The operation, such as `tracks/new` (the broker contract's path).
  final String operation;

  /// The session the call was for, if any.
  final String? sessionId;

  /// The request model, such as a [TracksRequest], if any.
  final Object? request;

  @override
  String toString() => 'BrokerCall($operation, $sessionId)';
}

/// A remote track the fake SFU offers when a pull asks for renegotiation.
class FakeRemoteMedia {
  const FakeRemoteMedia({required this.mid, required this.kind});

  final String mid;
  final String kind;
}

/// A scriptable in-memory [BrokerClient] that behaves like a cooperative
/// SFU, for session-level tests.
///
/// By default:
/// - `sessions/new` returns `session-1`, `session-2`, ...
/// - `generate-ice-servers` returns Cloudflare STUN.
/// - A push (`tracks/new` with an offer) answers `answer:<offer sdp>` and
///   echoes each track with its `mid`.
/// - A pull (`tracks/new` without an offer) assigns mids `r1`, `r2`, ...,
///   and returns an SFU offer with `requiresImmediateRenegotiation`. Pair
///   it with `FakePeerConnection(remoteMedia: broker.remoteMediaForOffer)`
///   so applying that offer creates the receiving transceivers.
/// - `tracks/update` echoes the tracks; `tracks/close` answers the offer
///   and echoes the mids; `renegotiate` returns `{}`.
/// - `datachannels/establish` returns an SFU offer (no media) with
///   `requiresImmediateRenegotiation`; `datachannels/new` echoes each
///   channel with a per-session ID from [firstDataChannelId] up;
///   `datachannels/update` and `/close` echo.
///
/// Every call is recorded in [calls]. Replace a behaviour by setting the
/// matching `on*` handler; handlers can call the `default*` methods. SDP
/// strings are opaque tokens: tests check sequencing, never SDP content.
class FakeBrokerClient implements BrokerClient {
  /// Every call, in the order it was made.
  final List<BrokerCall> calls = [];

  /// Session IDs passed to [forgetSession].
  final List<String> forgotten = [];

  /// The kind of each published track, by `'<sessionId>/<trackName>'`, used
  /// when a pull creates remote media. Unknown tracks are `video`.
  final Map<String, String> trackKinds = {};

  Future<NewSessionResponse> Function(NewSessionRequest? request)? onNewSession;
  Future<List<Map<String, dynamic>>> Function()? onGetIceServers;
  Future<TracksResponse> Function(String sessionId, TracksRequest request)?
  onNewTracks;
  Future<TracksResponse> Function(
    String sessionId,
    UpdateTracksRequest request,
  )?
  onUpdateTracks;
  Future<RenegotiateResponse> Function(
    String sessionId,
    RenegotiateRequest request,
  )?
  onRenegotiate;
  Future<TracksResponse> Function(String sessionId, CloseTracksRequest request)?
  onCloseTracks;

  final Map<String, List<FakeRemoteMedia>> _offers = {};
  int _sessions = 0;
  int _remoteMids = 0;
  int _sfuOffers = 0;
  bool disposed = false;

  /// The calls for [operation], in order.
  List<BrokerCall> callsTo(String operation) =>
      calls.where((c) => c.operation == operation).toList();

  /// The operations called, in order.
  List<String> get operations => [for (final c in calls) c.operation];

  /// The remote media an SFU offer from this fake carries. Wire it into
  /// `FakePeerConnection.remoteMedia`.
  List<FakeRemoteMedia> remoteMediaForOffer(String sdp) =>
      _offers[sdp] ?? const [];

  // ---------------------------------------------------------------------------
  // Default behaviours
  // ---------------------------------------------------------------------------

  Future<NewSessionResponse> defaultNewSession() async =>
      NewSessionResponse(sessionId: 'session-${++_sessions}');

  Future<TracksResponse> defaultNewTracks(
    String sessionId,
    TracksRequest request,
  ) async {
    final offer = request.sessionDescription;
    if (offer != null) {
      return TracksResponse(
        sessionDescription: SessionDescription.answer('answer:${offer.sdp}'),
        tracks: [
          for (final t in request.tracks)
            TrackResult(
              location: TrackLocation.local,
              mid: t.mid,
              trackName: t.trackName,
            ),
        ],
      );
    }
    final media = <FakeRemoteMedia>[];
    final results = <TrackResult>[];
    for (final t in request.tracks) {
      final mid = 'r${++_remoteMids}';
      media.add(
        FakeRemoteMedia(
          mid: mid,
          kind: trackKinds['${t.sessionId}/${t.trackName}'] ?? 'video',
        ),
      );
      results.add(
        TrackResult(
          location: TrackLocation.remote,
          mid: mid,
          sessionId: t.sessionId,
          trackName: t.trackName,
        ),
      );
    }
    return TracksResponse(
      requiresImmediateRenegotiation: true,
      sessionDescription: sfuOffer(media),
      tracks: results,
    );
  }

  /// An SFU offer that creates [media] when applied by a fake peer
  /// connection wired to [remoteMediaForOffer].
  SessionDescription sfuOffer(List<FakeRemoteMedia> media) {
    final sdp = 'sfu-offer-${++_sfuOffers}';
    _offers[sdp] = media;
    return SessionDescription.offer(sdp);
  }

  Future<TracksResponse> defaultUpdateTracks(
    String sessionId,
    UpdateTracksRequest request,
  ) async => TracksResponse(
    tracks: [
      for (final t in request.tracks)
        TrackResult(
          location: TrackLocation.remote,
          mid: t.mid,
          sessionId: t.sessionId,
          trackName: t.trackName,
          simulcast: t.simulcast,
        ),
    ],
  );

  Future<TracksResponse> defaultCloseTracks(
    String sessionId,
    CloseTracksRequest request,
  ) async => TracksResponse(
    sessionDescription: request.sessionDescription == null
        ? null
        : SessionDescription.answer(
            'answer:${request.sessionDescription!.sdp}',
          ),
    tracks: [for (final mid in request.mids) TrackResult(mid: mid)],
  );

  // ---------------------------------------------------------------------------
  // BrokerClient
  // ---------------------------------------------------------------------------

  @override
  Future<NewSessionResponse> newSession([NewSessionRequest? request]) {
    calls.add(BrokerCall('sessions/new', request: request));
    return onNewSession?.call(request) ?? defaultNewSession();
  }

  @override
  Future<List<Map<String, dynamic>>> getIceServers() {
    calls.add(BrokerCall('generate-ice-servers'));
    return onGetIceServers?.call() ??
        Future.value([
          {'urls': 'stun:stun.cloudflare.com:3478'},
        ]);
  }

  @override
  Future<TracksResponse> newTracks(String sessionId, TracksRequest request) {
    calls.add(BrokerCall('tracks/new', sessionId: sessionId, request: request));
    return onNewTracks?.call(sessionId, request) ??
        defaultNewTracks(sessionId, request);
  }

  @override
  Future<TracksResponse> updateTracks(
    String sessionId,
    UpdateTracksRequest request,
  ) {
    calls.add(
      BrokerCall('tracks/update', sessionId: sessionId, request: request),
    );
    return onUpdateTracks?.call(sessionId, request) ??
        defaultUpdateTracks(sessionId, request);
  }

  @override
  Future<RenegotiateResponse> renegotiate(
    String sessionId,
    RenegotiateRequest request,
  ) {
    calls.add(
      BrokerCall('renegotiate', sessionId: sessionId, request: request),
    );
    return onRenegotiate?.call(sessionId, request) ??
        Future.value(const RenegotiateResponse());
  }

  @override
  Future<TracksResponse> closeTracks(
    String sessionId,
    CloseTracksRequest request,
  ) {
    calls.add(
      BrokerCall('tracks/close', sessionId: sessionId, request: request),
    );
    return onCloseTracks?.call(sessionId, request) ??
        defaultCloseTracks(sessionId, request);
  }

  /// Sessions `GET sessions/{id}` reports gone (a 410 `session_error`), as
  /// the SFU does for an expired session. Other sessions are alive.
  final Set<String> goneSessions = {};

  /// Replaces the default `GET sessions/{id}` behaviour.
  Future<SessionState> Function(String sessionId)? onGetSessionState;

  @override
  Future<SessionState> getSessionState(String sessionId) async {
    calls.add(BrokerCall('sessions/{id}', sessionId: sessionId));
    final handler = onGetSessionState;
    if (handler != null) return handler(sessionId);
    if (goneSessions.contains(sessionId)) {
      throw SessionGoneException(
        operation: 'sessions/{id}',
        sessionId: sessionId,
        statusCode: 410,
        errorCode: 'session_error',
      );
    }
    return const SessionState();
  }

  @override
  Future<EstablishDataChannelsResponse> establishDataChannels(
    String sessionId, [
    EstablishDataChannelsRequest? request,
  ]) {
    calls.add(
      BrokerCall(
        'datachannels/establish',
        sessionId: sessionId,
        request: request,
      ),
    );
    return onEstablishDataChannels?.call(sessionId, request) ??
        defaultEstablishDataChannels(sessionId, request);
  }

  @override
  Future<DataChannelsResponse> newDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) {
    calls.add(
      BrokerCall('datachannels/new', sessionId: sessionId, request: request),
    );
    return onNewDataChannels?.call(sessionId, request) ??
        defaultNewDataChannels(sessionId, request);
  }

  @override
  Future<DataChannelsResponse> updateDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) {
    calls.add(
      BrokerCall('datachannels/update', sessionId: sessionId, request: request),
    );
    return onUpdateDataChannels?.call(sessionId, request) ??
        defaultUpdateDataChannels(sessionId, request);
  }

  @override
  Future<DataChannelsResponse> closeDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) {
    calls.add(
      BrokerCall('datachannels/close', sessionId: sessionId, request: request),
    );
    return onCloseDataChannels?.call(sessionId, request) ??
        defaultCloseDataChannels(sessionId, request);
  }

  // ---------------------------------------------------------------------------
  // DataChannels
  // ---------------------------------------------------------------------------

  Future<EstablishDataChannelsResponse> Function(
    String sessionId,
    EstablishDataChannelsRequest? request,
  )?
  onEstablishDataChannels;
  Future<DataChannelsResponse> Function(
    String sessionId,
    DataChannelsRequest request,
  )?
  onNewDataChannels;
  Future<DataChannelsResponse> Function(
    String sessionId,
    DataChannelsRequest request,
  )?
  onUpdateDataChannels;
  Future<DataChannelsResponse> Function(
    String sessionId,
    DataChannelsRequest request,
  )?
  onCloseDataChannels;

  /// The next DataChannel ID per session. ID 0 is `server-events`.
  final Map<String, int> _dataChannelIds = {};

  /// The first DataChannel ID `datachannels/new` assigns on each session.
  /// Subscribers and publishers get IDs from separate per-session counters,
  /// so they differ, as on the real SFU.
  int firstDataChannelId = 1;

  /// An SFU offer carrying no media (only the `application` m-line), as
  /// `datachannels/establish` returns, then `server-events` with ID 0.
  Future<EstablishDataChannelsResponse> defaultEstablishDataChannels(
    String sessionId,
    EstablishDataChannelsRequest? request,
  ) async => EstablishDataChannelsResponse(
    requiresImmediateRenegotiation: true,
    sessionDescription: sfuOffer(const []),
    dataChannel: const DataChannelResult(
      dataChannelName: EstablishDataChannelsRequest.serverEventsChannelName,
      id: 0,
    ),
  );

  /// Echoes each channel with the next ID on [sessionId].
  Future<DataChannelsResponse> defaultNewDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) async => DataChannelsResponse(
    dataChannels: [
      for (final d in request.dataChannels)
        DataChannelResult(
          location: d.location,
          dataChannelName: d.dataChannelName,
          sessionId: d.sessionId,
          ordered: d.ordered,
          maxRetransmits: d.maxRetransmits,
          canReply: d.canReply,
          id: nextDataChannelId(sessionId),
        ),
    ],
  );

  /// The ID [defaultNewDataChannels] assigns next on [sessionId].
  int nextDataChannelId(String sessionId) {
    final id = _dataChannelIds[sessionId] ?? firstDataChannelId;
    _dataChannelIds[sessionId] = id + 1;
    return id;
  }

  /// Echoes each channel.
  Future<DataChannelsResponse> defaultUpdateDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) async => DataChannelsResponse(
    dataChannels: [
      for (final d in request.dataChannels)
        DataChannelResult(
          location: d.location,
          dataChannelName: d.dataChannelName,
          sessionId: d.sessionId,
          canReply: d.canReply,
        ),
    ],
  );

  /// Echoes each ID.
  Future<DataChannelsResponse> defaultCloseDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) async => DataChannelsResponse(
    dataChannels: [
      for (final d in request.dataChannels) DataChannelResult(id: d.id),
    ],
  );

  @override
  void forgetSession(String sessionId) => forgotten.add(sessionId);

  @override
  void dispose() => disposed = true;
}
