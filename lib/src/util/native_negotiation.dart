import 'dart:async';

/// Tracks the native SDP calls (`createOffer`, `createAnswer`,
/// `setLocalDescription`, `setRemoteDescription`) running in this process,
/// so calls that would block the platform thread behind them can wait.
///
/// `flutter_webrtc`'s native plugins answer most method calls on the
/// platform thread, and libwebrtc's proxies make those calls wait for its
/// signaling and worker threads. Applying a description can hold the
/// worker thread for seconds: the first audio send starts the audio device
/// module, which on macOS builds Apple's voice-processing unit (14–15 s
/// measured on a Mac with a virtual default input, docs/design.md §4.2).
/// A `getStats()` or `Helper.selectAudioInput` sent meanwhile blocks the
/// platform thread, which on macOS (and iOS) is also the Dart UI thread,
/// until the description is applied: the app freezes. The description
/// calls themselves complete asynchronously and don't block it.
/// Reported upstream as flutter-webrtc issue #2217.
///
/// The audio device module is one per process, so this is process-wide.
///
/// A call can hang for good on a stuck platform. `SfuSession` bounds each
/// step (`NegotiationGuard`, docs/design.md §4.2, Bounded negotiation
/// steps) and runs it under [releasingOn]: a call it gave up on stops
/// counting as running then, so [whenIdle] (and `getStats()`, and the
/// macOS microphone selection behind it) never waits forever on it.
///
/// Internal: not exported from the package barrel.
abstract final class NativeNegotiation {
  static int _running = 0;
  static Completer<void>? _idle;
  static const Symbol _abandonKey = #cloudflareRealtimeNativeNegotiationAbandon;

  /// Whether a native SDP call is running.
  static bool get isRunning => _running > 0;

  /// Runs [call], a native SDP call, and counts it as running until it
  /// completes.
  ///
  /// Inside [releasingOn], it also stops counting once that call's
  /// `abandoned` future completes, whichever comes first.
  static Future<T> run<T>(Future<T> Function() call) async {
    _running++;
    var released = false;
    void release() {
      if (released) return;
      released = true;
      _running--;
      if (_running == 0) {
        final idle = _idle;
        _idle = null;
        idle?.complete();
      }
    }

    final abandoned = Zone.current[_abandonKey];
    if (abandoned is Future<void>) unawaited(abandoned.then((_) => release()));
    try {
      return await call();
    } finally {
      release();
    }
  }

  /// Runs [body]. The native SDP calls it starts ([run]) stop counting as
  /// running once [abandoned] completes, even if they never complete: the
  /// caller gave up on them (a timeout).
  static R releasingOn<R>(Future<void> abandoned, R Function() body) =>
      runZoned(body, zoneValues: {_abandonKey: abandoned});

  /// Completes once no native SDP call is running: at once if none is.
  static Future<void> whenIdle() {
    if (_running == 0) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }
}
