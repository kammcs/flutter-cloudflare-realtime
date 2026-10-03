import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

/// Tuning for the delay between reconnection attempts (design.md §8).
///
/// The delay before attempt `n` (0-based) is drawn uniformly from
/// `[0, min(maxDelay, initialDelay × multiplier^n)]`: exponential backoff
/// with **full jitter**. Full jitter spreads out clients that lost the
/// connection at the same moment (a network blip, an SFU restart), so they
/// don't all come back at once.
///
/// A reconnection episode gives up once [maxAttempts] delays have been
/// handed out, or once [maxElapsed] has passed since the episode's first
/// attempt, whichever comes first. Either limit can be `null` for "no
/// limit"; with both `null` it retries forever.
@immutable
class BackoffOptions {
  /// Creates a backoff configuration.
  const BackoffOptions({
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 10),
    this.multiplier = 2.0,
    this.maxAttempts,
    this.maxElapsed = const Duration(minutes: 2),
  }) : assert(multiplier >= 1.0, 'multiplier must be at least 1'),
       assert(maxAttempts == null || maxAttempts > 0);

  /// The upper bound of the first delay. Default 500 ms.
  final Duration initialDelay;

  /// The cap on the upper bound of any delay. Default 10 s, so a call that
  /// dropped retries at least every 10 s.
  final Duration maxDelay;

  /// How much the upper bound grows per attempt. Default 2.
  final double multiplier;

  /// The most attempts per episode, or `null` for no limit (the default).
  final int? maxAttempts;

  /// How long an episode may last, measured from its first attempt, or
  /// `null` for no limit. Default 2 minutes.
  final Duration? maxElapsed;

  /// Returns a copy with the given fields replaced. (It can't clear
  /// [maxAttempts] or [maxElapsed]; use the constructor for that.)
  BackoffOptions copyWith({
    Duration? initialDelay,
    Duration? maxDelay,
    double? multiplier,
    int? maxAttempts,
    Duration? maxElapsed,
  }) => BackoffOptions(
    initialDelay: initialDelay ?? this.initialDelay,
    maxDelay: maxDelay ?? this.maxDelay,
    multiplier: multiplier ?? this.multiplier,
    maxAttempts: maxAttempts ?? this.maxAttempts,
    maxElapsed: maxElapsed ?? this.maxElapsed,
  );

  @override
  bool operator ==(Object other) =>
      other is BackoffOptions &&
      other.initialDelay == initialDelay &&
      other.maxDelay == maxDelay &&
      other.multiplier == multiplier &&
      other.maxAttempts == maxAttempts &&
      other.maxElapsed == maxElapsed;

  @override
  int get hashCode =>
      Object.hash(initialDelay, maxDelay, multiplier, maxAttempts, maxElapsed);

  @override
  String toString() =>
      'BackoffOptions(initial: $initialDelay, max: $maxDelay, '
      'x$multiplier, maxAttempts: $maxAttempts, maxElapsed: $maxElapsed)';
}

/// The state of one reconnection episode: hands out jittered delays and
/// says when to give up.
///
/// ```dart
/// final backoff = Backoff(config);
/// while (true) {
///   final delay = backoff.nextDelay();
///   if (delay == null) break; // give up
///   await Future<void>.delayed(delay);
///   if (await tryReconnect()) {
///     backoff.reset();
///     break;
///   }
/// }
/// ```
///
/// The random source and the clock are injectable, so tests are
/// deterministic.
///
/// Internal: not exported from the package barrel. The Room's reconnection
/// owns it; apps tune it through [BackoffOptions].
class Backoff {
  /// Creates a backoff with [config].
  ///
  /// [random] defaults to [debugDefaultRandom], else a fresh [math.Random].
  /// [clock] returns monotonic elapsed time; it defaults to a stopwatch
  /// from `package:clock`, started here, so `fake_async` controls it in
  /// tests.
  Backoff(this.config, {math.Random? random, Duration Function()? clock})
    : _random = random ?? debugDefaultRandom?.call() ?? math.Random(),
      _clock = clock ?? _stopwatchClock();

  /// Test hook: creates the random source for backoffs made without one
  /// (such as the Room's reconnection and pull-retry backoffs), so tests
  /// can make the jitter deterministic. Reset it to `null` after the test.
  @visibleForTesting
  static math.Random Function()? debugDefaultRandom;

  static Duration Function() _stopwatchClock() {
    final stopwatch = clock.stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  /// The configuration.
  final BackoffOptions config;

  final math.Random _random;
  final Duration Function() _clock;
  int _attempt = 0;
  Duration? _episodeStart;

  /// How many delays this episode has handed out.
  int get attempt => _attempt;

  /// Whether an episode is in progress (a delay was handed out since the
  /// last [reset]).
  bool get isActive => _episodeStart != null;

  /// The upper bound of the delay for 0-based [attempt], before jitter.
  Duration ceilingFor(int attempt) {
    final initial = config.initialDelay.inMicroseconds.toDouble();
    final cap = config.maxDelay.inMicroseconds.toDouble();
    // For large attempt numbers the power overflows to infinity; use the cap.
    final grown = initial * math.pow(config.multiplier, attempt);
    final bound = grown.isFinite ? math.min(grown, cap) : cap;
    return Duration(microseconds: bound.round());
  }

  /// Returns the delay before the next attempt, or `null` when the episode
  /// is exhausted (by [BackoffOptions.maxAttempts] or
  /// [BackoffOptions.maxElapsed]).
  ///
  /// The first call after construction or [reset] starts the episode clock.
  Duration? nextDelay() {
    final now = _clock();
    final start = _episodeStart ??= now;
    final maxAttempts = config.maxAttempts;
    if (maxAttempts != null && _attempt >= maxAttempts) return null;
    final maxElapsed = config.maxElapsed;
    if (maxElapsed != null && now - start >= maxElapsed) return null;
    final ceiling = ceilingFor(_attempt);
    _attempt++;
    // Full jitter: uniform in [0, ceiling].
    return Duration(
      microseconds: (_random.nextDouble() * ceiling.inMicroseconds).round(),
    );
  }

  /// Ends the episode, after a successful reconnection. The next
  /// [nextDelay] starts a fresh one.
  void reset() {
    _attempt = 0;
    _episodeStart = null;
  }
}
