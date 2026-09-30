import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/session/peer_connection.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        MediaStreamTrack,
        RTCIceConnectionState,
        RTCPeerConnectionState,
        RTCSignalingState;

import 'fake_broker_client.dart';

/// A [MediaStreamTrack] with no native side.
class FakeMediaStreamTrack extends MediaStreamTrack {
  FakeMediaStreamTrack({required String kind, String? id, this.label = ''})
    : _kind = kind,
      _id = id ?? '$kind-${++_count}';

  static int _count = 0;

  final String _kind;
  final String _id;
  bool _enabled = true;

  /// Whether [stop] was called.
  bool stopped = false;

  @override
  String? get id => _id;

  @override
  final String? label;

  @override
  String? get kind => _kind;

  @override
  bool get enabled => _enabled;

  @override
  set enabled(bool value) => _enabled = value;

  @override
  bool? get muted => false;

  @override
  Future<void> stop() async => stopped = true;

  @override
  // ignore: deprecated_member_use
  Future<void> dispose() async {}

  @override
  String toString() => 'FakeMediaStreamTrack($_id)';
}

/// Creates [FakePeerConnection]s and keeps them, for injection into
/// `connectSfuSession`.
class FakePeerConnectionFactory {
  FakePeerConnectionFactory({this.remoteMedia});

  /// Passed to each created connection.
  final List<FakeRemoteMedia> Function(String sdp)? remoteMedia;

  /// Every connection created, in order.
  final List<FakePeerConnection> created = [];

  /// The last connection created.
  FakePeerConnection get last => created.last;

  /// The [PeerConnectionFactory].
  Future<PeerConnection> call(Map<String, dynamic> configuration) async {
    final pc = FakePeerConnection(
      configuration: configuration,
      remoteMedia: remoteMedia,
    );
    created.add(pc);
    return pc;
  }
}

/// A scripted [PeerConnection].
///
/// SDP is opaque: offers are `offer-1`, `offer-2`, ...; answers
/// `answer-1`, ... Setting a local offer assigns mids `0`, `1`, ... to
/// transceivers that have none. Setting a remote offer creates a receiving
/// transceiver for each [FakeRemoteMedia] that [remoteMedia] returns for its
/// SDP (wire it to `FakeBrokerClient.remoteMediaForOffer`).
///
/// Signaling states follow WebRTC: setting an offer in the wrong state (for
/// example a remote offer while a local offer is pending) throws, as a
/// real peer connection does, and [rollback] withdraws a pending offer.
///
/// Every call is appended to [log], so tests can check sequencing. Make the
/// next call to a method throw with [failNext] (including `rollback`).
class FakePeerConnection implements PeerConnection {
  FakePeerConnection({this.configuration = const {}, this.remoteMedia});

  /// The configuration the connection was created with.
  final Map<String, dynamic> configuration;

  /// Maps a remote offer's SDP to the media it carries.
  final List<FakeRemoteMedia> Function(String sdp)? remoteMedia;

  /// Method calls, such as `createOffer` or `setRemoteDescription(answer)`.
  final List<String> log = [];

  /// Every transceiver, in creation order (including stopped ones).
  final List<FakeTransceiver> transceivers = [];

  /// The last local and remote descriptions set.
  SessionDescription? localDescription;
  SessionDescription? remoteDescription;

  final Map<String, Object> _failures = {};
  final _connectionStates = StreamController<RTCPeerConnectionState>.broadcast(
    sync: true,
  );
  final _iceStates = StreamController<RTCIceConnectionState>.broadcast(
    sync: true,
  );
  RTCPeerConnectionState _connectionState =
      RTCPeerConnectionState.RTCPeerConnectionStateNew;
  RTCSignalingState _signalingState = RTCSignalingState.RTCSignalingStateStable;
  int _offers = 0;
  int _answers = 0;
  int _mids = 0;
  bool closed = false;

  /// Makes the next call to [method] (such as `createOffer`) throw [error].
  void failNext(String method, Object error) => _failures[method] = error;

