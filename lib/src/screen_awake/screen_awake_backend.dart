import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'screen_awake_platform.dart';

/// The platform side of keeping the screen on during a call
/// (`docs/design.md` §4.7, Keeping the screen on). It decides nothing;
/// `ScreenAwake` does.
///
/// - **Android:** `FLAG_KEEP_SCREEN_ON` on the activity's window (this
///   package's plugin; no permission).
/// - **iOS:** `UIApplication.isIdleTimerDisabled`, the previous value
///   restored on release (this package's plugin).
/// - **macOS:** an `IOPMAssertion` of type `PreventUserIdleDisplaySleep`
///   (`dart:ffi`, IOKit).
/// - **Windows:** `SetThreadExecutionState` with `ES_DISPLAY_REQUIRED`
///   (`dart:ffi`, kernel32), on the root isolate's thread.
/// - **Web:** the Screen Wake Lock API, taken again when the tab becomes
///   visible (the browser releases it when the tab is hidden).
/// - **Linux:** not supported.
///
/// Internal.
abstract interface class ScreenAwakeBackend {
  /// Whether this platform can keep the screen on.
  bool get supported;

  /// Keeps the screen on ([on]) or lets it sleep again. Completes with
  /// whether the screen is kept on now.
  Future<bool> setKeepAwake(bool on);

  /// The platform giving the hold up by itself (`false`) or taking it again
  /// (`true`), while it is wanted: the web's wake lock, released when the
  /// tab is hidden. Empty elsewhere.
  Stream<bool> get changes;
}

/// Creates a [ScreenAwakeBackend]; the platform's by default.
typedef ScreenAwakeBackendFactory = ScreenAwakeBackend Function();

/// **Tests only:** replaces the platform backend. Reset it to `null`
/// afterwards, with `ScreenAwake.debugReset`.
@visibleForTesting
ScreenAwakeBackendFactory? debugScreenAwakeBackendFactory;

/// Creates the backend for this platform (or
/// [debugScreenAwakeBackendFactory]'s).
ScreenAwakeBackend createScreenAwakeBackend() =>
    (debugScreenAwakeBackendFactory ?? createPlatformScreenAwakeBackend)();

/// Platforms that can't keep the screen on (Linux): does nothing.
class UnsupportedScreenAwakeBackend implements ScreenAwakeBackend {
  /// Creates the backend.
  const UnsupportedScreenAwakeBackend();

  @override
  bool get supported => false;

  @override
  Future<bool> setKeepAwake(bool on) async => false;

  @override
  Stream<bool> get changes => const Stream.empty();
}

/// The phones' backend: this package's native code on Android and iOS, on
/// the call audio channel (next to the proximity sensor).
class MethodChannelScreenAwakeBackend implements ScreenAwakeBackend {
  /// Creates the backend.
  const MethodChannelScreenAwakeBackend();

  static const _methods = MethodChannel(
    'dev.kammcs.cloudflare_realtime/call_audio',
  );

  @override
  bool get supported => true;

  @override
  Future<bool> setKeepAwake(bool on) async =>
      await _methods.invokeMethod<bool>('keepScreenOn', {'enabled': on}) ??
      false;

  @override
  Stream<bool> get changes => const Stream.empty();
}
