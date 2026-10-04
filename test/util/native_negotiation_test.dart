import 'dart:async';

import 'package:cloudflare_realtime/src/util/native_negotiation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('idle at once when nothing runs', () async {
    expect(NativeNegotiation.isRunning, isFalse);
    await NativeNegotiation.whenIdle();
  });

  test('waits for every running call, then is idle', () async {
    final first = Completer<int>();
    final second = Completer<void>();
    final a = NativeNegotiation.run(() => first.future);
    final b = NativeNegotiation.run(() => second.future);
    expect(NativeNegotiation.isRunning, isTrue);

    var idle = false;
    unawaited(NativeNegotiation.whenIdle().then((_) => idle = true));
    first.complete(7);
    expect(await a, 7);
    await pumpEventQueue();
    expect(idle, isFalse, reason: 'one call still runs');

    second.completeError(StateError('failed'));
    await expectLater(b, throwsStateError);
    await pumpEventQueue();
    expect(idle, isTrue, reason: 'a failed call counts as done');
    expect(NativeNegotiation.isRunning, isFalse);
  });

  test('a call started under releasingOn stops counting when abandoned, '
      'and its late completion counts nothing twice', () async {
    final hung = Completer<int>();
    final abandoned = Completer<void>();
    final call = NativeNegotiation.releasingOn(
      abandoned.future,
      () => NativeNegotiation.run(() => hung.future),
    );
    final other = Completer<void>();
    final healthy = NativeNegotiation.run(() => other.future);
    expect(NativeNegotiation.isRunning, isTrue);

    abandoned.complete();
    await pumpEventQueue();
    expect(NativeNegotiation.isRunning, isTrue, reason: 'the other call');
    other.complete();
    await healthy;
    await pumpEventQueue();
    expect(NativeNegotiation.isRunning, isFalse);
    await NativeNegotiation.whenIdle();

    // The abandoned call completes late: the count stays right.
    hung.complete(1);
    expect(await call, 1);
    expect(NativeNegotiation.isRunning, isFalse);
    final next = Completer<void>();
    final counted = NativeNegotiation.run(() => next.future);
    expect(NativeNegotiation.isRunning, isTrue);
    next.complete();
    await counted;
    expect(NativeNegotiation.isRunning, isFalse);
  });

  test(
    'a call under releasingOn that completes first is released once',
    () async {
      final abandoned = Completer<void>();
      await NativeNegotiation.releasingOn(
        abandoned.future,
        () => NativeNegotiation.run(() async => 1),
      );
      expect(NativeNegotiation.isRunning, isFalse);
      final other = Completer<void>();
      final running = NativeNegotiation.run(() => other.future);
      abandoned.complete();
      await pumpEventQueue();
      expect(NativeNegotiation.isRunning, isTrue, reason: 'not released twice');
      other.complete();
      await running;
      expect(NativeNegotiation.isRunning, isFalse);
    },
  );
}
