import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/session/sfu_session.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack;

import '../media/fakes.dart';
import 'session_harness.dart';

export '../media/fakes.dart';
export 'session_harness.dart';

/// What `wrapTrackInMediaStream` returns, without the plugin: a stream
/// holding one track.
class FakeWrappedStream extends MediaStream {
  FakeWrappedStream(this.track) : super('wrapped-${++_count}', 'local');

  static int _count = 0;

  /// The wrapped track.
  final MediaStreamTrack track;

  /// Whether [dispose] was called.
  bool disposed = false;

  @override
  bool? get active => !disposed;

  @override
  Future<void> getMediaTracks() async {}

  @override
  Future<void> addTrack(MediaStreamTrack track, {bool addToNative = true}) =>
      throw UnimplementedError();

  @override
  Future<void> removeTrack(
    MediaStreamTrack track, {
    bool removeFromNative = true,
  }) => throw UnimplementedError();

  @override
  List<MediaStreamTrack> getTracks() => [track];

  @override
  List<MediaStreamTrack> getAudioTracks() => [if (track.kind == 'audio') track];

  @override
  List<MediaStreamTrack> getVideoTracks() => [if (track.kind == 'video') track];

  @override
  Future<void> dispose() async => disposed = true;
}

/// Several [Room]s in one process: they share a [FakeBrokerClient] (a
/// cooperative fake SFU), an [InMemorySignalingHub] and a [FakeMediaBackend],
/// and each gets its own [FakePeerConnection].
class RoomHarness {
  RoomHarness({FakeMediaBackend? media})
    : media = media ?? FakeMediaBackend(devices: [cam1, mic1]) {
    // Remember what each pushed track is, so pulls of it create receivers of
    // the right kind.
    broker.onNewTracks = (sessionId, request) {
      if (request.sessionDescription != null) {
        final pc = pcBySession[sessionId];
        for (final t in request.tracks) {
          final kind = pc?.byMid(t.mid ?? '')?.kind;
          if (kind != null) {
            broker.trackKinds['$sessionId/${t.trackName}'] = kind;
          }
        }
      }
      return broker.defaultNewTracks(sessionId, request);
    };
  }

  /// The fakes every session uses.
  final SessionHarness sessions = SessionHarness();

  /// The shared fake broker.
  FakeBrokerClient get broker => sessions.broker;

  /// The shared signaling hub.
  final InMemorySignalingHub hub = InMemorySignalingHub();

  /// Where local media is captured.
  final FakeMediaBackend media;

  /// Each session's peer connection, by session ID.
  final Map<String, FakePeerConnection> pcBySession = {};

  /// The room IDs broker clients were created for.
  final List<String> brokerRooms = [];

  /// Every stream a pulled track was wrapped in.
  final List<FakeWrappedStream> wrapped = [];

  /// Makes the next session connections throw [error].
  Object? connectError;

  late final CloudflareRealtime realtime = CloudflareRealtime(
    broker: BrokerConfig(
      baseUrl: Uri.parse('https://broker.test/realtime'),
      headers: () async => const {},
    ),
    mediaBackend: media,
    createBrokerClient: (config, roomId) {
      brokerRooms.add(roomId);
      return broker;
    },
    connectSession: (broker, options) async {
      final error = connectError;
      if (error != null) throw error;
      final session = await connectSfuSession(
        broker: broker,
        options: options,
        createPeerConnection: sessions.peerConnections.call,
      );
      pcBySession[session.sessionId] = sessions.peerConnections.last;
      return session;
    },
    wrapTrack: (track) async {
      final stream = FakeWrappedStream(track);
      wrapped.add(stream);
      return stream;
    },
  );

  /// Joins [roomId] as [participantId] with a new [InMemorySignaling].
  Future<Room> join(
    String participantId, {
    String roomId = 'room',
    RoomOptions options = const RoomOptions(),
    Map<String, Object?>? metadata,
    Signaling? signaling,
  }) => realtime.join(
    roomId,
    signaling: signaling ?? InMemorySignaling(hub),
    participantId: participantId,
    options: options,
    metadata: metadata,
  );

  /// The peer connection of [room]'s session.
  FakePeerConnection pcOf(Room room) => pcBySession[room.session.sessionId]!;

  /// The broker calls made for [room]'s session to [operation].
  List<BrokerCall> callsOf(Room room, String operation) => [
    for (final c in broker.callsTo(operation))
      if (c.sessionId == room.session.sessionId) c,
  ];

  /// The tracks pulled (remote `tracks/new`) by [room], as
  /// `remoteSessionId/trackName` with `@rid` when a layer was asked for.
  List<String> pullsOf(Room room) => [
    for (final call in callsOf(room, 'tracks/new'))
      if ((call.request! as TracksRequest).sessionDescription == null)
        for (final t in (call.request! as TracksRequest).tracks)
          '${t.sessionId}/${t.trackName}'
              '${t.simulcast == null ? '' : '@${t.simulcast!.preferredRid}'}',
  ];

  /// The mids closed (`tracks/close`) by [room].
  List<String> closesOf(Room room) => [
    for (final call in callsOf(room, 'tracks/close'))
      ...(call.request! as CloseTracksRequest).mids,
  ];

  /// What the hub holds for [participantId] in [roomId].
  ParticipantState? announced(String participantId, {String roomId = 'room'}) {
    for (final p in hub.participantsIn(roomId)) {
      if (p.participantId == participantId) return p;
    }
    return null;
  }
}
