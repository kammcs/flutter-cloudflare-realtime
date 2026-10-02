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
) async {
  return FlutterWebrtcPeerConnection(
    await webrtc.createPeerConnection(
      platformConfiguration(
        configuration,
        platform: defaultTargetPlatform,
        isWeb: kIsWeb,
      ),
    ),
  );
}

/// [configuration], adjusted for the `flutter_webrtc` plugin on [platform]:
/// on Windows and Linux (not the web), at most [maxDesktopIceServers]
/// `iceServers` entries. Every other platform gets [configuration] itself.
///
/// Internal: not exported from the package barrel.
Map<String, dynamic> platformConfiguration(
  Map<String, dynamic> configuration, {
  required TargetPlatform platform,
  required bool isWeb,
}) {
  final iceServers = configuration['iceServers'];
  if (isWeb ||
      (platform != TargetPlatform.windows &&
          platform != TargetPlatform.linux) ||
      iceServers is! List<Map<String, dynamic>>) {
    return configuration;
  }
  return {
    ...configuration,
    'iceServers': limitIceServers(iceServers, maxDesktopIceServers),
  };
}

/// The most `iceServers` entries the `flutter_webrtc` desktop plugin
/// (Windows, Linux) accepts.
///
/// Its C++ layer copies the entries into a fixed array of 8
/// (`kMaxIceServerSize`) without a bounds check, so a ninth entry corrupts
/// memory. Each entry holds one URL (see `IceServer.toRtcIceServers`), and
/// Cloudflare's TURN service returns up to 9 URLs.
const maxDesktopIceServers = 8;

/// At most [max] of [servers], in their order.
///
/// Drops entries on port 53 first (browsers block that port, and
/// Cloudflare's docs say those URLs time out there), then duplicate URLs,
/// then entries from the end.
///
/// Internal: not exported from the package barrel.
List<Map<String, dynamic>> limitIceServers(
  List<Map<String, dynamic>> servers,
  int max,
) {
  if (servers.length <= max) return servers;
  final seen = <String>{};
  final kept = <Map<String, dynamic>>[];
  for (final server in servers) {
    final urls = server['urls'];
    final key = '$urls|${server['username']}';
    if (urls is String && _port53.hasMatch(urls)) continue;
    if (!seen.add(key)) continue;
    kept.add(server);
  }
  return kept.length <= max ? kept : kept.sublist(0, max);
}

final _port53 = RegExp(r'^(?:stuns?|turns?):[^?]*:53(?:\?|$)');

/// Explicit, empty offer/answer constraints.
///
/// Without an argument, native `flutter_webrtc` (Android, Darwin, Windows,
/// Linux) sends `{mandatory: {OfferToReceiveAudio: true,
/// OfferToReceiveVideo: true}}`. Under Unified Plan, libwebrtc then adds a
/// `recvonly` audio and a `recvonly` video transceiver to the first offer
/// that lacks them. The SFU answers those undeclared m-lines, which leaves
/// stray transceivers on every session and m-lines that no track request
/// names. Browsers add nothing for `createOffer()`, so an empty map matches
/// the web (and partytracks). See `docs/design.md` §4.2.
const Map<String, dynamic> _noReceiveConstraints = <String, dynamic>{};

/// [PeerConnection] over a `flutter_webrtc` [webrtc.RTCPeerConnection].
///
/// Internal: not exported from the package barrel.
class FlutterWebrtcPeerConnection implements PeerConnection {
  /// Wraps [pc] and takes over its state and track callbacks.
  FlutterWebrtcPeerConnection(this._pc) {
    _pc
      ..onConnectionState = _connectionStates.add
      ..onIceConnectionState = _iceStates.add
      // The SFU opens `server-events` in-band; keep it to close on [close].
      ..onDataChannel = _dataChannels.add
      ..onTrack = (_) => _trackEvents.add(null);
  }

  final webrtc.RTCPeerConnection _pc;
  final _connectionStates =
      StreamController<webrtc.RTCPeerConnectionState>.broadcast();
  final _iceStates = StreamController<webrtc.RTCIceConnectionState>.broadcast();
  final _trackEvents = StreamController<void>.broadcast();
  final List<webrtc.RTCDataChannel> _dataChannels = [];
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
      _fromRtc(await _pc.createOffer(_noReceiveConstraints));

  @override
  Future<SessionDescription> createAnswer() async =>
      _fromRtc(await _pc.createAnswer(_noReceiveConstraints));

  @override
  Future<void> setLocalDescription(SessionDescription description) =>
      _pc.setLocalDescription(_toRtc(description));

  @override
  Future<void> setRemoteDescription(SessionDescription description) =>
      _pc.setRemoteDescription(_toRtc(description));