  /// Emits a connection state change.
  void emitConnectionState(RTCPeerConnectionState state) {
    _connectionState = state;
    _connectionStates.add(state);
  }

  /// Emits an ICE connection state change.
  void emitIceConnectionState(RTCIceConnectionState state) =>
      _iceStates.add(state);

  /// The transceiver with [mid], if any.
  FakeTransceiver? byMid(String mid) =>
      transceivers.where((t) => t.currentMid == mid).firstOrNull;

  void _record(String entry, String method) {
    log.add(entry);
    final error = _failures.remove(method);
    if (error != null) throw error;
    if (closed) throw StateError('FakePeerConnection is closed');
  }

  @override
  RTCPeerConnectionState get connectionState => _connectionState;

  @override
  Stream<RTCPeerConnectionState> get onConnectionState =>
      _connectionStates.stream;

  @override
  Stream<RTCIceConnectionState> get onIceConnectionState => _iceStates.stream;

  /// The current signaling state, synchronously.
  RTCSignalingState get currentSignalingState => _signalingState;

  @override
  Future<RTCSignalingState> signalingState() async => _signalingState;

  @override
  Future<void> rollback() async {
    _record('rollback(${_rollbackSide ?? 'none'})', 'rollback');
    switch (_signalingState) {
      case RTCSignalingState.RTCSignalingStateHaveLocalOffer:
        // Mids assigned by the withdrawn offer are released.
        for (final t in _pendingLocal) {
          t.currentMid = null;
        }
      case RTCSignalingState.RTCSignalingStateHaveRemoteOffer:
        // Transceivers the withdrawn remote offer created go away.
        transceivers.removeWhere(_pendingRemote.contains);
      case _:
        break;
    }
    _pendingLocal.clear();
    _pendingRemote.clear();
    _signalingState = RTCSignalingState.RTCSignalingStateStable;
  }

  String? get _rollbackSide => switch (_signalingState) {
    RTCSignalingState.RTCSignalingStateHaveLocalOffer => 'local',
    RTCSignalingState.RTCSignalingStateHaveRemoteOffer => 'remote',
    _ => null,
  };

  /// The active send transceivers (not stopped) each offer carried, in
  /// order: what the SFU would see as sending m-lines.
  final List<List<FakeTransceiver>> offeredSenders = [];

  final List<FakeTransceiver> _pendingLocal = [];
  final List<FakeTransceiver> _pendingRemote = [];

  void _requireState(Set<RTCSignalingState> allowed, String what) {
    if (!allowed.contains(_signalingState)) {
      throw StateError('$what is invalid in ${_signalingState.name}');
    }
  }

  static const _stable = RTCSignalingState.RTCSignalingStateStable;
  static const _haveLocalOffer =
      RTCSignalingState.RTCSignalingStateHaveLocalOffer;
  static const _haveRemoteOffer =
      RTCSignalingState.RTCSignalingStateHaveRemoteOffer;

  @override
  Future<PeerTransceiver> addSendTransceiver({
    required String kind,
    MediaStreamTrack? track,
    List<SendEncoding> sendEncodings = const [],
  }) async {
    _record('addTransceiver($kind)', 'addTransceiver');
    final t = FakeTransceiver._(
      this,
      kind: kind,
      direction: 'sendonly',
      sentTrack: track,
      sendEncodings: sendEncodings,
    );
    transceivers.add(t);
    return t;
  }

  @override
  Future<SessionDescription> createOffer() async {
    _record('createOffer', 'createOffer');
    offeredSenders.add([
      for (final t in transceivers)
        if (t.direction == 'sendonly' && !t.stopped) t,
    ]);
    return SessionDescription.offer('offer-${++_offers}');
  }

  @override
  Future<SessionDescription> createAnswer() async {
    _record('createAnswer', 'createAnswer');
    return SessionDescription.answer('answer-${++_answers}');
  }

