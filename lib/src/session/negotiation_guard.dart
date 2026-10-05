import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        MediaStreamTrack,
        RTCIceConnectionState,
        RTCPeerConnectionState,
        RTCSignalingState,
        StatsReport;

import '../broker/models/common.dart';
import '../diagnostics/log.dart';
import '../util/native_negotiation.dart';
import 'peer_connection.dart';
import 'publish_options.dart';

/// A [PeerConnection] whose negotiation steps can't hang forever
/// (`docs/design.md` §4.2, Bounded negotiation steps).
///
/// Every call an SDP exchange awaits (`createOffer`, `setLocalDescription`,
/// `addTransceiver`, a transceiver's `mid`, `replaceTrack` and `stop`, the
/// signaling state, a rollback, a negotiated DataChannel) is bounded by
/// [timeout]. When one doesn't complete in time, [onTimeout] is told which
/// step it was and returns the error to throw: `SfuSession` fails itself
/// with `PeerConnectionFailureKind.negotiationTimeout`, so the room
/// replaces the session instead of its operation queue waiting forever.
/// What completes late stays on this peer connection, which the replacement
/// closes; a late DataChannel is closed here.
///
/// Stats (`getStats`, `hasSentMedia`) and `setEncodings` aren't bounded:
/// they aren't part of an exchange, and stats are slow on a loaded machine.
/// [close] is bounded by [timeout] without [onTimeout]: closing doesn't
/// wait on a stuck platform.
///
/// Internal: not exported from the package barrel.
class NegotiationGuard implements PeerConnection {
  /// Wraps [inner]. A null [timeout] bounds nothing.
  NegotiationGuard(this.inner, {required this.timeout});

  /// The wrapped peer connection.
  final PeerConnection inner;

  /// How long one step may take; null for no bound.
  final Duration? timeout;

  /// Called when a step timed out, with its name; returns the error the
  /// step throws. Without it, a `TimeoutException` is thrown.
  Object Function(String step)? onTimeout;

  /// Runs [step] ([name]) within [timeout], plus [extra]. [onLate] gets a
  /// result that arrives after the timeout.
  Future<T> guard<T>(
    String name,
    Future<T> Function() step, {
    Duration extra = Duration.zero,
    void Function(T late)? onLate,
  }) {
    final limit = timeout;
    if (limit == null) return step();
    // A native SDP call given up on stops holding back `getStats()` and
    // the macOS microphone selection ([NativeNegotiation.whenIdle]).
    final abandoned = Completer<void>();
    final future = NativeNegotiation.releasingOn(abandoned.future, step);
    final bound = limit + extra;
    return future.timeout(
      bound,
      onTimeout: () {
        abandoned.complete();
        // Errors that arrive late are dropped (the timeout already listens
        // for them); a late value may need releasing.
        if (onLate != null) {
          unawaited(future.then(onLate, onError: (Object _) {}));
        }
        RealtimeLog.warning(
          '$name did not complete within ${bound.inMilliseconds} ms',
        );
        throw onTimeout?.call(name) ?? TimeoutException(name, bound);
      },
    );
  }

  PeerTransceiver _wrap(PeerTransceiver transceiver) =>
      transceiver is _GuardedTransceiver
      ? transceiver
      : _GuardedTransceiver(this, transceiver);

  @override
  RTCPeerConnectionState get connectionState => inner.connectionState;

  @override
  Stream<RTCPeerConnectionState> get onConnectionState =>
      inner.onConnectionState;

  @override
  Stream<RTCIceConnectionState> get onIceConnectionState =>
      inner.onIceConnectionState;

  @override
  Future<RTCSignalingState> signalingState() =>
      guard('signalingState', inner.signalingState);

  @override
  Future<void> rollback() => guard('rollback', inner.rollback);

  @override
  Future<PeerTransceiver> addSendTransceiver({
    required String kind,
    MediaStreamTrack? track,
    List<SendEncoding> sendEncodings = const [],
  }) async => _wrap(
    await guard(
      'addTransceiver',
      () => inner.addSendTransceiver(
        kind: kind,
        track: track,
        sendEncodings: sendEncodings,
      ),
    ),
  );

  @override
  Future<SessionDescription> createOffer() =>
      guard('createOffer', inner.createOffer);

  @override
  Future<SessionDescription> createAnswer() =>
      guard('createAnswer', inner.createAnswer);

  @override
  Future<void> setLocalDescription(SessionDescription description) => guard(
    'setLocalDescription',
    () => inner.setLocalDescription(description),
  );

  @override
  Future<void> setRemoteDescription(SessionDescription description) => guard(
    'setRemoteDescription',
    () => inner.setRemoteDescription(description),
  );

  @override
  Future<SessionDescription?> localDescription() =>
      guard('localDescription', inner.localDescription);

  @override
  Future<PeerTransceiver?> transceiverForMid(
    String mid, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    // It waits up to its own timeout for the track event; the bound comes
    // on top of that.
    final found = await guard(
      'transceiverForMid',
      () => inner.transceiverForMid(mid, timeout: timeout),
      extra: timeout,
    );
    return found == null ? null : _wrap(found);
  }

  @override
  Future<PeerDataChannel> createDataChannel(
    String label, {
    required int id,
    bool ordered = true,
    int? maxRetransmits,
  }) => guard(
    'createDataChannel',
    () => inner.createDataChannel(
      label,
      id: id,
      ordered: ordered,
      maxRetransmits: maxRetransmits,
    ),
    onLate: (channel) => unawaited(channel.close().catchError((Object _) {})),
  );

  @override
  Future<List<StatsReport>> getStats() => inner.getStats();

  @override
  Future<void> close() {
    final limit = timeout;
    final closing = inner.close();
    if (limit == null) return closing;
    return closing.timeout(
      limit,
      onTimeout: () => RealtimeLog.warning(
        'closing the peer connection did not complete within '
        '${limit.inMilliseconds} ms',
      ),
    );
  }
}

class _GuardedTransceiver implements PeerTransceiver {
  _GuardedTransceiver(this._guard, this._inner);

  final NegotiationGuard _guard;
  final PeerTransceiver _inner;

  @override
  Future<String?> mid() => _guard.guard('mid', _inner.mid);

  @override
  MediaStreamTrack? get receiverTrack => _inner.receiverTrack;

  @override
  Future<void> replaceTrack(MediaStreamTrack? track) =>
      _guard.guard('replaceTrack', () => _inner.replaceTrack(track));

  @override
  Future<void> setCodecPreferences(String kind, List<String> mimeTypes) =>
      _guard.guard(
        'setCodecPreferences',
        () => _inner.setCodecPreferences(kind, mimeTypes),
      );

  @override
  Future<void> setEncodings(List<SendEncoding> encodings) =>
      _inner.setEncodings(encodings);

  @override
  Future<bool> hasSentMedia() => _inner.hasSentMedia();

  @override
  Future<void> stop() => _guard.guard('stop', _inner.stop);
}
