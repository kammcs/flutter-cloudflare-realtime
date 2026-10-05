import '../broker/broker_exception.dart';

/// The state of an [SfuSession]'s connection to the SFU.
///
/// Mirrors the peer connection's `connectionState`, except that the session
/// also reports [failed] when the SFU session is gone, and [closed] once
/// `close()` is called.
enum SfuConnectionState {
  /// Nothing has been negotiated yet (`RTCPeerConnectionState` `new`). A
  /// session starts connecting with its first push or pull.
  initial,

  /// ICE and DTLS are connecting.
  connecting,

  /// Media can flow.
  connected,

  /// The connection was lost, and may come back on its own.
  disconnected,

  /// The connection or the SFU session failed. It won't recover: replace the
  /// session (see [SfuSessionFailure]).
  failed,

  /// `close()` was called.
  closed,
}

/// Why an [SfuSession] can no longer be used. Emitted once, on
/// `SfuSession.failures`, and kept in `SfuSession.failure`.
///
/// The session is dead after a failure: operations fail fast with an
/// [SfuSessionFailedException]. To recover, connect a new session and move
/// the publications and subscriptions to it with `republish` and
/// `resubscribe`; a `Room` does this by itself (`docs/design.md` §8).
sealed class SfuSessionFailure {
  const SfuSessionFailure();

  /// A short, log-safe description.
  String get reason;

  @override
  String toString() => '$runtimeType($reason)';
}

/// The SFU session expired or was removed: a broker call failed with a
/// [SessionGoneException].
final class SfuSessionGone extends SfuSessionFailure {
  /// Creates the failure.
  const SfuSessionGone(this.exception);

  /// The broker error that reported it.
  final SessionGoneException exception;

  @override
  String get reason => 'SFU session gone (${exception.operation})';
}

/// What made a peer connection fail.
enum PeerConnectionFailureKind {
  /// The connection state became `failed`.
  connectionFailed,

  /// The ICE connection state became `failed`.
  iceFailed,

  /// The ICE connection stayed `disconnected` longer than
  /// `SfuSessionOptions.iceDisconnectedTimeout`.
  iceDisconnectedTimeout,

  /// The peer connection closed without `SfuSession.close()` being called.
  closedUnexpectedly,

  /// A failed SDP exchange left the signaling state unstable and rolling it
  /// back failed (or isn't supported on this platform), so no further
  /// negotiation is possible.
  signalingStuck,

  /// A peer-connection step of an SDP exchange (`createOffer`,
  /// `setLocalDescription`, `addTransceiver`, …), or creating the peer
  /// connection, didn't complete within
  /// `SfuSessionOptions.negotiationTimeout`: the platform's WebRTC stack is
  /// stuck, so the session is given up rather than its operations waiting
  /// forever.
  negotiationTimeout,

  /// `SfuSession.debugSimulateFailure` was called: a test or demo of
  /// reconnection.
  simulated,
}

/// The session's peer connection failed.
final class SfuPeerConnectionFailed extends SfuSessionFailure {
  /// Creates the failure.
  const SfuPeerConnectionFailed(this.kind);

  /// What failed.
  final PeerConnectionFailureKind kind;

  @override
  String get reason => 'peer connection failed (${kind.name})';
}

/// An `SfuSession` operation failed.
///
/// Broker errors pass through unchanged as [BrokerException]s (including
/// [SessionGoneException]); these cover the session's own failure modes.
/// The class is sealed, so a `switch` over them is exhaustive:
///
/// - [SfuSessionClosedException]: the session was closed.
/// - [SfuSessionFailedException]: the session failed ([SfuSessionFailure]).
/// - [SfuInterruptedException]: the publication, subscription or
///   DataChannel was unpublished, closed, interrupted or moved to another
///   session before the operation completed.
/// - [SfuTrackException] and [SfuDataChannelException]: the SFU rejected
///   one track or DataChannel of a request.
/// - [SfuRequestException]: the SFU rejected a whole request.
/// - [SfuProtocolException]: the SFU's answer was unusable.
sealed class SfuSessionException implements Exception {
  /// Creates the exception. For the subclasses' constructors.
  const SfuSessionException(this.message);