  @override
  Future<void> setLocalDescription(SessionDescription description) async {
    _record(
      'setLocalDescription(${description.type.name})',
      'setLocalDescription',
    );
    if (description.type == SdpType.offer) {
      _requireState({_stable, _haveLocalOffer}, 'setLocalDescription(offer)');
      for (final t in transceivers) {
        if (t.currentMid == null && !t.stopped) {
          t.currentMid = '${_mids++}';
          _pendingLocal.add(t);
        }
      }
      _signalingState = _haveLocalOffer;
    } else {
      _requireState({_haveRemoteOffer}, 'setLocalDescription(answer)');
      _pendingRemote.clear();
      _signalingState = _stable;
    }
    localDescription = description;
  }

  @override
  Future<void> setRemoteDescription(SessionDescription description) async {
    _record(
      'setRemoteDescription(${description.type.name})',
      'setRemoteDescription',
    );
    if (description.type == SdpType.offer) {
      _requireState({_stable, _haveRemoteOffer}, 'setRemoteDescription(offer)');
      for (final media in remoteMedia?.call(description.sdp) ?? const []) {
        final t = FakeTransceiver._(
          this,
          kind: media.kind,
          direction: 'recvonly',
          mid: media.mid,
          receiverTrack: FakeMediaStreamTrack(
            kind: media.kind,
            id: 'remote-${media.mid}',
          ),
        );
        transceivers.add(t);
        _pendingRemote.add(t);
      }
      _signalingState = _haveRemoteOffer;
    } else {
      _requireState({_haveLocalOffer}, 'setRemoteDescription(answer)');
      _pendingLocal.clear();
      _signalingState = _stable;
    }
    remoteDescription = description;
  }

  @override
  Future<PeerTransceiver?> transceiverForMid(
    String mid, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _record('transceiverForMid($mid)', 'transceiverForMid');
    return byMid(mid);
  }

  @override
  Future<void> close() async {
    log.add('close');
    closed = true;
    _connectionState = RTCPeerConnectionState.RTCPeerConnectionStateClosed;
    await _connectionStates.close();
    await _iceStates.close();
  }
}

/// A transceiver of a [FakePeerConnection].
class FakeTransceiver implements PeerTransceiver {
  FakeTransceiver._(
    this._pc, {
    required this.kind,
    required this.direction,
    this.sentTrack,
    this.sendEncodings = const [],
    String? mid,
    this.receiverTrack,
  }) : currentMid = mid;

  final FakePeerConnection _pc;

  /// `audio` or `video`.
  final String kind;

  /// `sendonly` for pushed tracks, `recvonly` for pulled ones.
  final String direction;

  /// The track being sent (updated by [replaceTrack]).
  MediaStreamTrack? sentTrack;

  /// The encodings, from creation and [setEncodings].
  List<SendEncoding> sendEncodings;

  /// The codec preferences set, if any.
  List<String>? codecPreferences;

  /// The negotiated mid.
  String? currentMid;

  /// Whether [stop] was called.
  bool stopped = false;

  /// What [hasSentMedia] returns.
  bool sentMedia = false;

  /// How many times [hasSentMedia] was called.
  int statsPolls = 0;

  @override
  final MediaStreamTrack? receiverTrack;

  @override
  Future<String?> mid() async => currentMid;

  @override
  Future<void> replaceTrack(MediaStreamTrack? track) async {
    _pc._record('replaceTrack(${track?.id})', 'replaceTrack');
    sentTrack = track;
  }

  @override
  Future<void> setCodecPreferences(String kind, List<String> mimeTypes) async {
    _pc._record(
      'setCodecPreferences($kind, ${mimeTypes.join(',')})',
      'setCodecPreferences',
    );
    codecPreferences = mimeTypes;
  }

  @override
  Future<void> setEncodings(List<SendEncoding> encodings) async {
    _pc._record('setEncodings', 'setEncodings');
    sendEncodings = encodings;
  }

  @override
  Future<bool> hasSentMedia() async {
    statsPolls++;
    return sentMedia;
  }

  @override
  Future<void> stop() async {
    _pc._record('stop($currentMid)', 'stop');
    stopped = true;
  }
}
