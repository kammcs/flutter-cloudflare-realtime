import 'dart:async';

/// Runs an async action so that runs never overlap, and requests that arrive
/// during a run are coalesced into one more run after it.
///
/// This is the "reconcile" pattern: the action compares desired state with
/// actual state and fixes the difference, so it doesn't matter how many
/// requests arrived, only that one more pass happens after the last of them.
///
/// ```dart
/// final runner = CoalescingRunner(_reconcile);
/// runner.run(); // starts a pass
/// runner.run(); // queued: one more pass after the current one
/// runner.run(); // coalesced into that same extra pass
/// ```
///
/// The action should handle its own errors. If it throws anyway, the error
/// goes to the current zone's uncaught-error handler and the returned future
/// still completes normally, so fire-and-forget callers never leak errors.
///
/// Internal: not exported from the package barrel.
class CoalescingRunner {
  /// Creates a runner for [action].
  CoalescingRunner(this._action);

  final Future<void> Function() _action;
  Future<void>? _running;
  bool _again = false;

  /// Whether a pass is in progress.
  bool get isRunning => _running != null;

  /// Requests a pass.
  ///
  /// If none is running, one starts now. Otherwise one more pass is queued
  /// after the current one. The returned future completes when no pass is
  /// pending any more, which includes the pass this call requested.
  Future<void> run() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    final completer = Completer<void>();
    _running = completer.future;
    _loop(completer);
    return completer.future;
  }

  Future<void> _loop(Completer<void> completer) async {
    do {
      _again = false;
      try {
        await _action();
      } catch (error, stackTrace) {
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    } while (_again);
    _running = null;
    completer.complete();
  }
}