  /// A log-safe description. Never contains SDP or tokens.
  final String message;

  @override
  String toString() => '$runtimeType($message)';
}

/// The session was closed before or during the operation.
final class SfuSessionClosedException extends SfuSessionException {
  /// Creates the exception.
  const SfuSessionClosedException() : super('the session is closed');
}

/// The session failed before the operation could run. See [failure].
final class SfuSessionFailedException extends SfuSessionException {
  /// Creates the exception.
  SfuSessionFailedException(this.failure) : super(failure.reason);

  /// Why the session failed.
  final SfuSessionFailure failure;
}

/// The SFU rejected one track of a request (a per-track error), or its
/// result was missing. Other tracks in the same batch are unaffected.
final class SfuTrackException extends SfuSessionException {
  /// Creates the exception.
  const SfuTrackException({
    required this.operation,
    required this.trackName,
    this.errorCode,
    this.errorDescription,
  }) : super(operation);

  /// The broker operation, such as `tracks/new`.
  final String operation;

  /// The track that failed.
  final String trackName;

  /// The SFU's `errorCode` for this track, if any. Null when the response
  /// had no result for the track.
  final String? errorCode;

  /// The SFU's `errorDescription` for this track, if any. Not in
  /// [toString], which stays log-safe.
  final String? errorDescription;

  @override
  String toString() =>
      'SfuTrackException($operation, trackName: $trackName'
      '${errorCode == null ? ', no result' : ', errorCode: $errorCode'})';
}

/// A request-level error returned in a 2xx response body (`errorCode` on
/// the whole response), which fails every track in the request.
final class SfuRequestException extends SfuSessionException {
  /// Creates the exception.
  const SfuRequestException({
    required this.operation,
    required this.errorCode,
    this.errorDescription,
  }) : super(operation);

  /// The broker operation, such as `tracks/new`.
  final String operation;

  /// The SFU's `errorCode`.
  final String errorCode;

  /// The SFU's `errorDescription`, if any. Not in [toString], which stays
  /// log-safe.
  final String? errorDescription;

  @override
  String toString() => 'SfuRequestException($operation, errorCode: $errorCode)';
}

/// The SFU rejected one DataChannel of a request (a per-channel error), or
/// its result was missing. Other channels in the same batch are unaffected.
final class SfuDataChannelException extends SfuSessionException {
  /// Creates the exception.
  const SfuDataChannelException({
    required this.operation,
    required this.name,
    this.errorCode,
    this.errorDescription,
  }) : super(operation);

  /// The broker operation, such as `datachannels/new`.
  final String operation;

  /// The channel's name.
  final String name;

  /// The SFU's `errorCode` for this channel, if any. Null when the response
  /// had no usable result for it.
  final String? errorCode;

  /// The SFU's `errorDescription` for this channel, if any. Not in
  /// [toString], which stays log-safe.
  final String? errorDescription;

  @override
  String toString() =>
      'SfuDataChannelException($operation, name: $name'
      '${errorCode == null ? ', no result' : ', errorCode: $errorCode'})';
}

/// The publication, subscription or DataChannel was unpublished, closed,
/// interrupted or moved to another session before the operation completed,
/// or the session it ran on was replaced. [message] says which.
final class SfuInterruptedException extends SfuSessionException {
  /// Creates the exception.
  const SfuInterruptedException(super.message);
}

/// The SFU's answer was unusable: a request without a result, an answer
/// without the expected session description, or a transceiver without a
/// `mid`. [message] says which.
final class SfuProtocolException extends SfuSessionException {
  /// Creates the exception.
  const SfuProtocolException(super.message);
}
