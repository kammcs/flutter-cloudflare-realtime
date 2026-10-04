import 'dart:async';
import 'dart:ui' as ui;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/diagnostics/platform_call_timing.dart'
    show PlatformCallTimer;
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A platform that answers each message when the test says so.
class _FakePlatform extends BinaryMessenger {
  final List<(String, Completer<ByteData?>)> sent = [];

  @override
  Future<ByteData?>? send(String channel, ByteData? message) {
    final reply = Completer<ByteData?>();
    sent.add((channel, reply));
    return reply.future;
  }

  void answerAll() {
    for (final (_, reply) in sent) {
      if (!reply.isCompleted) reply.complete(null);
    }
  }

  @override
  void setMessageHandler(String channel, MessageHandler? handler) {}

  @override
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) async {}
}

const _secret = 'v=0 o=- SECRET-SDP-AND-TOKEN';

ByteData _call(String method, [Object? arguments]) =>
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));

void main() {
  group('timing', _timing);

  testWidgets('ensureInitialized keeps a binding that exists', (tester) async {
    expect(PlatformCallTimingBinding.ensureInitialized(), same(tester.binding));
  });
}

void _timing() {
  late _FakePlatform platform;
  late BinaryMessenger messenger;
  late List<PlatformCallTimingEvent> events;
  late StreamSubscription<PlatformCallTimingEvent> subscription;
  late List<String> logged;
  late DebugPrintCallback previousPrint;

  setUp(() {
    platform = _FakePlatform();
    messenger = PlatformCallTimingBinding.wrapMessenger(platform);
    events = [];
    logged = [];
    previousPrint = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add(message ?? '');
  });

  tearDown(() {
    PlatformCallTimer.reset();
    debugPrint = previousPrint;
  });

  /// Runs [body] in fake time with the timing's events collected.
  void run(void Function(FakeAsync async) body) {
    fakeAsync((async) {
      subscription = CloudflareRealtime.debugPlatformCallTimingEvents.listen(
        events.add,
      );
      body(async);
      CloudflareRealtime.debugPlatformCallTiming = null;
      subscription.cancel();
      async.flushMicrotasks();
    });
  }

  test('is off by default, and then times nothing and runs no timer', () {
    expect(CloudflareRealtime.debugPlatformCallTiming, isNull);
    run((async) {
      final reply = messenger.send(
        flutterWebrtcMethodChannel,
        _call('getSources'),
      );
      expect(platform.sent, hasLength(1), reason: 'still sent');
      async.elapseBlocking(const Duration(seconds: 2));
      platform.answerAll();
      async.elapse(const Duration(seconds: 1));
      expect(reply, completes);
      expect(async.periodicTimerCount, 0);
    });
    expect(events, isEmpty);
    expect(logged, isEmpty);
  });

  test('times each call with its method name and argument keys', () {
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions();
      expect(async.periodicTimerCount, 1);
      async.elapse(const Duration(milliseconds: 100));
      messenger.send(
        flutterWebrtcMethodChannel,
        _call('setRemoteDescription', {
          'peerConnectionId': 'pc-$_secret',
          'description': {'sdp': _secret, 'type': 'answer'},
        }),
      );
      async.elapse(const Duration(milliseconds: 60));
      platform.answerAll();
      async.elapse(const Duration(milliseconds: 100));
    });
    final answered = events.whereType<PlatformCallAnsweredEvent>().single;
    expect(answered.call.channel, flutterWebrtcMethodChannel);
    expect(answered.call.method, 'setRemoteDescription');
    expect(answered.call.argumentKeys, ['peerConnectionId', 'description']);
    expect(answered.call.sentAt, const Duration(milliseconds: 100));
    expect(answered.call.duration, const Duration(milliseconds: 60));
    expect(answered.longestGap, Duration.zero);
    expect(events.whereType<EventLoopGapEvent>(), isEmpty);
    expect(logged.first, contains('platform call timing on'));
    expect(
      logged.where((l) => l.contains('setRemoteDescription')),
      isEmpty,
      reason: 'faster than the 100 ms threshold for the log',
    );
  });

  test('names the call sent when the event loop stopped', () {
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions();
      // An asynchronous call that stays pending across the gap.
      messenger.send(flutterWebrtcMethodChannel, _call('createOffer'));
      async.elapse(const Duration(milliseconds: 500));
      // A call the platform answers on the UI thread, blocking it for 4 s.
      messenger.send(
        flutterWebrtcMethodChannel,
        _call('createPeerConnection', {'configuration': _secret}),
      );
      async.elapseBlocking(const Duration(seconds: 4));
      platform.sent.last.$2.complete(null);
      async.elapse(const Duration(milliseconds: 100));
    });
    final gap = events.whereType<EventLoopGapEvent>().single;
    expect(gap.duration, greaterThanOrEqualTo(const Duration(seconds: 4)));
    expect(gap.duration, lessThan(const Duration(milliseconds: 4100)));
    expect(gap.sent.single.method, 'createPeerConnection');
    expect(gap.sent.single.duration, const Duration(seconds: 4));
    expect(gap.pending.single.method, 'createOffer');
    expect(gap.pending.single.answeredAt, isNull);

    final answered = events.whereType<PlatformCallAnsweredEvent>().single;
    expect(answered.call.method, 'createPeerConnection');
    expect(
      answered.longestGap,
      greaterThanOrEqualTo(const Duration(seconds: 4)),
    );

    expect(
      logged,
      contains(
        allOf(
          contains('event loop stopped for 40'),
          contains('sent then: createPeerConnection(4000 ms)'),
          contains('pending: createOffer(unanswered)'),
        ),
      ),
    );
    expect(
      logged,
      contains(
        allOf(
          contains('createPeerConnection took 4000 ms'),
          contains('the event loop stopped for'),
        ),
      ),
    );
  });

  test('reports a gap with no call sent', () {
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions(log: false);
      async.elapse(const Duration(milliseconds: 100));
      async.elapseBlocking(const Duration(milliseconds: 300));
      async.elapse(const Duration(milliseconds: 100));
      // Under the threshold: not a gap.
      async.elapseBlocking(const Duration(milliseconds: 200));
      async.elapse(const Duration(milliseconds: 100));
    });
    final gap = events.whereType<EventLoopGapEvent>().single;
    expect(gap.sent, isEmpty);
    expect(gap.pending, isEmpty);
    expect(logged, isEmpty, reason: 'log: false');
  });

  test('times only the chosen channels; null times every channel', () {
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions();
      messenger.send('other.plugin', _call('level'));
      CloudflareRealtime.debugPlatformCallTiming = null;
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions(channels: null);
      messenger.send('other.plugin', _call('level', {'id': _secret}));
      messenger.send(
        'flutter/platform',
        const JSONMethodCodec().encodeMethodCall(
          const MethodCall('Clipboard.setData', {'text': _secret}),
        ),
      );
      messenger.send(
        'plain.messages',
        const StringCodec().encodeMessage(_secret),
      );
      platform.answerAll();
      async.elapse(const Duration(milliseconds: 100));
    });
    final calls = [
      for (final e in events.whereType<PlatformCallAnsweredEvent>()) e.call,
    ];
    expect(
      [for (final c in calls) '${c.channel} ${c.method}'],
      [
        'other.plugin level',
        'flutter/platform Clipboard.setData',
        'plain.messages <message>',
      ],
    );
    expect(calls[0].argumentKeys, ['id']);
    expect(calls[1].argumentKeys, ['text']);
  });

  test('records no argument values or replies', () {
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions(
            channels: null,
            slowCallThreshold: Duration.zero,
          );
      messenger.send(
        flutterWebrtcMethodChannel,
        _call('createAnswer', {'constraints': _secret}),
      );
      async.elapseBlocking(const Duration(seconds: 1));
      platform.sent.single.$2.complete(
        const StandardMethodCodec().encodeSuccessEnvelope({'sdp': _secret}),
      );
      async.elapse(const Duration(milliseconds: 100));
    });
    expect(events, isNotEmpty);
    expect(logged, isNotEmpty);
    final text = [
      for (final e in events)
        switch (e) {
          PlatformCallAnsweredEvent(:final call) =>
            '$call ${call.argumentKeys}',
          EventLoopGapEvent(:final sent, :final pending) => '$sent $pending',
        },
      ...logged,
    ].join('\n');
    expect(text, contains('createAnswer'));
    expect(text, isNot(contains('SECRET')));
  });

  test('turning it off stops the timer and forgets calls in flight', () {
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions();
      messenger.send(flutterWebrtcMethodChannel, _call('getStats'));
      CloudflareRealtime.debugPlatformCallTiming = null;
      expect(async.periodicTimerCount, 0);
      platform.answerAll();
      async.elapse(const Duration(seconds: 1));
    });
    expect(events, isEmpty);
  });

  test('says so when no messenger is wrapped', () {
    PlatformCallTimer.reset();
    run((async) {
      CloudflareRealtime.debugPlatformCallTiming =
          const PlatformCallTimingOptions();
    });
    expect(logged, contains(contains("platform calls aren't timed")));
  });
}
