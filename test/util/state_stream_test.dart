import 'dart:async';

import 'package:cloudflare_realtime/src/util/state_stream.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StateStream', () {
    test('exposes the initial value', () {
      final state = StateStream<int>(1);
      expect(state.value, 1);
      expect(state.isClosed, isFalse);
      expect(state.hasListener, isFalse);
    });

    test('stream is a broadcast stream', () {
      expect(StateStream<int>(0).stream.isBroadcast, isTrue);
    });

    test('replays the current value to a new listener', () async {
      final state = StateStream<int>(1)..set(2);
      final events = <int>[];
      state.stream.listen(events.add);
      await pumpEventQueue();
      expect(events, [2]);
    });

    test('emits later changes in order after the replayed value', () async {
      final state = StateStream<int>(0);
      final events = <int>[];
      state.stream.listen(events.add);
      state
        ..set(1)
        ..set(2)
        ..set(3);
      await pumpEventQueue();
      expect(events, [0, 1, 2, 3]);
    });

    test('updates value synchronously but delivers asynchronously', () async {
      final state = StateStream<int>(0);
      final events = <int>[];
      state.stream.listen(events.add);
      await pumpEventQueue();
      events.clear();

      state.set(5);
      expect(state.value, 5);
      expect(events, isEmpty);
      await pumpEventQueue();
      expect(events, [5]);
    });

    test('each listener gets the value current when it subscribed', () async {
      final state = StateStream<String>('a');
      final first = <String>[];
      final second = <String>[];
      state.stream.listen(first.add);
      state.set('b');
      state.stream.listen(second.add);
      state.set('c');
      await pumpEventQueue();
      expect(first, ['a', 'b', 'c']);
      expect(second, ['b', 'c']);
    });

    test('a listener that cancels stops receiving values', () async {
      final state = StateStream<int>(0);
      final events = <int>[];
      final sub = state.stream.listen(events.add);
      await pumpEventQueue();
      expect(state.hasListener, isTrue);
      await sub.cancel();
      expect(state.hasListener, isFalse);
      state.set(1);
      await pumpEventQueue();
      expect(events, [0]);
    });

    test('a paused listener receives buffered values on resume', () async {
      final state = StateStream<int>(0);
      final events = <int>[];
      final sub = state.stream.listen(events.add);
      await pumpEventQueue();
      sub.pause();
      state
        ..set(1)
        ..set(2);
      await pumpEventQueue();
      expect(events, [0]);
      sub.resume();
      await pumpEventQueue();
      expect(events, [0, 1, 2]);
    });

    test('update transforms the current value', () async {
      final state = StateStream<List<int>>(const []);
      state
        ..update((xs) => [...xs, 1])
        ..update((xs) => [...xs, 2]);
      expect(state.value, [1, 2]);
      expect(await state.stream.first, [1, 2]);
    });

    test('non-distinct mode emits repeated values', () async {
      final state = StateStream<int>(0);
      final events = <int>[];
      state.stream.listen(events.add);
      state
        ..set(0)
        ..set(0);
      await pumpEventQueue();
      expect(events, [0, 0, 0]);
    });

    test('distinct mode skips values equal to the current one', () async {
      final state = StateStream<int>(0, distinct: true);
      final events = <int>[];
      state.stream.listen(events.add);
      state
        ..set(0)
        ..set(1)
        ..set(1)
        ..set(0);
      await pumpEventQueue();
      expect(events, [0, 1, 0]);
    });

    test('custom equals implies distinct mode', () async {
      final state = StateStream<List<int>>([
        1,
      ], equals: (a, b) => a.length == b.length);
      final events = <List<int>>[];
      state.stream.listen(events.add);
      final original = state.value;
      state.set([2]); // same length: skipped, value unchanged
      expect(state.value, same(original));
      state.set([1, 2]);
      await pumpEventQueue();
      expect(events, [
        [1],
        [1, 2],
      ]);
    });

    test('close completes current listeners after pending values', () async {
      final state = StateStream<int>(0);
      final events = <int>[];
      final done = Completer<void>();
      state.stream.listen(events.add, onDone: done.complete);
      state.set(1);
      await state.close();
      await done.future;
      expect(events, [0, 1]);
      expect(state.isClosed, isTrue);
      expect(state.value, 1);
    });

    test('a listener after close gets the last value, then done', () async {
      final state = StateStream<int>(0)..set(7);
      await state.close();
      expect(await state.stream.toList(), [7]);
    });

    test('set and update throw after close', () async {
      final state = StateStream<int>(0);
      await state.close();
      expect(() => state.set(1), throwsStateError);
      var called = false;
      expect(
        () => state.update((v) {
          called = true;
          return v + 1;
        }),
        throwsStateError,
      );
      expect(called, isFalse);
      expect(state.value, 0);
    });

    test('close is idempotent', () async {
      final state = StateStream<int>(0);
      await state.close();
      await state.close();
      expect(state.isClosed, isTrue);
    });

    test(
      'set from inside a listener is delivered after the current value',
      () async {
        final state = StateStream<int>(0);
        final events = <int>[];
        state.stream.listen((v) {
          events.add(v);
          if (v == 1) state.set(2);
        });
        state.set(1);
        await pumpEventQueue();
        expect(events, [0, 1, 2]);
        expect(state.value, 2);
      },
    );
  });
}
