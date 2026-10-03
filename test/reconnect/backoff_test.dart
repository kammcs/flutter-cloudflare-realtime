import 'dart:math' as math;

import 'package:cloudflare_realtime/src/reconnect/backoff.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns the given values from [nextDouble], in a loop.
class _ScriptedRandom implements math.Random {
  _ScriptedRandom(this.values);

  final List<double> values;
  int _i = 0;

  @override
  double nextDouble() => values[_i++ % values.length];

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

void main() {
  const ms = Duration(milliseconds: 1);

  test('defaults', () {
    const config = BackoffOptions();
    expect(config.initialDelay, ms * 500);
    expect(config.maxDelay, const Duration(seconds: 10));
    expect(config.multiplier, 2.0);
    expect(config.maxAttempts, isNull);
    expect(config.maxElapsed, const Duration(minutes: 2));
  });

  test('the ceiling grows exponentially up to the cap', () {
    final backoff = Backoff(
      const BackoffOptions(initialDelay: Duration(milliseconds: 100)),
    );
    expect(
      [for (var i = 0; i < 9; i++) backoff.ceilingFor(i).inMilliseconds],
      [100, 200, 400, 800, 1600, 3200, 6400, 10000, 10000],
    );
  });

  test('a huge attempt number is capped, not overflowed', () {
    final backoff = Backoff(const BackoffOptions());
    expect(backoff.ceilingFor(100000), const Duration(seconds: 10));
  });

  test('full jitter scales the ceiling by the random draw', () {
    final backoff = Backoff(
      const BackoffOptions(initialDelay: Duration(milliseconds: 100)),
      random: _ScriptedRandom([0.0, 0.5, 1.0, 0.25]),
      clock: () => Duration.zero,
    );
    expect(backoff.nextDelay(), Duration.zero); // 0.0 × 100
    expect(backoff.nextDelay(), ms * 100); // 0.5 × 200
    expect(backoff.nextDelay(), ms * 400); // 1.0 × 400
    expect(backoff.nextDelay(), ms * 200); // 0.25 × 800
    expect(backoff.attempt, 4);
  });

  test('real random delays stay within [0, ceiling]', () {
    final backoff = Backoff(
      const BackoffOptions(maxElapsed: null),
      random: math.Random(42),
      clock: () => Duration.zero,
    );
    for (var i = 0; i < 200; i++) {
      final ceiling = backoff.ceilingFor(backoff.attempt);
      final delay = backoff.nextDelay()!;
      expect(delay, greaterThanOrEqualTo(Duration.zero));
      expect(delay, lessThanOrEqualTo(ceiling));
    }
  });

  test('gives up after maxAttempts', () {
    final backoff = Backoff(
      const BackoffOptions(maxAttempts: 3, maxElapsed: null),
      random: _ScriptedRandom([0.5]),
      clock: () => Duration.zero,
    );
    expect(backoff.nextDelay(), isNotNull);
    expect(backoff.nextDelay(), isNotNull);
    expect(backoff.nextDelay(), isNotNull);
    expect(backoff.nextDelay(), isNull);
    expect(backoff.nextDelay(), isNull);
  });

  test('gives up after maxElapsed, measured from the first attempt', () {
    var now = const Duration(seconds: 100);
    final backoff = Backoff(
      const BackoffOptions(maxElapsed: Duration(seconds: 30)),
      random: _ScriptedRandom([0.5]),
      clock: () => now,
    );
    expect(backoff.isActive, isFalse);
    expect(backoff.nextDelay(), isNotNull); // Episode starts at 100 s.
    expect(backoff.isActive, isTrue);
    now = const Duration(seconds: 129);
    expect(backoff.nextDelay(), isNotNull);
    now = const Duration(seconds: 130);
    expect(backoff.nextDelay(), isNull);
  });

  test('no limits retries forever', () {
    final backoff = Backoff(
      const BackoffOptions(maxElapsed: null),
      random: _ScriptedRandom([1.0]),
      clock: () => const Duration(days: 365),
    );
    for (var i = 0; i < 1000; i++) {
      expect(backoff.nextDelay(), isNotNull);
    }
    expect(backoff.nextDelay(), const Duration(seconds: 10));
  });

  test('reset starts a fresh episode', () {
    var now = Duration.zero;
    final backoff = Backoff(
      const BackoffOptions(
        initialDelay: Duration(milliseconds: 100),
        maxAttempts: 2,
        maxElapsed: Duration(seconds: 10),
      ),
      random: _ScriptedRandom([1.0]),
      clock: () => now,
    );
    expect(backoff.nextDelay(), ms * 100);
    expect(backoff.nextDelay(), ms * 200);
    expect(backoff.nextDelay(), isNull);

    backoff.reset();
    expect(backoff.attempt, 0);
    expect(backoff.isActive, isFalse);
    now = const Duration(minutes: 5); // Long after the old episode's limit.
    expect(backoff.nextDelay(), ms * 100);
    expect(backoff.attempt, 1);
  });

  test('config equality and copyWith', () {
    const a = BackoffOptions();
    expect(a, const BackoffOptions());
    expect(a.hashCode, const BackoffOptions().hashCode);
    final b = a.copyWith(maxAttempts: 5, multiplier: 3);
    expect(b.maxAttempts, 5);
    expect(b.multiplier, 3);
    expect(b.initialDelay, a.initialDelay);
    expect(b, isNot(a));
  });
}
