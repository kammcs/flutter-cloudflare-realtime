import 'dart:async';

import 'package:cloudflare_realtime/src/util/coalescing_runner.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('runs are serialized and extra requests coalesce into one', () async {
    var runs = 0;
    var active = 0;
    final gates = <Completer<void>>[];
    final runner = CoalescingRunner(() async {
      runs++;
      active++;
      expect(active, 1);
      final gate = Completer<void>();
      gates.add(gate);
      await gate.future;
      active--;
    });

    final first = runner.run();
    expect(runner.isRunning, isTrue);
    final second = runner.run();
    final third = runner.run();
    expect(identical(first, second), isTrue);
    await pumpEventQueue();
    expect(runs, 1);

    gates[0].complete();
    await pumpEventQueue();
    expect(runs, 2); // One extra pass for both queued requests.
    gates[1].complete();
    await Future.wait([first, second, third]);
    expect(runs, 2);
    expect(runner.isRunning, isFalse);

    unawaited(runner.run());
    await pumpEventQueue();
    expect(runs, 3);
    gates[2].complete();
  });

  test('an error goes to the zone and the future still completes', () async {
    final errors = <Object>[];
    final done = Completer<void>();
    runZonedGuarded(() async {
      final runner = CoalescingRunner(() async => throw StateError('bug'));
      await runner.run();
      expect(runner.isRunning, isFalse);
      done.complete();
    }, (error, _) => errors.add(error));
    await done.future;
    expect(errors.single, isA<StateError>());
  });
}
