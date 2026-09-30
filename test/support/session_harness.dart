import 'package:cloudflare_realtime/src/session/sfu_session.dart';

import 'fake_broker_client.dart';
import 'fake_peer_connection.dart';

export 'fake_broker_client.dart';
export 'fake_peer_connection.dart';

/// A [FakeBrokerClient] and a [FakePeerConnectionFactory] wired together,
/// for connecting [SfuSession]s without a network or native WebRTC.
class SessionHarness {
  SessionHarness() {
    peerConnections = FakePeerConnectionFactory(
      remoteMedia: broker.remoteMediaForOffer,
    );
  }

  /// The fake broker every session uses.
  final FakeBrokerClient broker = FakeBrokerClient();

  /// Creates a fake peer connection per session.
  late final FakePeerConnectionFactory peerConnections;

  /// The last session's peer connection.
  FakePeerConnection get pc => peerConnections.last;

  /// Connects a session through the fakes.
  Future<SfuSession> connect({
    SfuSessionOptions options = const SfuSessionOptions(),
  }) => connectSfuSession(
    broker: broker,
    options: options,
    createPeerConnection: peerConnections.call,
  );
}
