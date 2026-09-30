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
/// Any other non-2xx status gives a plain [BrokerException] with the SFU's
/// [errorCode] and [errorDescription] when the body has them.
///
/// Messages never include SDP, header values or tokens.
class BrokerException implements Exception {
  /// Creates a broker exception.
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

  /// The `errorDescription` from the response body, if any.
  final String? errorDescription;

  /// The class name used by [toString].
  String get _kind => 'BrokerException';

  @override
  String toString() {
    final parts = <String>[operation];
    if (statusCode != null) parts.add('status: $statusCode');
    if (errorCode != null) parts.add('errorCode: $errorCode');
    if (errorDescription != null) {
      parts.add('errorDescription: ${_truncate(errorDescription!)}');
    }
    return '$_kind(${parts.join(', ')})';
  }

  static String _truncate(String s) =>
      s.length <= 200 ? s : '${s.substring(0, 200)}…';
}

/// HTTP 401: the broker didn't accept the app's credential.
class BrokerUnauthorizedException extends BrokerException {
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
class BrokerForbiddenException extends BrokerException {
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
class SessionGoneException extends BrokerException {
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
class BrokerNetworkException extends BrokerException {
  /// Creates the exception.
  const BrokerNetworkException({required super.operation, this.cause});

  /// The underlying error, for diagnostics. Not included in [toString].
  final Object? cause;

  @override
  String get _kind => 'BrokerNetworkException';
}

/// The request took longer than [BrokerConfig.timeout]. It was aborted.
class BrokerTimeoutException extends BrokerNetworkException {
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
class BrokerProtocolException extends BrokerException {
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
