/// A failed broker call.
///
/// Subclasses name the cases callers act on:
/// - [BrokerUnauthorizedException] (HTTP 401): the app's credential is
///   missing or expired. Refresh it and retry.
/// - [BrokerForbiddenException] (HTTP 403): not a member of the room, not
///   the session's owner, or a pull from another room's session.
/// - [SessionGoneException] (HTTP 410, or `errorCode: session_error`): the
///   SFU session expired. Create a new session.
/// - [BrokerNetworkException] and [BrokerTimeoutException]: the request
///   didn't complete.
/// - [BrokerProtocolException]: a successful response the client couldn't
///   parse.
///
/// - [BrokerResponseException]: any other error response, with the SFU's
///   [errorCode] and [errorDescription] when the body has them.
///
/// The class is sealed, so a `switch` over these cases is exhaustive. A
/// custom `BrokerClient` throws them through their public constructors.
///
/// [toString] is log-safe: the class, [operation], [statusCode] and
/// [errorCode], never [errorDescription] (the response body's text, which a
/// broker may fill with its own data), SDP, header values or tokens.
sealed class BrokerException implements Exception {
  /// Creates a broker exception. For the subclasses' constructors.
  const BrokerException({
    required this.operation,
    this.statusCode,
    this.errorCode,
    this.errorDescription,
  });

  /// The broker operation that failed, such as `tracks/new`.
  final String operation;

  /// The HTTP status, or null if no response arrived.
  final int? statusCode;

  /// The `errorCode` from the response body, if any.
  final String? errorCode;

  /// The `errorDescription` from the response body, if any. Left out of
  /// [toString]: it is the broker's or the SFU's text, and may carry data
  /// that shouldn't reach a log.
  final String? errorDescription;

  /// The class name used by [toString].
  String get _kind => 'BrokerException';

  @override
  String toString() {
    final parts = <String>[operation];
    if (statusCode != null) parts.add('status: $statusCode');
    if (errorCode != null) parts.add('errorCode: $errorCode');
    return '$_kind(${parts.join(', ')})';
  }
}

/// An error response that the other [BrokerException]s don't name: a
/// non-2xx status other than 401, 403 and 410 (the SFU's status and body
/// pass through the broker unchanged), or an SFU error in a 2xx body that
/// leaves nothing to return (`sessions/new` without a session).
final class BrokerResponseException extends BrokerException {
  /// Creates the exception.
  const BrokerResponseException({
    required super.operation,
    super.statusCode,
    super.errorCode,
    super.errorDescription,
  });

  @override
  String get _kind => 'BrokerResponseException';
}

/// HTTP 401: the broker didn't accept the app's credential.
final class BrokerUnauthorizedException extends BrokerException {
  /// Creates the exception.
  const BrokerUnauthorizedException({
    required super.operation,
    super.statusCode = 401,
    super.errorCode,
    super.errorDescription,
  });

  @override
  String get _kind => 'BrokerUnauthorizedException';
}

/// HTTP 403: the broker refused the call. The caller isn't in the room,
/// doesn't own the session, or tried to pull from a session in another room.
///
/// The reference brokers answer with
/// `{"errorCode": "forbidden", "errorDescription": "..."}`.
final class BrokerForbiddenException extends BrokerException {
  /// Creates the exception.
  const BrokerForbiddenException({
    required super.operation,
    super.statusCode = 403,
    super.errorCode,
    super.errorDescription,
  });

  @override
  String get _kind => 'BrokerForbiddenException';
}

/// The SFU session no longer exists: HTTP 410, or an `errorCode` of
/// `session_error`. An unconnected session can expire before its first track
/// or DataChannel operation.
///
/// Recover by creating a new session and re-pushing and re-pulling tracks.
final class SessionGoneException extends BrokerException {
  /// Creates the exception.
  const SessionGoneException({
    required super.operation,
    this.sessionId,
    super.statusCode,
    super.errorCode,
    super.errorDescription,
  });

  /// The session that is gone, when the call named one.
  final String? sessionId;

  @override
  String get _kind => 'SessionGoneException';
}

/// The request didn't complete: a connection, DNS or TLS failure, or an
/// aborted request.
final class BrokerNetworkException extends BrokerException {
  /// Creates the exception.
  const BrokerNetworkException({required super.operation, this.cause});

  /// The underlying error, for diagnostics. Not included in [toString].
  final Object? cause;

  @override
  String get _kind => 'BrokerNetworkException';
}

/// The request took longer than [BrokerOptions.timeout]. It was aborted.
final class BrokerTimeoutException extends BrokerNetworkException {
  /// Creates the exception.
  const BrokerTimeoutException({required super.operation, this.timeout});

  /// The timeout that elapsed.
  final Duration? timeout;

  @override
  String get _kind => 'BrokerTimeoutException';

  @override
  String toString() => timeout == null
      ? super.toString()
      : '$_kind($operation, timeout: ${timeout!.inMilliseconds} ms)';
}

/// A successful (2xx) response that the client couldn't parse: invalid
/// JSON, or a required field missing or of the wrong type.
final class BrokerProtocolException extends BrokerException {
  /// Creates the exception.
  const BrokerProtocolException({
    required super.operation,
    super.statusCode,
    this.message,
  });

  /// What was wrong, naming fields but never their values.
  final String? message;

  @override
  String get _kind => 'BrokerProtocolException';

  @override
  String toString() {
    final base = super.toString();
    if (message == null) return base;
    return '${base.substring(0, base.length - 1)}, $message)';
  }
}
