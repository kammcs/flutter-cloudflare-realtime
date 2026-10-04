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
}
