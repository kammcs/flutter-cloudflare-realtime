import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/diagnostics/log.dart';
import 'package:cloudflare_realtime/src/session/peer_connection_warmup.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Text that stands for what must never reach a log: a response body with
/// the app's data, SDP, a token.
const _secret = 'v=0 o=- token=abc123 {"userId":"u-42","email":"a@b.c"}';

void main() {
  late List<String> printed;
  late DebugPrintCallback previousPrint;

  setUp(() {
    printed = [];
    previousPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message ?? '');
    PeerConnectionWarmup.reset();
  });

  tearDown(() {
    debugPrint = previousPrint;
    RealtimeLog.reset();
    PeerConnectionWarmup.reset();
  });

  group('the default logger', () {
    test('prints the message, the error type and its code, not its '
        'text', () {
      RealtimeLog.warning(
        'call audio routing failed',
        error: PlatformException(
          code: 'call_audio',
          message: _secret,
          details: _secret,
        ),
        stackTrace: StackTrace.current,
      );
      expect(printed, [
        'cloudflare_realtime: call audio routing failed '
            '(PlatformException, code: call_audio)',
      ]);
    });

    test('leaves out a broker error\'s description', () {
      RealtimeLog.warning(
        'prewarm failed',
        error: const BrokerResponseException(
          operation: 'sessions/new',
          statusCode: 500,
          errorCode: 'internal_error',
          errorDescription: _secret,
        ),
      );
      expect(printed.single, isNot(contains('token')));
      expect(printed.single, isNot(contains('u-42')));
      expect(
        printed.single,
        'cloudflare_realtime: prewarm failed '
        '(BrokerResponseException, code: HTTP 500, internal_error)',
      );
    });

    test('an error without a code: the type only', () {
      RealtimeLog.warning('enumerateDevices failed', error: _secret);
      expect(printed, [
        'cloudflare_realtime: enumerateDevices failed (String)',
      ]);
    });

    test('a line without an error: the message only', () {
      RealtimeLog.info('a share stopped from the system');
      expect(printed, ['cloudflare_realtime: a share stopped from the system']);
    });

    test('a status code without an error', () {
      RealtimeLog.warning(
        'IOPMAssertionCreateWithName failed',
        errorCode: '-1',
      );
      expect(printed, [
        'cloudflare_realtime: IOPMAssertionCreateWithName failed (code: -1)',
      ]);
    });

    test('debugLogFullErrors adds the error\'s text and stack', () {
      CloudflareRealtime.debugLogFullErrors = true;
      expect(CloudflareRealtime.debugLogFullErrors, isTrue);
      RealtimeLog.warning(
        'prewarm failed',
        error: StateError(_secret),
        stackTrace: StackTrace.current,
      );
      expect(
        printed.first,
        'cloudflare_realtime: prewarm failed (StateError): '
        'Bad state: $_secret',
      );
      expect(printed.length, greaterThan(1), reason: 'the stack');
    });

    test('defaultLogger is off for full errors by default', () {
      expect(CloudflareRealtime.debugLogFullErrors, isFalse);
      expect(CloudflareRealtime.logger, same(RealtimeLog.defaultLogger));
    });
  });

  group('CloudflareRealtime.logger', () {
    test('receives the package\'s records, with the full error in its '
        'own field', () async {
      final records = <CloudflareRealtimeLogRecord>[];
      CloudflareRealtime.logger = records.add;
      final error = StateError(_secret);
      await PeerConnectionWarmup.warm(
        create: (_) async => throw error,
        platform: TargetPlatform.macOS,
      );
      expect(printed, isEmpty, reason: 'the default logger was replaced');
      final record = records.single;
      expect(record.level, CloudflareRealtimeLogLevel.warning);
      expect(record.message, 'prewarm failed');
      expect(record.error, same(error));
      expect(record.errorType, 'StateError');
      expect(record.errorCode, isNull);
      expect(record.toString(), isNot(contains(_secret)));
    });

    test('can forward to the default logger', () {
      final levels = <CloudflareRealtimeLogLevel>[];
      CloudflareRealtime.logger = (record) {
        levels.add(record.level);
        CloudflareRealtime.defaultLogger(record);
      };
      RealtimeLog.error('call audio routing failed', error: _secret);
      expect(levels, [CloudflareRealtimeLogLevel.error]);
      expect(printed, [
        'cloudflare_realtime: call audio routing failed (String)',
      ]);
    });

    test('a logger that throws: the record goes to the default logger', () {
      CloudflareRealtime.logger = (_) => throw StateError('logger bug');
      RealtimeLog.warning('prewarm failed');
      expect(printed, ['cloudflare_realtime: prewarm failed']);
    });

    test('a logger that drops everything', () {
      CloudflareRealtime.logger = (_) {};
      RealtimeLog.warning('prewarm failed', error: _secret);
      expect(printed, isEmpty);
    });
  });

  group('logSafeErrorCode', () {
    test('reads the codes errors carry, never their text', () {
      expect(logSafeErrorCode(null), isNull);
      expect(logSafeErrorCode(_secret), isNull);
      expect(logSafeErrorCode(StateError(_secret)), isNull);
      expect(
        logSafeErrorCode(PlatformException(code: 'denied', message: _secret)),
        'denied',
      );
      expect(
        logSafeErrorCode(
          const BrokerUnauthorizedException(
            operation: 'sessions/new',
            errorDescription: _secret,
          ),
        ),
        'HTTP 401',
      );
      expect(
        logSafeErrorCode(const BrokerNetworkException(operation: 'x')),
        isNull,
      );
      expect(
        logSafeErrorCode(
          const SfuTrackException(
            operation: 'tracks/new',
            trackName: 't',
            errorCode: 'not_found',
            errorDescription: _secret,
          ),
        ),
        'not_found',
      );
      expect(
        logSafeErrorCode(
          const SfuRequestException(operation: 'x', errorCode: 'bad'),
        ),
        'bad',
      );
      expect(
        logSafeErrorCode(
          const SfuDataChannelException(
            operation: 'x',
            name: 'input',
            errorCode: 'gone',
          ),
        ),
        'gone',
      );
      expect(
        logSafeErrorCode(
          SfuSessionFailedException(
            const SfuPeerConnectionFailed(PeerConnectionFailureKind.iceFailed),
          ),
        ),
        'iceFailed',
      );
      expect(
        logSafeErrorCode(
          const SystemCallException(SystemCallErrorCode.filtered, _secret),
        ),
        'filtered',
      );
      expect(
        logSafeErrorCode(
          const AudioOutputException(
            AudioOutputFailure.notFound,
            deviceId: 'd',
            cause: _secret,
          ),
        ),
        'notFound',
      );
      expect(
        logSafeErrorCode(
          MediaCaptureException(
            'Screen capture failed.',
            cause: PlatformException(code: 'getDisplayMedia', message: _secret),
          ),
        ),
        'getDisplayMedia',
      );
    });

    test('caps a long code and keeps it on one line', () {
      final code = logSafeErrorCode(
        BrokerResponseException(operation: 'x', errorCode: 'a\nb${'c' * 100}'),
      )!;
      expect(code, startsWith('a b'));
      expect(code, isNot(contains('\n')));
      expect(code.length, lessThanOrEqualTo(65));
    });
  });

  group('exceptions: toString is log-safe', () {
    test('broker exceptions: status and code, no description', () {
      const response = BrokerResponseException(
        operation: 'tracks/new',
        statusCode: 400,
        errorCode: 'invalid',
        errorDescription: _secret,
      );
      expect(
        response.toString(),
        'BrokerResponseException(tracks/new, status: 400, errorCode: invalid)',
      );
      expect(response.errorDescription, _secret, reason: 'kept as data');
      for (final e in <BrokerException>[
        const BrokerUnauthorizedException(
          operation: 'x',
          errorDescription: _secret,
        ),
        const BrokerForbiddenException(
          operation: 'x',
          errorDescription: _secret,
        ),
        const SessionGoneException(
          operation: 'x',
          sessionId: 's',
          errorDescription: _secret,
        ),
        BrokerNetworkException(operation: 'x', cause: Exception(_secret)),
      ]) {
        expect(e.toString(), isNot(contains('token')), reason: '$e');
      }
    });

    test('SFU exceptions: code, no description', () {
      const track = SfuTrackException(
        operation: 'tracks/new',
        trackName: 'camera-1',
        errorCode: 'bad',
        errorDescription: _secret,
      );
      expect(
        track.toString(),
        'SfuTrackException(tracks/new, trackName: camera-1, errorCode: bad)',
      );
      const request = SfuRequestException(
        operation: 'tracks/new',
        errorCode: 'bad',
        errorDescription: _secret,
      );
      expect(
        request.toString(),
        'SfuRequestException(tracks/new, errorCode: bad)',
      );
      const channel = SfuDataChannelException(
        operation: 'datachannels/new',
        name: 'input',
        errorCode: 'bad',
        errorDescription: _secret,
      );
      expect(
        channel.toString(),
        'SfuDataChannelException(datachannels/new, name: input, '
        'errorCode: bad)',
      );
    });

    test('media exceptions: the cause\'s type, not its text', () {
      final e = MediaCaptureException(
        'Screen capture failed.',
        cause: PlatformException(code: 'x', message: _secret),
      );
      expect(
        e.toString(),
        'MediaCaptureException: Screen capture failed. '
        '(cause: PlatformException)',
      );
      expect(
        const MediaPermissionDeniedException('Denied.').toString(),
        'MediaPermissionDeniedException: Denied.',
      );
    });

    test('AudioOutputException: the cause\'s type, not its text', () {
      expect(
        const AudioOutputException(
          AudioOutputFailure.other,
          deviceId: 'speaker-2',
          cause: _secret,
        ).toString(),
        'AudioOutputException(other, deviceId: speaker-2, cause: String)',
      );
    });

    test('SystemCallException: the code, not the platform\'s message', () {
      const e = SystemCallException(SystemCallErrorCode.unavailable, _secret);
      expect(e.toString(), 'SystemCallException(unavailable)');
      expect(e.message, _secret, reason: 'kept as data');
    });
  });
}
