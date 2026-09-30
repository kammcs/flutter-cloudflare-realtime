import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

import '../broker/models/common.dart';
import 'peer_connection.dart';
import 'publish_options.dart';

/// Creates a [FlutterWebrtcPeerConnection]: the default
/// [PeerConnectionFactory].
///
/// Internal: not exported from the package barrel.
Future<PeerConnection> createFlutterWebrtcPeerConnection(
  Map<String, dynamic> configuration,
) async => FlutterWebrtcPeerConnection(
  await webrtc.createPeerConnection(configuration),
);

/// [PeerConnection] over a `flutter_webrtc` [webrtc.RTCPeerConnection].
///
/// Internal: not exported from the package barrel.
class FlutterWebrtcPeerConnection implements PeerConnection {
  /// Wraps [pc] and takes over its state and track callbacks.
  FlutterWebrtcPeerConnection(this._pc) {
    _pc
      ..onConnectionState = _connectionStates.add
      ..onIceConnectionState = _iceStates.add
      ..onTrack = (_) => _trackEvents.add(null);
  }

  final webrtc.RTCPeerConnection _pc;
  final _connectionStates =
      StreamController<webrtc.RTCPeerConnectionState>.broadcast();
  final _iceStates = StreamController<webrtc.RTCIceConnectionState>.broadcast();
  final _trackEvents = StreamController<void>.broadcast();
  bool _closed = false;

  @override
  webrtc.RTCPeerConnectionState get connectionState =>
      _pc.connectionState ??
      webrtc.RTCPeerConnectionState.RTCPeerConnectionStateNew;

  @override
  Stream<webrtc.RTCPeerConnectionState> get onConnectionState =>
      _connectionStates.stream;

  @override
  Stream<webrtc.RTCIceConnectionState> get onIceConnectionState =>
      _iceStates.stream;

  @override
  Future<webrtc.RTCSignalingState> signalingState() async =>
      await _pc.getSignalingState() ??
      webrtc.RTCSignalingState.RTCSignalingStateStable;

  @override
  Future<void> rollback() async {
    // `{type: rollback}` is standard WebRTC. flutter_webrtc passes the type
    // string through to libwebrtc (Android `Type.fromCanonicalForm`, Darwin
    // `typeForString`, the C++ wrapper on desktop). If a platform rejects
    // it, this throws and the session fails as `signalingStuck`.
    final rollback = webrtc.RTCSessionDescription('', 'rollback');
    switch (await signalingState()) {
      // Per the WebRTC spec: the side that made the offer rolls it back.
      case webrtc.RTCSignalingState.RTCSignalingStateHaveLocalOffer ||
          webrtc.RTCSignalingState.RTCSignalingStateHaveRemotePrAnswer:
        await _pc.setLocalDescription(rollback);
      case webrtc.RTCSignalingState.RTCSignalingStateHaveRemoteOffer ||
          webrtc.RTCSignalingState.RTCSignalingStateHaveLocalPrAnswer:
        await _pc.setRemoteDescription(rollback);
      case _:
        break;
    }
  }

  @override
  Future<PeerTransceiver> addSendTransceiver({
    required String kind,
    webrtc.MediaStreamTrack? track,
    List<SendEncoding> sendEncodings = const [],
  }) async {
    final mediaType = kind == 'audio'
        ? webrtc.RTCRtpMediaType.RTCRtpMediaTypeAudio
        : webrtc.RTCRtpMediaType.RTCRtpMediaTypeVideo;
    final init = webrtc.RTCRtpTransceiverInit(
      direction: webrtc.TransceiverDirection.SendOnly,
      sendEncodings: sendEncodings.isEmpty
          ? null
          : [for (final e in sendEncodings) _toRtpEncoding(e)],
    );
    // Without a track (muted from the start), the kind alone creates it.
    final transceiver = track == null
        ? await _pc.addTransceiver(kind: mediaType, init: init)
        : await _pc.addTransceiver(track: track, kind: mediaType, init: init);
    return _FlutterWebrtcTransceiver(_pc, transceiver);
  }

  @override
  Future<SessionDescription> createOffer() async =>
      _fromRtc(await _pc.createOffer());

  @override
  Future<SessionDescription> createAnswer() async =>
      _fromRtc(await _pc.createAnswer());

  @override
  Future<void> setLocalDescription(SessionDescription description) =>
      _pc.setLocalDescription(_toRtc(description));

  @override
  Future<void> setRemoteDescription(SessionDescription description) =>
      _pc.setRemoteDescription(_toRtc(description));

