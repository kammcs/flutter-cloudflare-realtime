/// @docImport '../room/cloudflare_realtime.dart';
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../audio/audio_output_exception.dart';
import '../broker/broker_exception.dart';
import '../calls/system_call_types.dart';
import '../media/media_errors.dart';
import '../session/sfu_session_events.dart';

/// How much a [CloudflareRealtimeLogRecord] matters.
enum CloudflareRealtimeLogLevel {
  /// Output of a debug aid the app turned on, such as
  /// [CloudflareRealtime.debugPlatformCallTiming].
  debug,

  /// Something happened that helps explain a call's behavior later: a
  /// system call event, a stuck step that was given up on.
  info,

  /// Something failed and the package carried on without it: a prewarm, a
  /// screen wake lock, the proximity sensor, a device list.
  warning,

  /// Something failed that leaves part of the call not working, such as
  /// call audio routing.
  error,
}

/// One line the package logs, passed to [CloudflareRealtime.logger].
///
/// The record keeps what is safe to log apart from what may not be:
///
/// - [message], [errorType] and [errorCode] are log-safe. [message] is
///   written by the package and never contains an error's text, a request
///   or response body, a session description (SDP), a token, a URL or a
///   payload. [errorType] is the error's class name and [errorCode] a short
///   code (a `PlatformException.code`, an HTTP status, the SFU's
///   `errorCode`). [toString] has only these.
/// - [error] and [stackTrace] are the originals, for an app that wants them
///   (in a debug build, or a crash reporter it trusts). An error's text can
///   echo what the broker answered, including the app's own data.
///   [CloudflareRealtime.defaultLogger] prints them only when
///   [CloudflareRealtime.debugLogFullErrors] is on.
final class CloudflareRealtimeLogRecord {
  /// Creates a record. [errorCode], when left out, is read from [error]
  /// (see [logSafeErrorCode]).
  CloudflareRealtimeLogRecord(
    this.level,
    this.message, {
    this.error,
    this.stackTrace,
    String? errorCode,
  }) : errorCode = errorCode ?? logSafeErrorCode(error);

  /// How much it matters.
  final CloudflareRealtimeLogLevel level;

  /// What happened, written by the package: for example `prewarm failed`.
  /// Log-safe.
  final String message;

  /// The error, if the line is about one. **Not log-safe**: its text may
  /// carry response bodies, URLs or other data the app didn't mean to log.
  final Object? error;

  /// Where [error] was caught, if known. Not printed by default.
  final StackTrace? stackTrace;

  /// A short code for [error], safe to log, or `null` when it has none: a
  /// `PlatformException`'s `code`, a broker error's HTTP status and
  /// `errorCode`, the SFU's `errorCode` for a track, a
  /// `SystemCallException`'s code. Also set without an [error] when a
  /// platform API answered with a status number.
  final String? errorCode;

  /// The class name of [error], or `null` without one. Log-safe. (In an
  /// obfuscated build, the obfuscated name.)
  String? get errorType => error?.runtimeType.toString();

  /// The log-safe line: `cloudflare_realtime: <message>`, then the error's
  /// type and code in parentheses, for example `cloudflare_realtime:
  /// prewarm failed (PlatformException, code: error)`. Never the error's
  /// text or the stack.
  @override
  String toString() {
    final details = [?errorType, if (errorCode != null) 'code: $errorCode'];
    return details.isEmpty
        ? 'cloudflare_realtime: $message'
        : 'cloudflare_realtime: $message (${details.join(', ')})';
  }
}

/// Receives the package's log records ([CloudflareRealtime.logger]).
typedef CloudflareRealtimeLogger =
    void Function(CloudflareRealtimeLogRecord record);

/// The longest [CloudflareRealtimeLogRecord.errorCode] kept. A broker's
/// `errorCode` comes from a response body, so it is capped like any other
/// value from outside.
const _maxCodeLength = 64;

/// A short, log-safe code for [error], or `null`.
///
/// Reads the codes the package's own errors and Flutter's
/// `PlatformException` carry; other errors have none. Never reads an
/// error's message or description.
@visibleForTesting
String? logSafeErrorCode(Object? error) {
  final code = switch (error) {
    null => null,
    PlatformException(:final code) => code,
    BrokerException(:final statusCode, :final errorCode) => [
      if (statusCode != null) 'HTTP $statusCode',
      ?errorCode,
    ].join(', '),
    SfuTrackException(:final errorCode) => errorCode,
    SfuDataChannelException(:final errorCode) => errorCode,
    SfuRequestException(:final errorCode) => errorCode,
    SfuSessionFailedException(failure: SfuPeerConnectionFailed(:final kind)) =>
      kind.name,
    SystemCallException(:final code) => code.name,
    AudioOutputException(:final reason) => reason.name,
    MediaException(cause: PlatformException(:final code)) => code,
    _ => null,
  };
  if (code == null || code.isEmpty) return null;
  final line = code.replaceAll(RegExp(r'[\r\n]+'), ' ');
  return line.length <= _maxCodeLength
      ? line
      : '${line.substring(0, _maxCodeLength)}…';
}

/// The package's logging, behind [CloudflareRealtime.logger]. Internal.
abstract final class RealtimeLog {
  /// Where records go. [CloudflareRealtime.logger].
  static CloudflareRealtimeLogger logger = defaultLogger;

  /// Whether [defaultLogger] prints errors in full.
  /// [CloudflareRealtime.debugLogFullErrors].
  static bool fullErrors = false;

  /// Prints [record] with `debugPrint`: its log-safe line, and with
  /// [fullErrors] on, the error's text and a few frames of its stack.
  static void defaultLogger(CloudflareRealtimeLogRecord record) {
    final error = record.error;
    if (!fullErrors || error == null) {
      debugPrint(record.toString());
      return;
    }
    debugPrint('$record: $error');
    final stack = record.stackTrace;
    if (stack != null) debugPrintStack(stackTrace: stack, maxFrames: 8);
  }

  /// Logs a [CloudflareRealtimeLogLevel.debug] record.
  static void debug(String message) => _log(
    CloudflareRealtimeLogRecord(CloudflareRealtimeLogLevel.debug, message),
  );

  /// Logs a [CloudflareRealtimeLogLevel.info] record.
  static void info(String message, {Object? error, String? errorCode}) => _log(
    CloudflareRealtimeLogRecord(
      CloudflareRealtimeLogLevel.info,
      message,
      error: error,
      errorCode: errorCode,
    ),
  );

  /// Logs a [CloudflareRealtimeLogLevel.warning] record.
  static void warning(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? errorCode,
  }) => _log(
    CloudflareRealtimeLogRecord(
      CloudflareRealtimeLogLevel.warning,
      message,
      error: error,
      stackTrace: stackTrace,
      errorCode: errorCode,
    ),
  );

  /// Logs a [CloudflareRealtimeLogLevel.error] record.
  static void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? errorCode,
  }) => _log(
    CloudflareRealtimeLogRecord(
      CloudflareRealtimeLogLevel.error,
      message,
      error: error,
      stackTrace: stackTrace,
      errorCode: errorCode,
    ),
  );

  static void _log(CloudflareRealtimeLogRecord record) {
    try {
      logger(record);
    } catch (_) {
      // The app's logger threw: logging must never break a call, so the
      // line goes to the default sink instead.
      defaultLogger(record);
    }
  }

  /// Restores the defaults. For tests.
  @visibleForTesting
  static void reset() {
    logger = defaultLogger;
    fullErrors = false;
  }
}
