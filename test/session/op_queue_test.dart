import 'dart:async';

import 'package:cloudflare_realtime/src/session/op_queue.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('OpQueue', () {
    test('runs tasks one at a time, in order', () async {
      final queue = OpQueue();
      final events = <String>[];
      final gate = Completer<void>();

      final first = queue.schedule(() async {
        events.add('first start');
        await gate.future;
        events.add('first end');
        return 1;
      });
      final second = queue.schedule(() async {
        events.add('second');
        return 2;
      });

      await pumpEventQueue();
      expect(events, ['first start']);
      expect(queue.pending, 2);

      gate.complete();
      expect(await first, 1);
      expect(await second, 2);
      expect(events, ['first start', 'first end', 'second']);
      expect(queue.isIdle, isTrue);
    });

    test('a failing task fails only its own future', () async {
      final queue = OpQueue();
      final failing = queue.schedule<void>(() async => throw StateError('x'));
      final next = queue.schedule(() async => 'ok');

      await expectLater(failing, throwsStateError);
      expect(await next, 'ok');
    });

    test('a synchronously throwing task does not wedge the queue', () async {
      final queue = OpQueue();
      final failing = expectLater(
        queue.schedule<void>(() => throw ArgumentError('x')),
        throwsArgumentError,
      );
      expect(await queue.schedule(() async => 3), 3);
      await failing;
    });
  });

  group('BatchDispatcher', () {
    test('batches items added in the same turn', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final dispatcher = BatchDispatcher<int>(batches.add);

        dispatcher
          ..add(1)
          ..add(2);
        scheduleMicrotask(() => dispatcher.add(3));
        async.flushMicrotasks();
        expect(batches, isEmpty);

        async.elapse(Duration.zero);
        expect(batches, [
          [1, 2, 3],
        ]);

        dispatcher.add(4);
        async.elapse(Duration.zero);
        expect(batches, [
          [1, 2, 3],
          [4],
        ]);
      });
    });

    test('starts a new batch once the current one is full', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final dispatcher = BatchDispatcher<int>(batches.add, maxBatchSize: 2);
        for (var i = 0; i < 5; i++) {
          dispatcher.add(i);
        }
        async.elapse(Duration.zero);
        expect(batches, [
          [0, 1],
          [2, 3],
          [4],
        ]);
      });
    });

    test('defaults to partytracks\' batch size of 32', () {
      fakeAsync((async) {
        final batches = <List<int>>[];
        final dispatcher = BatchDispatcher<int>(batches.add);
        for (var i = 0; i < 33; i++) {
          dispatcher.add(i);
        }
        async.elapse(Duration.zero);
        expect(batches.map((b) => b.length), [32, 1]);
      });
    });
  });
}