  @override
  Future<PeerTransceiver?> transceiverForMid(
    String mid, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // Port of partytracks' `resolveTransceiver`: look now, then again after
    // each `track` event, until the timeout.
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final found = await _findByMid(mid);
      if (found != null) return found;
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero || _closed) return null;
      try {
        await _trackEvents.stream.first.timeout(remaining);
      } on TimeoutException {
        return _findByMid(mid);
      } on StateError {
        return null; // Closed while waiting.
      }
    }
  }

  Future<PeerTransceiver?> _findByMid(String mid) async {
    for (final t in await _pc.getTransceivers()) {
      if (_safeMid(t) == mid) return _FlutterWebrtcTransceiver(_pc, t);
    }
    return null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _pc.close();
    } finally {
      await _pc.dispose();
      await _connectionStates.close();
      await _iceStates.close();
      await _trackEvents.close();
    }
  }

  static SessionDescription _fromRtc(webrtc.RTCSessionDescription d) =>
      SessionDescription(
        type: d.type == 'answer' ? SdpType.answer : SdpType.offer,
        sdp: d.sdp ?? '',
      );

  static webrtc.RTCSessionDescription _toRtc(SessionDescription d) =>
      webrtc.RTCSessionDescription(d.sdp, d.type.name);

  static webrtc.RTCRtpEncoding _toRtpEncoding(SendEncoding e) =>
      webrtc.RTCRtpEncoding(
        rid: e.rid,
        active: e.active,
        maxBitrate: e.maxBitrate,
        maxFramerate: e.maxFramerate,
        scaleResolutionDownBy: e.scaleResolutionDownBy,
      );
}

/// Reads a transceiver's `mid`, or null. On web the getter throws until the
/// transceiver is negotiated.
String? _safeMid(webrtc.RTCRtpTransceiver t) {
  try {
    final mid = t.mid;
    return mid.isEmpty ? null : mid;
  } catch (_) {
    return null;
  }
}

class _FlutterWebrtcTransceiver implements PeerTransceiver {
  _FlutterWebrtcTransceiver(this._pc, this._t);

  final webrtc.RTCPeerConnection _pc;
  final webrtc.RTCRtpTransceiver _t;

  /// Codec capabilities per kind, fetched once.
  static final Map<String, Future<List<webrtc.RTCRtpCodecCapability>>>
  _capabilities = {};

  static const _auxiliaryCodecs = {'rtx', 'red', 'ulpfec', 'flexfec-03'};

  @override
  Future<String?> mid() async {
    // On web the wrapper reads the live JS transceiver.
    if (kIsWeb) return _safeMid(_t);
    // Native wrappers cache the mid from creation: re-read it.
    final id = _t.transceiverId;
    for (final t in await _pc.getTransceivers()) {
      if (t.transceiverId == id) return _safeMid(t);
    }
    return null;
  }

  @override
  webrtc.MediaStreamTrack? get receiverTrack => _t.receiver.track;

  @override
  Future<void> replaceTrack(webrtc.MediaStreamTrack? track) =>
      _t.sender.replaceTrack(track);

  @override
  Future<void> setCodecPreferences(String kind, List<String> mimeTypes) async {
    if (mimeTypes.isEmpty) return;
    final available = await _capabilities.putIfAbsent(
      kind,
      () => webrtc
          .getRtpSenderCapabilities(kind)
          .then((c) => c.codecs ?? const <webrtc.RTCRtpCodecCapability>[]),
    );
    final preferred = <webrtc.RTCRtpCodecCapability>[];
    for (final mime in mimeTypes) {
      preferred.addAll(
        available.where((c) => c.mimeType.toLowerCase() == mime.toLowerCase()),
      );
    }
    if (preferred.isEmpty) return;
    final auxiliary = available.where((c) {
      final name = c.mimeType.split('/').last.toLowerCase();
      return _auxiliaryCodecs.contains(name);
    });
    await _t.setCodecPreferences([...preferred, ...auxiliary]);
  }

  @override
  Future<void> setEncodings(List<SendEncoding> encodings) async {
    final parameters = _t.sender.parameters;
    final current = parameters.encodings ?? const <webrtc.RTCRtpEncoding>[];
    for (var i = 0; i < encodings.length; i++) {
      final wanted = encodings[i];
      final target = wanted.rid == null
          ? (i < current.length ? current[i] : null)
          : current.where((e) => e.rid == wanted.rid).firstOrNull;
      if (target == null) continue;
      target
        ..active = wanted.active
        ..maxBitrate = wanted.maxBitrate
        ..maxFramerate = wanted.maxFramerate
        ..scaleResolutionDownBy = wanted.scaleResolutionDownBy;
    }
    await _t.sender.setParameters(parameters);
  }

  @override
  Future<bool> hasSentMedia() async {
    for (final report in await _t.sender.getStats()) {
      if (report.type != 'outbound-rtp') continue;
      final bytes = report.values['bytesSent'];
      final sent = bytes is num ? bytes : num.tryParse('$bytes');
      if (sent != null && sent > 0) return true;
    }
    return false;
  }

  @override
  Future<void> stop() => _t.stop();
}