  @override
  Future<SessionDescription?> localDescription() async {
    final webrtc.RTCSessionDescription? description;
    try {
      description = await _pc.getLocalDescription();
    } catch (_) {
      // Android's plugin throws (a NullPointerException in
      // `MethodCallHandlerImpl`) instead of answering null while there is
      // no local description yet: an SFU offer applied as the session's
      // first SDP (`datachannels/establish`) read it before any was set.
      return null;
    }
    final sdp = description?.sdp;
    if (description == null || sdp == null || sdp.isEmpty) return null;
    return _fromRtc(description);
  }

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
  Future<List<webrtc.StatsReport>> getStats() => _pc.getStats();

  @override
  Future<PeerDataChannel> createDataChannel(
    String label, {
    required int id,
    bool ordered = true,
    int? maxRetransmits,
  }) async {
    final init = _NegotiatedDataChannelInit()
      ..negotiated = true
      ..id = id
      ..ordered = ordered
      // Web: deliver binary as ArrayBuffer, not Blob (whose asynchronous
      // decoding can reorder messages).
      ..binaryType = 'binary';
    if (maxRetransmits != null) init.maxRetransmits = maxRetransmits;
    final channel = await _pc.createDataChannel(label, init);
    _dataChannels
      ..removeWhere(
        (c) => c.state == webrtc.RTCDataChannelState.RTCDataChannelClosed,
      )
      ..add(channel);
    return FlutterWebrtcDataChannel(
      channel,
      id: id,
      label: label,
      // The browser fires `open` reliably; native platforms can miss it.
      isOpenInStats: kIsWeb ? null : () => _isDataChannelOpenInStats(id),
    );
  }

