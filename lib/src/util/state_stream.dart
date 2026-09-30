import 'dart:async';

/// Compares two values for [StateStream]'s distinct mode.
typedef StateEquals<T> = bool Function(T previous, T next);

/// A value that changes over time, observable as a [Stream] that replays the
/// current value to every new listener.
///
/// This is the package's small, dependency-free stand-in for rxdart's
/// `BehaviorSubject`. partytracks relies on that "replay latest" behaviour
/// (for example for device lists and connection state), and the public API
/// here exposes plain `Stream`s, so internals keep their state in a
/// [StateStream] and hand out [stream].
///
/// Semantics:
///
/// - [value] is always readable, synchronously, even after [close].
/// - [stream] is a broadcast stream. Each new listener first receives the
///   value current at the moment it subscribes, then every later change.
/// - Events are never delivered synchronously from inside [set] or [update]:
///   they arrive in a later microtask, in order. [value] is updated
///   immediately, so code after `set(x)` already sees `x`.
/// - With `distinct: true`, [set] ignores a value equal to the current one
///   (by `==`, or by the `equals` function when given), so listeners see no
///   repeats.
/// - [close] completes [stream] for current listeners. A listener that
///   subscribes after [close] receives the last value, then done. Calling
///   [set] or [update] after [close] throws a [StateError].
///
/// Internal: not exported from the package barrel.
class StateStream<T> {
  /// Creates a state holder that starts at [initial].
  ///
  /// When [distinct] is true, [set] skips values equal to the current one.
  /// [equals] replaces `==` for that comparison; passing it implies
  /// [distinct].
  StateStream(T initial, {bool distinct = false, StateEquals<T>? equals})
    : _value = initial,
      _equals = equals ?? (distinct ? _defaultEquals : null);

  static bool _defaultEquals(Object? a, Object? b) => a == b;

  // Sync, so a change reaches each per-listener controller immediately; those
  // controllers buffer and deliver asynchronously, which keeps order and
  // avoids re-entrancy into the caller of [set].
  final StreamController<T> _changes = StreamController<T>.broadcast(
    sync: true,
  );
  final StateEquals<T>? _equals;
  T _value;

  /// The current value.
  T get value => _value;

  /// Whether [close] has been called.
  bool get isClosed => _changes.isClosed;

  /// Whether [stream] currently has at least one listener.
  bool get hasListener => _changes.hasListener;

  /// A broadcast stream of values that replays [value] to each new listener.
  ///
  /// Each access returns a new stream object; all of them observe the same
  /// state.
  Stream<T> get stream => Stream<T>.multi((listener) {
    listener.add(_value);
    final subscription = _changes.stream.listen(
      listener.add,
      onError: listener.addError,
      onDone: listener.close,
    );
    // A paused listener's controller buffers events itself.
    listener.onCancel = subscription.cancel;
  }, isBroadcast: true);

  /// Replaces the current value and notifies listeners.
  ///
  /// In distinct mode, does nothing if [next] equals the current value.
  /// Throws a [StateError] if this has been closed.
  void set(T next) {
    if (isClosed) {
      throw StateError('Cannot set the value of a closed StateStream.');
    }
    final equals = _equals;
    if (equals != null && equals(_value, next)) return;
    _value = next;
    _changes.add(next);
  }

  /// Sets the value to `transform(value)`.
  ///
  /// Throws a [StateError] if this has been closed.
  void update(T Function(T current) transform) {
    if (isClosed) {
      throw StateError('Cannot update the value of a closed StateStream.');
    }
    set(transform(_value));
  }

  /// Stops emitting and completes [stream] for all listeners.
  ///
  /// [value] stays readable. Calling [close] again has no effect.
  Future<void> close() => _changes.close();
}
