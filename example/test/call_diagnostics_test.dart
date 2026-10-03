import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/call_diagnostics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('describes each step of a reconnection', () {
    const offline = BrokerNetworkException(operation: 'sessions/new');
    expect(
      [
        const RoomConnectionStateChangedEvent(RoomConnectionState.reconnecting),
        const RoomReconnectingEvent(ReconnectReason.peerConnectionFailed),
        const RoomReconnectAttemptEvent(
          reason: ReconnectReason.peerConnectionFailed,
          attempt: 1,
          delay: Duration(milliseconds: 420),
          waited: Duration(milliseconds: 420),
        ),
        const RoomErrorEvent('reconnect', offline),
        const RoomReconnectAttemptEvent(
          reason: ReconnectReason.peerConnectionFailed,
          attempt: 2,
          delay: Duration(milliseconds: 8400),
          waited: Duration(milliseconds: 1200),
        ),
        const RoomReconnectAttemptEvent(
          reason: ReconnectReason.peerConnectionFailed,
          attempt: 3,
          delay: Duration.zero,
          waited: Duration.zero,
          restarted: true,
        ),
        const RoomReconnectedEvent(
          reason: ReconnectReason.peerConnectionFailed,
          duration: Duration(milliseconds: 2950),
          attempts: 3,
        ),
        const RoomReconnectFailedEvent(
          reason: ReconnectReason.networkChanged,
          attempts: 1,
          error: offline,
        ),
      ].map(describeReconnectEvent),
      [
        'state: reconnecting',
        'reconnecting (peerConnectionFailed)',
        'attempt 1 (peerConnectionFailed): backoff 0.4 s, waited 0.4 s',
        'attempt failed: $offline',
        'attempt 2 (peerConnectionFailed): backoff 8.4 s, waited 1.2 s '
            '(cut short)',
        'attempt 3 (peerConnectionFailed): network changed, attempt 2 '
            'abandoned, no backoff',
        'reconnected (peerConnectionFailed) in 3.0 s after 3 attempts',
        'gave up (networkChanged) after 1 attempt: $offline',
      ],
    );
  });

  test('ignores other events', () {
    expect(
      describeReconnectEvent(const RoomErrorEvent('videoCodec', 'x')),
      isNull,
    );
    expect(describeReconnectEvent(const RoomCameraResumedEvent()), isNull);
    expect(logReconnectEvent(const RoomCameraResumedEvent()), isFalse);
  });

  test('prints with a UTC timestamp and a tag', () {
    final printed = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => printed.add(message);
    addTearDown(() => debugPrint = original);

    final logged = logReconnectEvent(
      const RoomReconnectingEvent(ReconnectReason.networkChanged),
      now: DateTime.utc(2026, 10, 3, 9, 56, 18, 500),
    );
    expect(logged, isTrue);
    expect(printed, [
      '[reconnect] 2026-10-03T09:56:18.500Z reconnecting (networkChanged)',
    ]);
  });
}
