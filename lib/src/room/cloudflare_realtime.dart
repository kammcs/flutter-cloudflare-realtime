import '../broker/broker_client.dart';
import '../broker/broker_config.dart';
import '../broker/http_broker_client.dart';
import '../media/flutter_webrtc_media_backend.dart';
import '../media/media_backend.dart';
import '../reconnect/app_lifecycle_source.dart';
import '../reconnect/network_change_source.dart';
import '../rendering/renderable_track.dart';
import '../session/peer_connection_warmup.dart';
import '../session/sfu_session.dart';
import '../signaling/signaling.dart';
import 'room.dart';
import 'room_options.dart';

/// Creates the [BrokerClient] for one room. The default is
/// [HttpBrokerClient].
typedef BrokerClientFactory =
    BrokerClient Function(BrokerOptions options, String roomId);

/// Connects an [SfuSession] through [broker]. The default is
/// [SfuSession.connect].
typedef SfuSessionConnector =
    Future<SfuSession> Function(BrokerClient broker, SfuSessionOptions options);

BrokerClient _defaultBrokerClient(BrokerOptions options, String roomId) =>
    HttpBrokerClient(options: options, roomId: roomId);

Future<SfuSession> _defaultConnect(
  BrokerClient broker,
  SfuSessionOptions options,
) => SfuSession.connect(broker: broker, options: options);

/// The package's entry point: joins rooms through the app's broker.
///
/// ```dart
/// final realtime = CloudflareRealtime(
///   broker: BrokerOptions(
///     baseUrl: Uri.parse('https://api.example.com/realtime'),
///     headers: () async => {'Authorization': 'Bearer ${await getAppJwt()}'},
///   ),
/// );
/// final room = await realtime.join(
///   'room-123',
///   signaling: mySignaling,
///   participantId: currentUserId,
///   metadata: {'displayName': 'Ada'},
/// );
/// await room.localParticipant.publishMicrophone();
/// await room.localParticipant.publishCamera();
/// ```
///
/// Every SFU call goes through the broker (`docs/design.md` §5); the App
/// Secret never reaches the client.
class CloudflareRealtime {
  /// Creates the entry point for the broker described by [broker].
  ///
  /// [mediaBackend] is where published media is captured from.
  ///
  /// [networkChanges] and [appLifecycle] feed the rooms' reconnection
  /// (`docs/design.md` §8): the package has no connectivity plugin, so
  /// network changes are only seen if the app passes a source (for example
  /// one built on `connectivity_plus`); the app lifecycle comes from
  /// Flutter by default. Pass `null` for [appLifecycle] to ignore it.
  ///
  /// The factory parameters replace the broker client
  /// ([createBrokerClient]), the SFU session ([connectSession], also used
  /// for every re-session) and the wrapping of pulled tracks into
  /// renderable streams ([wrapTrack]); tests use them to run without a
  /// network or native WebRTC. Leave them out in apps.
  CloudflareRealtime({
    required this.broker,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
    this.networkChanges,
    this.appLifecycle = const FlutterAppLifecycleSource(),
    BrokerClientFactory? createBrokerClient,
    SfuSessionConnector? connectSession,
    MediaStreamWrapper? wrapTrack,
  }) : _createBrokerClient = createBrokerClient ?? _defaultBrokerClient,
       _connectSession = connectSession ?? _defaultConnect,
       _wrapTrack = wrapTrack ?? wrapTrackInMediaStream;

  /// Where the broker is and how to authenticate to it.
  final BrokerOptions broker;

  /// Where local media is captured from.
  final MediaBackend mediaBackend;

  /// Network-change events for the rooms' reconnection, or `null` (the
  /// default) for none.
  final NetworkChangeSource? networkChanges;

  /// Background and foreground events for the rooms' reconnection, or
  /// `null` for none. Default: [FlutterAppLifecycleSource].
  final AppLifecycleSource? appLifecycle;

  /// Does the slow part of a join's WebRTC setup now, where it is slow:
  /// on macOS. Elsewhere it does nothing.
  ///
  /// On macOS the first peer connection in an app process initializes
  /// `flutter_webrtc` and WebRTC-SDK's audio device module, which blocks
  /// the main thread, and so the app's UI, for 4–6 s (measured on a
  /// MacBook Pro, macOS 27; `docs/design.md` §4.2, macOS: a slow first
  /// join). Without this, [join] does it while the user waits for the
  /// call. Call this when a pause matters less, such as behind a launch
  /// screen, or as a pre-call screen opens; then the join's own peer
  /// connection takes milliseconds.
  ///
  /// It creates one idle peer connection (no ICE servers, no media) and
  /// keeps it until the next [join] has created its own, because closing
  /// the last peer connection undoes part of the setup: after a room is
  /// left, the next join's peer connection blocks again, for 2–3 s. So call
  /// it again after leaving, before the next join. Calls while one is held
  /// return the same future.
  ///
  /// The UI still freezes while it runs: it moves the pause, it doesn't
  /// remove it. Nothing is captured or sent, and no permission is asked
  /// for; Apple's voice processing still starts with the first microphone
  /// publish (off the UI thread). A [join] started meanwhile waits for it
  /// before requesting the session. Never throws: a failure is logged, and
  /// the join creates its own peer connection.
  static Future<void> prewarm() => PeerConnectionWarmup.warm();

  final BrokerClientFactory _createBrokerClient;
  final SfuSessionConnector _connectSession;
  final MediaStreamWrapper _wrapTrack;

  /// Joins [roomId] as [participantId] and returns the connected [Room].
  ///
  /// Creates a broker client for the room (every request carries
  /// `X-Realtime-Room: roomId`) and an SFU session, then joins [signaling]
  /// with the session's ID and [metadata]. Nothing is published yet: call
  /// [LocalParticipant.publishMicrophone] and friends on
  /// [Room.localParticipant].
  ///
  /// [participantId] must be unique in the room; if one user can join from
  /// several devices, include a device or connection ID. [signaling] must
  /// not be in a room already.
  ///
  /// Throws the broker's or the session's exception if the session can't
  /// be created, or the signaling's error if joining fails; nothing is left
  /// open then.
  Future<Room> join(
    String roomId, {
    required Signaling signaling,
    required String participantId,
    Map<String, Object?>? metadata,
    RoomOptions options = const RoomOptions(),
  }) async {
    if (roomId.isEmpty) {
      throw ArgumentError.value(roomId, 'roomId', 'must not be empty');
    }
    if (participantId.isEmpty) {
      throw ArgumentError.value(
        participantId,
        'participantId',
        'must not be empty',
      );
    }
    final client = _createBrokerClient(broker, roomId);
    final SfuSession session;
    try {
      session = await _connectSession(client, options.sessionOptions);
    } catch (_) {
      client.dispose();
      rethrow;
    }
    try {
      return await joinRoom(
        roomId: roomId,
        signaling: signaling,
        options: options,
        session: session,
        broker: client,
        connect: _connectSession,
        mediaBackend: mediaBackend,
        wrapTrack: _wrapTrack,
        networkChanges: networkChanges,
        appLifecycle: appLifecycle,
        participantId: participantId,
        metadata: metadata,
      );
    } catch (_) {
      await session.close();
      client.dispose();
      rethrow;
    }
  }
}
