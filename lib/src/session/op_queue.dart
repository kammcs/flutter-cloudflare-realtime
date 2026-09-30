// Ported from partytracks' `Peer.utils.ts` (`FIFOScheduler` and
// `BulkRequestDispatcher`), ISC License, Copyright 2024 Sunil Pai. See
// THIRD_PARTY_NOTICES.md.

import 'dart:async';

/// Runs asynchronous tasks one at a time, in the order they were scheduled.
///
/// A port of partytracks' `FIFOScheduler`. The SFU requires each SDP
/// exchange on a session to finish before the next mutation, so every
/// session operation goes through one of these.
///
/// A task that throws fails only its own future: the queue moves on to the
/// next task.
///
/// Internal: not exported from the package barrel.
class OpQueue {
  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// The number of tasks scheduled and not yet finished, including the one
  /// running.
  int get pending => _pending;

  /// Whether no task is scheduled or running.
  bool get isIdle => _pending == 0;

  /// Schedules [task] to run after every task scheduled before it has
  /// finished, and returns its result.
  Future<T> schedule<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _pending++;
    _tail = _tail.then((_) async {
      try {
        completer.complete(await task());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      } finally {
        _pending--;
      }
    });
    return completer.future;
  }
}

/// Collects items that arrive in the same event-loop turn and hands them to
/// [onBatch] together.
///
/// A port of partytracks' `BulkRequestDispatcher`. The first [add] of a
/// batch starts a zero-duration timer (partytracks uses `setTimeout(0)`), so
/// everything added synchronously or in microtasks before it fires joins the
/// same batch. A batch holds at most [maxBatchSize] items; the next [add]
/// starts a new batch with its own timer.
///
/// Unlike partytracks, which resolves every caller with the whole bulk
/// response, items here carry their own completion (for example a
/// [Completer]), and [onBatch] settles each one.
///
/// Internal: not exported from the package barrel.
class BatchDispatcher<T> {
  /// Creates a dispatcher that calls [onBatch] with each batch.
  BatchDispatcher(this.onBatch, {this.maxBatchSize = defaultMaxBatchSize})
    : assert(maxBatchSize > 0);

  /// partytracks' batch size for push, pull and close.
  static const defaultMaxBatchSize = 32;

  /// Called once per batch, from a timer, with the items in the order they
  /// were added.
  final void Function(List<T> batch) onBatch;

  /// The largest batch [onBatch] receives.
  final int maxBatchSize;

  List<T>? _current;

  /// Adds [item] to the current batch, starting a new batch if there is none
  /// or the current one is full.
  void add(T item) {
    var batch = _current;
    if (batch == null || batch.length >= maxBatchSize) {
      final fresh = batch = <T>[];
      _current = fresh;
      Timer.run(() {
        if (identical(_current, fresh)) _current = null;
        onBatch(fresh);
      });
    }
    batch.add(item);
  }
}
