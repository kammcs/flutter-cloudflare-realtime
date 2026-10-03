import 'package:cloudflare_realtime/src/reconnect/reconnect_trigger.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

const _new = RTCPeerConnectionState.RTCPeerConnectionStateNew;
const _connecting = RTCPeerConnectionState.RTCPeerConnectionStateConnecting;
const _connected = RTCPeerConnectionState.RTCPeerConnectionStateConnected;
const _disconnected = RTCPeerConnectionState.RTCPeerConnectionStateDisconnected;
const _failed = RTCPeerConnectionState.RTCPeerConnectionStateFailed;
const _closed = RTCPeerConnectionState.RTCPeerConnectionStateClosed;

Duration s(num seconds) => Duration(milliseconds: (seconds * 1000).round());

void main() {
  late ReconnectTrigger trigger;

  setUp(() => trigger = ReconnectTrigger());

  /// Brings the trigger to a connected state at time 0.
  void connect() {
    expect(trigger.peerConnectionStateChanged(_new, s(0)), isNull);
    expect(trigger.peerConnectionStateChanged(_connecting, s(0)), isNull);
    expect(trigger.peerConnectionStateChanged(_connected, s(1)), isNull);
    expect(trigger.nextCheckAt, isNull);
  }

  test('defaults', () {
    const config = ReconnectTriggerOptions();
    expect(config.disconnectedTimeout, s(5));
    expect(config.connectTimeout, s(15));
    expect(config.networkChangeWindow, s(10));
    expect(config.backgroundThreshold, s(30));
    expect(config, const ReconnectTriggerOptions());
  });

  test('failed triggers at once', () {
    connect();
    expect(
      trigger.peerConnectionStateChanged(_failed, s(2)),
      ReconnectReason.peerConnectionFailed,
    );
    expect(trigger.isTriggered, isTrue);
    expect(trigger.triggeredReason, ReconnectReason.peerConnectionFailed);
  });

  group('disconnected', () {
    test('triggers after the timeout', () {
      connect();
      expect(trigger.peerConnectionStateChanged(_disconnected, s(10)), isNull);
      expect(trigger.nextCheckAt, s(15));
      expect(trigger.check(s(14.9)), isNull);
      expect(trigger.check(s(15)), ReconnectReason.disconnectedTooLong);
      expect(trigger.nextCheckAt, isNull);
    });

    test('recovering to connected cancels the timer', () {
      connect();
      trigger.peerConnectionStateChanged(_disconnected, s(10));
      expect(trigger.peerConnectionStateChanged(_connected, s(12)), isNull);
      expect(trigger.nextCheckAt, isNull);
      expect(trigger.check(s(100)), isNull);
    });

    test('a repeated disconnected keeps the original start', () {
      connect();
      trigger.peerConnectionStateChanged(_disconnected, s(10));
      trigger.peerConnectionStateChanged(_disconnected, s(13));
      expect(trigger.nextCheckAt, s(15));
    });

    test('a later state change also evaluates the timer', () {
      connect();
      trigger.peerConnectionStateChanged(_disconnected, s(10));
      expect(
        trigger.peerConnectionStateChanged(_disconnected, s(16)),
        ReconnectReason.disconnectedTooLong,
      );
    });
  });

  group('network changes', () {
    test('while connected only arm the window', () {
      connect();
      expect(trigger.networkChanged(s(20)), isNull);
      expect(trigger.isTriggered, isFalse);
      expect(
        trigger.peerConnectionStateChanged(_disconnected, s(25)),
        ReconnectReason.networkChanged,
      );
    });

    test('a disconnect after the window waits for the timeout', () {
      connect();
      trigger.networkChanged(s(20));
      expect(trigger.peerConnectionStateChanged(_disconnected, s(31)), isNull);
      expect(trigger.check(s(36)), ReconnectReason.disconnectedTooLong);
    });

    test('while disconnected trigger at once', () {
      connect();
      trigger.peerConnectionStateChanged(_disconnected, s(10));
      expect(trigger.networkChanged(s(11)), ReconnectReason.networkChanged);
    });

    test('while connecting defer to the connect timeout', () {
      trigger.peerConnectionStateChanged(_connecting, s(0));
      expect(trigger.networkChanged(s(1)), isNull);
      expect(trigger.nextCheckAt, s(15));
    });
  });

  group('connect timeout', () {
    test('triggers when connected is never reached', () {
      trigger.peerConnectionStateChanged(_new, s(0));
      trigger.peerConnectionStateChanged(_connecting, s(2));
      expect(trigger.nextCheckAt, s(15)); // From `new`.
      expect(trigger.check(s(14)), isNull);
      expect(trigger.check(s(15)), ReconnectReason.connectTimeout);
    });

    test('can be turned off', () {
      trigger = ReconnectTrigger(
        const ReconnectTriggerOptions(connectTimeout: null),
      );
      trigger.peerConnectionStateChanged(_connecting, s(0));
      expect(trigger.nextCheckAt, isNull);
      expect(trigger.check(s(1000)), isNull);
    });
  });

  group('app lifecycle', () {
    test('a long background triggers on resume', () {
      connect();
      trigger.appPaused(s(10));
      expect(trigger.isPaused, isTrue);
      expect(trigger.appResumed(s(40)), ReconnectReason.resumedFromBackground);
      expect(trigger.isPaused, isFalse);
    });

    test('a short background does not', () {
      connect();
      trigger.appPaused(s(10));
      expect(trigger.appResumed(s(39)), isNull);
      expect(trigger.isTriggered, isFalse);
    });

    test('resume catches up on timers that could not run', () {
      connect();
      trigger.peerConnectionStateChanged(_disconnected, s(10));
      trigger.appPaused(s(11));
      expect(trigger.appResumed(s(20)), ReconnectReason.disconnectedTooLong);
    });

    test('a null threshold disables the resume trigger', () {
      trigger = ReconnectTrigger(
        const ReconnectTriggerOptions(backgroundThreshold: null),
      );
      connect();
      trigger.appPaused(s(10));
      expect(trigger.appResumed(s(10000)), isNull);
    });

    test('resume without a pause does nothing', () {
      connect();
      expect(trigger.appResumed(s(1000)), isNull);
    });
  });

  test('session gone triggers at once', () {
    connect();
    expect(trigger.sessionGone(s(3)), ReconnectReason.sessionGone);
  });

  test('closed clears the timers', () {
    connect();
    trigger.peerConnectionStateChanged(_disconnected, s(10));
    expect(trigger.peerConnectionStateChanged(_closed, s(11)), isNull);
    expect(trigger.nextCheckAt, isNull);
    expect(trigger.check(s(100)), isNull);
  });

  test('stays triggered and ignores input until reset', () {
    connect();
    trigger.peerConnectionStateChanged(_failed, s(2));
    expect(trigger.peerConnectionStateChanged(_failed, s(3)), isNull);
    expect(trigger.networkChanged(s(3)), isNull);
    expect(trigger.sessionGone(s(3)), isNull);
    expect(trigger.check(s(100)), isNull);
    trigger.appPaused(s(4));
    expect(trigger.appResumed(s(100)), isNull);
    expect(trigger.triggeredReason, ReconnectReason.peerConnectionFailed);

    trigger.reset();
    expect(trigger.isTriggered, isFalse);
    expect(trigger.state, isNull);
    // The new session connects normally.
    expect(trigger.peerConnectionStateChanged(_connecting, s(5)), isNull);
    expect(trigger.peerConnectionStateChanged(_connected, s(6)), isNull);
    expect(
      trigger.peerConnectionStateChanged(_failed, s(7)),
      ReconnectReason.peerConnectionFailed,
    );
  });

  test('reset clears the network-change window but keeps background', () {
    connect();
    trigger.networkChanged(s(10));
    trigger.appPaused(s(10));
    trigger.sessionGone(s(11));
    trigger.reset();
    trigger.peerConnectionStateChanged(_connected, s(12));
    expect(trigger.peerConnectionStateChanged(_disconnected, s(13)), isNull);
    trigger.peerConnectionStateChanged(_connected, s(14));
    expect(trigger.isPaused, isTrue);
    expect(trigger.appResumed(s(45)), ReconnectReason.resumedFromBackground);
  });
}
