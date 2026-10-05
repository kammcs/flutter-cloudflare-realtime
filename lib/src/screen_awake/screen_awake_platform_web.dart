import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../diagnostics/log.dart';
import 'screen_awake_backend.dart';

/// The backend for browsers: the Screen Wake Lock API.
ScreenAwakeBackend createPlatformScreenAwakeBackend() =>
    WebScreenAwakeBackend();

/// The Screen Wake Lock API (`navigator.wakeLock.request('screen')`).
///
/// The browser releases the lock whenever the tab is hidden, and refuses
/// one for a hidden tab, so while it is wanted the lock is taken again on
/// `visibilitychange` when the tab is visible. Browsers without the API
/// (or a page where a permissions policy forbids it) are not [supported],
/// or answer `false`.
class WebScreenAwakeBackend implements ScreenAwakeBackend {
  /// Creates the backend.
  WebScreenAwakeBackend();

  final StreamController<bool> _changes = StreamController.broadcast();
  web.WakeLockSentinel? _sentinel;
  // Counts the locks taken, so a release event is matched to its lock
  // without comparing JS objects.
  int _generation = 0;
  bool _wanted = false;
  Future<void>? _requesting;
  JSFunction? _onVisibility;

  @override
  late final bool supported = _hasApi();

  static bool _hasApi() {
    try {
      return (web.window.navigator as JSObject).has('wakeLock');
    } catch (_) {
      return false;
    }
  }

  @override
  Stream<bool> get changes => _changes.stream;

  @override
  Future<bool> setKeepAwake(bool on) async {
    if (!supported) return false;
    _wanted = on;
    if (on) {
      if (_onVisibility == null) {
        final listener = ((web.Event _) => _onVisibilityChange()).toJS;
        _onVisibility = listener;
        web.document.addEventListener('visibilitychange', listener);
      }
      await _request();
      return _sentinel != null;
    }
    if (_onVisibility case final listener?) {
      web.document.removeEventListener('visibilitychange', listener);
      _onVisibility = null;
    }
    final sentinel = _sentinel;
    _sentinel = null;
    _generation++;
    if (sentinel != null) await _releaseQuietly(sentinel);
    return false;
  }

  void _onVisibilityChange() {
    if (!_wanted || _sentinel != null) return;
    if (web.document.visibilityState != 'visible') return;
    unawaited(
      _request().then((_) {
        if (_sentinel != null && !_changes.isClosed) _changes.add(true);
      }),
    );
  }

  Future<void> _request() => _requesting ??= _doRequest().whenComplete(() {
    _requesting = null;
  });

  Future<void> _doRequest() async {
    if (!_wanted || _sentinel != null) return;
    // A hidden tab is refused; visibilitychange tries again.
    if (web.document.visibilityState != 'visible') return;
    final web.WakeLockSentinel sentinel;
    try {
      sentinel = await web.window.navigator.wakeLock.request('screen').toDart;
    } catch (error) {
      RealtimeLog.warning('screen wake lock refused', error: error);
      return;
    }
    if (!_wanted) {
      await _releaseQuietly(sentinel);
      return;
    }
    _sentinel = sentinel;
    final generation = ++_generation;
    sentinel.onrelease = ((web.Event _) {
      // Released by the browser (the tab was hidden), not by us.
      if (_sentinel == null || generation != _generation) return;
      _sentinel = null;
      if (!_changes.isClosed) _changes.add(false);
    }).toJS;
  }

  static Future<void> _releaseQuietly(web.WakeLockSentinel sentinel) async {
    try {
      await sentinel.release().toDart;
    } catch (_) {
      // Already released.
    }
  }
}
