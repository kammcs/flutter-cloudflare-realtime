import 'dart:async';

import 'package:cloudflare_realtime/src/session/peer_connection_warmup.dart';
import 'package:cloudflare_realtime/src/session/sfu_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_harness.dart';

void main() {
  late SessionHarness h;
  late List<FakePeerConnection> warmed;

  Future<FakePeerConnection> create(Map<String, dynamic> configuration) async {
    final pc = FakePeerConnection(configuration: configuration);
    warmed.add(pc);
    return pc;
  }

  Future<void> warm([TargetPlatform platform = TargetPlatform.macOS]) =>
      PeerConnectionWarmup.warm(create: create, platform: platform);

  setUp(() {
    PeerConnectionWarmup.reset();
    h = SessionHarness();
    warmed = [];
  });

  tearDown(PeerConnectionWarmup.reset);

  test('on macOS creates one idle peer connection and keeps it', () async {
    final first = warm();
    expect(warm(), same(first));
    await first;
    await warm();
    expect(warmed, hasLength(1));
    expect(warmed.single.closed, isFalse);
    expect(warmed.single.configuration['iceServers'], isEmpty);
    expect(warmed.single.transceivers, isEmpty);
    expect(warmed.single.log, isEmpty, reason: 'nothing negotiated');
  });

  test('elsewhere does nothing', () async {
    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.macOS) continue;
      await warm(platform);
    }
    expect(warmed, isEmpty);
    await PeerConnectionWarmup.whenDone(null);
  });

  test('a connect closes it once its own peer connection exists, and the '
      'next warm-up creates another', () async {
    await warm();
    final session = await connectSfuSession(
      broker: h.broker,
      createPeerConnection: (configuration) {
        expect(warmed.single.closed, isFalse, reason: 'still open');
        return h.peerConnections.call(configuration);
      },
    );
    await pumpEventQueue();
    expect(warmed.single.closed, isTrue);
    expect(h.pc.closed, isFalse);

    await warm();
    expect(warmed, hasLength(2));
    expect(warmed.last.closed, isFalse);
    await session.close();
  });

  test('a failed connect closes it too', () async {
    await warm();
    await expectLater(
      connectSfuSession(
        broker: h.broker,
        createPeerConnection: (_) async => throw StateError('no factory'),
      ),
      throwsA(isA<StateError>()),
    );
    await pumpEventQueue();
    expect(warmed.single.closed, isTrue);
  });

  test('a failure is logged, not thrown, and the next call tries '
      'again', () async {
    final logged = <String?>[];
    final original = debugPrint;
    debugPrint = (message, {wrapWidth}) => logged.add(message);
    addTearDown(() => debugPrint = original);
    await PeerConnectionWarmup.warm(
      create: (_) async => throw StateError('no factory'),
      platform: TargetPlatform.macOS,
    );
    expect(logged.single, contains('prewarm failed'));
    await warm();
    expect(warmed, hasLength(1));
  });

  test('a connect waits for a running warm-up before sessions/new', () async {
    final created = Completer<FakePeerConnection>();
    final warming = PeerConnectionWarmup.warm(
      create: (_) => created.future,
      platform: TargetPlatform.macOS,
    );
    final connecting = connectSfuSession(
      broker: h.broker,
      createPeerConnection: h.peerConnections.call,
    );
    await pumpEventQueue();
    expect(h.broker.calls, isEmpty);

    final pc = FakePeerConnection();
    created.complete(pc);
    await warming;
    final session = await connecting;
    expect(h.broker.operations, contains('sessions/new'));
    await pumpEventQueue();
    expect(pc.closed, isTrue);
    await session.close();
  });

  test('a connect stops waiting for a stuck warm-up after the negotiation '
      'timeout, and the late peer connection is closed', () async {
    final created = Completer<FakePeerConnection>();
    unawaited(
      PeerConnectionWarmup.warm(
        create: (_) => created.future,
        platform: TargetPlatform.macOS,
      ),
    );
    final session = await connectSfuSession(
      broker: h.broker,
      options: const SfuSessionOptions(
        negotiationTimeout: Duration(milliseconds: 10),
      ),
      createPeerConnection: h.peerConnections.call,
    );
    expect(h.broker.operations, contains('sessions/new'));

    final late = FakePeerConnection();
    created.complete(late);
    await pumpEventQueue();
    expect(late.closed, isTrue);
    await session.close();
  });

  test('a connect without a warm-up does not wait', () async {
    final session = await connectSfuSession(
      broker: h.broker,
      createPeerConnection: h.peerConnections.call,
    );
    expect(h.broker.operations, contains('sessions/new'));
    await session.close();
  });
}