  /// Whether the connection's stats report the DataChannel with SCTP stream
  /// [id] as open.
  ///
  /// On Windows and Android, `flutter_webrtc` never delivers the `open`
  /// state of a negotiated channel, so the Dart channel's state stays null
  /// although the channel works. (Both plugins register the observer only
  /// after libwebrtc has created the channel, and the Dart side listens to
  /// the channel's events later still, which misses an open during
  /// creation.)
  /// `getStats()` still reports the channel's real state as a
  /// `data-channel` report. See `docs/design.md` §9.
  Future<bool> _isDataChannelOpenInStats(int id) async {
    if (_closed) return false;
    for (final report in await _pc.getStats()) {
      if (report.type != 'data-channel') continue;
      final values = report.values;
      if ('${values['dataChannelIdentifier']}' == '$id' &&
          values['state'] == 'open') {
        return true;
      }
    }
    return false;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      // Close the DataChannels while the platform still knows the
      // connection: after `close()`, the Windows plugin forgets it, and
      // `dispose()` then fails to close them (`dataChannelClose()
      // peerConnection is null`), leaking their native observers.
      for (final channel in _dataChannels) {
        try {
          await channel.close();
        } catch (_) {
          // Already closed, or unknown to the platform.
        }
      }
      _dataChannels.clear();
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

/// The entry of [current] (a fresh `getTransceivers()` list) that is the
/// same native transceiver as [original], or null.
///
/// Matches on the sender's ID, which every native plugin reports stably.
/// The `transceiverId` isn't stable: Android reports a random ID until the
/// transceiver has a mid and the mid afterwards, and Darwin always reports
/// the mid (empty before negotiation). Only the C++ desktop plugin keeps
/// one ID. So the transceiver ID is only a fallback, for a sender without
/// an ID. See `docs/design.md` §9.
///
/// Internal: not exported from the package barrel.
webrtc.RTCRtpTransceiver? findSameTransceiver(
  webrtc.RTCRtpTransceiver original,
  List<webrtc.RTCRtpTransceiver> current,
) {
  final senderId = _safeSenderId(original);
  if (senderId != null) {
    for (final t in current) {
      if (_safeSenderId(t) == senderId) return t;
    }
    return null;
  }
  final id = original.transceiverId;
  if (id.isEmpty) return null;
  for (final t in current) {
    if (t.transceiverId == id) return t;
  }
  return null;
}

String? _safeSenderId(webrtc.RTCRtpTransceiver t) {
  try {
    final id = t.sender.senderId;
    return id.isEmpty ? null : id;
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
    final current = findSameTransceiver(_t, await _pc.getTransceivers());
    return current == null ? null : _safeMid(current);
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
  Future<void> stop() async {
    if (kIsWeb) return _t.stop();
    // The native plugins look the transceiver up by the ID cached at
    // creation, which Darwin no longer knows once the transceiver has a
    // mid: stop the current entry instead (see [findSameTransceiver]).
    final current = findSameTransceiver(_t, await _pc.getTransceivers());
    await (current ?? _t).stop();
  }
}

/// `RTCDataChannelInit` that keeps `maxRetransmits: 0`.
///
/// `flutter_webrtc`'s `toMap()` only sends `maxRetransmits` when it is
/// positive, so the unreliable profile (`maxRetransmits: 0`) would silently
/// become reliable on native platforms, breaking the SFU's rule that every
/// endpoint mirrors the channel's delivery policy. Android, Darwin and the
/// C++ desktop plugin all apply the key when present. (The web
/// implementation doesn't use `toMap()` and drops 0 as well; see
/// `docs/design.md` §9.)
class _NegotiatedDataChannelInit extends webrtc.RTCDataChannelInit {
  @override
  Map<String, dynamic> toMap() => {
    ...super.toMap(),
    if (maxRetransmits >= 0) 'maxRetransmits': maxRetransmits,
  };
}

/// [PeerDataChannel] over a `flutter_webrtc` [webrtc.RTCDataChannel].
///
/// With `isOpenInStats` (native platforms), it works around a missed `open`
/// event: while the channel's state is unknown or `connecting`, it asks
/// `isOpenInStats` with a growing delay (from [probeInterval] to
/// [maxProbeInterval]) and reports `open` once the stats say so. A state
/// event from the platform always wins, and stops the probing.
///
/// Internal: not exported from the package barrel.
class FlutterWebrtcDataChannel implements PeerDataChannel {
  /// Wraps [_dc], the channel with SCTP stream [id] and [label].
  FlutterWebrtcDataChannel(
    this._dc, {
    required this.id,
    required this.label,
    Future<bool> Function()? isOpenInStats,
    this.probeInterval = const Duration(milliseconds: 20),
    this.maxProbeInterval = const Duration(seconds: 1),
  }) : _state = _dc.state {
    _dc
      ..onBufferedAmountChange = _onBufferedAmountChange
      ..onBufferedAmountLow = _onBufferedAmountLow;
    _platformStates = _dc.stateChangeStream.listen(_setState);
    if (isOpenInStats != null && _isUnsettled) {
      unawaited(_probe(isOpenInStats));
    }
  }

  final webrtc.RTCDataChannel _dc;
  final _states = StreamController<webrtc.RTCDataChannelState>.broadcast();
  late final StreamSubscription<webrtc.RTCDataChannelState> _platformStates;
  final _low = StreamController<int>.broadcast();
  webrtc.RTCDataChannelState? _state;
  bool _closed = false;
  int _threshold = 0;
  int _lastAmount = 0;

  @override
  final int id;

  @override
  final String label;

  /// The first delay between two stats probes.
  final Duration probeInterval;

  /// The longest delay between two stats probes.
  final Duration maxProbeInterval;

  @override
  webrtc.RTCDataChannelState? get state => _state;

  @override
  Stream<webrtc.RTCDataChannelState> get onStateChange => _states.stream;

  @override
  Stream<webrtc.RTCDataChannelMessage> get onMessage => _dc.messageStream;

  bool get _isUnsettled =>
      _state == null ||
      _state == webrtc.RTCDataChannelState.RTCDataChannelConnecting;

  void _setState(webrtc.RTCDataChannelState state) {
    if (_state == state) return;
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  Future<void> _probe(Future<bool> Function() isOpenInStats) async {
    var delay = probeInterval;
    while (true) {
      await Future<void>.delayed(delay);
      if (_closed || !_isUnsettled) return;
      final bool open;
      try {
        open = await isOpenInStats();
      } catch (_) {
        return; // The connection is gone.
      }
      if (_closed || !_isUnsettled) return;
      if (open) {
        _setState(webrtc.RTCDataChannelState.RTCDataChannelOpen);
        return;
      }
      final next = delay * 2;
      delay = next > maxProbeInterval ? maxProbeInterval : next;
    }
  }

  @override
  int get bufferedAmount => _dc.bufferedAmount ?? 0;

  @override
  set bufferedAmountLowThreshold(int value) {
    _threshold = value;
    _dc.bufferedAmountLowThreshold = value;
  }

  @override
  Stream<int> get onBufferedAmountLow => _low.stream;

  // Native platforms report every change, and call `onBufferedAmountLow` on
  // every change below the threshold: detect the crossing here instead.
  void _onBufferedAmountChange(int current, int changed) {
    final previous = _lastAmount;
    _lastAmount = current;
    if (!kIsWeb && previous > _threshold && current <= _threshold) {
      if (!_low.isClosed) _low.add(current);
    }
  }

  // The browser fires `bufferedamountlow` once per crossing.
  void _onBufferedAmountLow(int current) {
    if (kIsWeb && !_low.isClosed) _low.add(current);
  }

  @override
  Future<void> send(webrtc.RTCDataChannelMessage message) => _dc.send(message);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _platformStates.cancel();
    await _low.close();
    await _states.close();
    await _dc.close();
  }
}
