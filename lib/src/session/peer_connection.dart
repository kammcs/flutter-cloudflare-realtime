import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        MediaStreamTrack,
        RTCDataChannelMessage,
        RTCDataChannelState,
        RTCIceConnectionState,
        RTCPeerConnectionState,
        RTCSignalingState,
        StatsReport;

import '../broker/models/common.dart';
import 'publish_options.dart';

/// Creates a [PeerConnection] with a WebRTC configuration map, such as
/// `{'iceServers': [...], 'bundlePolicy': 'max-bundle'}`.
///
/// Internal: not exported from the package barrel.
typedef PeerConnectionFactory = Future<PeerConnection> Function(
  Map<String, dynamic> configuration,
);

/// The small slice of `RTCPeerConnection` that `SfuSession` uses.
///
/// It exists so the session can be tested without native WebRTC:
/// `FlutterWebrtcPeerConnection` wraps `flutter_webrtc`, and tests use a
/// scripted fake. SDP is passed through as the broker's
/// [SessionDescription] model and is otherwise opaque here.
///
/// Internal: not exported from the package barrel.
abstract interface class PeerConnection {
  /// The current connection state.
  RTCPeerConnectionState get connectionState;

  /// Connection state changes.
  Stream<RTCPeerConnectionState> get onConnectionState;

  /// ICE connection state changes.
  Stream<RTCIceConnectionState> get onIceConnectionState;

  /// The current signaling state, read from the platform (native
  /// `flutter_webrtc` caches it from asynchronous events).
  Future<RTCSignalingState> signalingState();

  /// Rolls back a pending local or remote offer, returning the signaling
  /// state to `stable`. Does nothing when already stable. Throws if the
  /// platform rejects the rollback.
  Future<void> rollback();

  /// Adds a `sendonly` transceiver of [kind] (`audio` or `video`) that sends
  /// [track], or nothing until a track is set with
  /// [PeerTransceiver.replaceTrack]. [sendEncodings] is empty for the
  /// platform default.
  Future<PeerTransceiver> addSendTransceiver({
    required String kind,
    MediaStreamTrack? track,
    List<SendEncoding> sendEncodings = const [],
  });

  /// Creates an SDP offer.
  Future<SessionDescription> createOffer();

  /// Creates an SDP answer to the current remote offer.
  Future<SessionDescription> createAnswer();

  /// Sets the local description.
  Future<void> setLocalDescription(SessionDescription description);

  /// Sets the remote description.
  Future<void> setRemoteDescription(SessionDescription description);

  /// The transceiver negotiated with [mid], waiting up to [timeout] for it
  /// to appear (a `track` event). Returns null if it doesn't.
  Future<PeerTransceiver?> transceiverForMid(
    String mid, {
    Duration timeout = const Duration(seconds: 5),
  });

  /// Creates a negotiated DataChannel (`negotiated: true`) with the SCTP
  /// stream [id] the SFU assigned. [ordered] and [maxRetransmits] must
  /// mirror the channel's delivery policy; null [maxRetransmits] means
  /// reliable. Binary messages arrive as bytes.
  Future<PeerDataChannel> createDataChannel(
    String label, {
    required int id,
    bool ordered = true,
    int? maxRetransmits,
  });

  /// The connection's WebRTC statistics (`RTCPeerConnection.getStats()`),
  /// for every sender and receiver. Used for active-speaker levels and
  /// debug overlays.
  Future<List<StatsReport>> getStats();

  /// Closes the connection. Safe to call more than once.
  Future<void> close();
}

/// The slice of `RTCDataChannel` that the DataChannel layer uses.
///
/// Internal: not exported from the package barrel.
abstract interface class PeerDataChannel {
  /// The SCTP stream ID.
  int get id;

  /// The channel's label.
  String get label;

  /// The current state, or null before the platform reported one.
  RTCDataChannelState? get state;

  /// State changes.
  Stream<RTCDataChannelState> get onStateChange;

  /// Incoming messages.
  Stream<RTCDataChannelMessage> get onMessage;

  /// Bytes queued for sending. On native platforms this is the last value
  /// the platform reported.
  int get bufferedAmount;

  /// The threshold for [onBufferedAmountLow].
  set bufferedAmountLowThreshold(int value);

  /// Emits the buffered amount each time it falls to or below the
  /// threshold from above it.
  Stream<int> get onBufferedAmountLow;

  /// Sends [message].
  Future<void> send(RTCDataChannelMessage message);

  /// Closes the channel. Safe to call more than once.
  Future<void> close();
}

/// The slice of `RTCRtpTransceiver` (and its sender and receiver) that
/// `SfuSession` uses.
///
/// Internal: not exported from the package barrel.
abstract interface class PeerTransceiver {
  /// The negotiated media ID, or null before negotiation.
  ///
  /// Asynchronous because native `flutter_webrtc` transceivers cache the
  /// `mid` from when they were created; the implementation re-reads it.
  Future<String?> mid();

  /// The track this transceiver receives, for a pulled track.
  MediaStreamTrack? get receiverTrack;

  /// Replaces the sent track without renegotiation. Null stops sending
  /// (mute) and keeps the transceiver and its `mid`.
  Future<void> replaceTrack(MediaStreamTrack? track);

  /// Restricts the transceiver's codecs to [mimeTypes], in that order (plus
  /// retransmission and FEC). Does nothing if none of them is supported.
  Future<void> setCodecPreferences(String kind, List<String> mimeTypes);

  /// Updates the sender's encodings, matched by `rid` (or by position when
  /// the encodings have no `rid`).
  Future<void> setEncodings(List<SendEncoding> encodings);

  /// Whether the sender has sent any media (`outbound-rtp` `bytesSent > 0`).
  Future<bool> hasSentMedia();

  /// Stops the transceiver. The next offer marks its m-line as rejected.
  Future<void> stop();
}
