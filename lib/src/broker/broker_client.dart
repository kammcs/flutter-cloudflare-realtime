import 'broker_exception.dart';
import 'models/data_channels.dart';
import 'models/session.dart';
import 'models/tracks.dart';

/// A typed client for the broker contract (`docs/design.md` §5).
///
/// Each method maps to one SFU API call made through the app's broker.
/// [HttpBrokerClient] is the real implementation; session code depends on
/// this interface so tests can substitute a fake.
///
/// Methods throw a [BrokerException] (or a subclass) when the call fails as
/// a whole. A successful response can still carry per-item errors, on
/// [TrackResult.hasError] and [DataChannelResult.hasError], and a
/// request-level error on the response's own `hasError`.
///
/// The SFU requires each SDP exchange on a session to finish before the next
/// mutation of that session. This client doesn't serialize calls; the
/// session layer does.
///
/// See also [SessionGoneException], which means the session must be
/// replaced.
abstract interface class BrokerClient {
  /// `POST sessions/new`: creates an SFU session.
  ///
  /// If the broker returns an `X-Realtime-Session-Token` header, the client
  /// keeps it and sends it on every later call for the new session.
  Future<NewSessionResponse> newSession([NewSessionRequest? request]);

  /// `POST sessions/{sessionId}/tracks/new`: pushes or pulls tracks.
  Future<TracksResponse> newTracks(String sessionId, TracksRequest request);

  /// `PUT sessions/{sessionId}/tracks/update`: changes pulled tracks, for
  /// example their simulcast `preferredRid`.
  Future<TracksResponse> updateTracks(
    String sessionId,
    UpdateTracksRequest request,
  );

  /// `PUT sessions/{sessionId}/renegotiate`: sends the local answer to an
  /// SFU offer that came with `requiresImmediateRenegotiation`.
  Future<RenegotiateResponse> renegotiate(
    String sessionId,
    RenegotiateRequest request,
  );

  /// `PUT sessions/{sessionId}/tracks/close`: closes tracks by `mid`.
  Future<TracksResponse> closeTracks(
    String sessionId,
    CloseTracksRequest request,
  );

  /// `GET sessions/{sessionId}`: reads the session's tracks and
  /// DataChannels.
  Future<SessionState> getSessionState(String sessionId);

  /// `POST sessions/{sessionId}/datachannels/establish`: sets up the
  /// DataChannel (SCTP) transport. Defaults to pulling `server-events`.
  Future<EstablishDataChannelsResponse> establishDataChannels(
    String sessionId, [
    EstablishDataChannelsRequest? request,
  ]);

  /// `POST sessions/{sessionId}/datachannels/new`: publishes or subscribes
  /// to DataChannels.
  Future<DataChannelsResponse> newDataChannels(
    String sessionId,
    DataChannelsRequest request,
  );

  /// `PUT sessions/{sessionId}/datachannels/update`: changes flags such as
  /// `canReply` on subscribed DataChannels.
  Future<DataChannelsResponse> updateDataChannels(
    String sessionId,
    DataChannelsRequest request,
  );

  /// `PUT sessions/{sessionId}/datachannels/close`: closes DataChannels,
  /// usually by [DataChannelObject.withId].
  Future<DataChannelsResponse> closeDataChannels(
    String sessionId,
    DataChannelsRequest request,
  );

  /// `POST generate-ice-servers`: fetches STUN/TURN servers.
  ///
  /// Returns entries ready for `flutter_webrtc`'s `iceServers` configuration
  /// (one map per URL, with `urls`, and `username` / `credential` for TURN).
  Future<List<Map<String, dynamic>>> getIceServers();

  /// Drops anything kept for [sessionId], such as its session token. Call it
  /// when a session is abandoned or replaced.
  void forgetSession(String sessionId);

  /// Releases resources. The client must not be used afterwards.
  void dispose();
}
