import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../audio/platform.dart';
import 'camera_pause.dart';

/// The platform side of keeping a call alive outside the foreground
/// (`docs/design.md` §4.7): Android's foreground service, and iOS's report
/// of a camera paused by the system. It decides nothing; `CallBackground`
/// does.
///
/// Internal.
abstract interface class CallBackgroundBackend {
  /// Whether this platform needs a foreground service for a call (Android).
  bool get runsForegroundService;

  /// Whether this platform reports a camera paused by the system (iOS).
  bool get reportsCameraPause;

  /// Starts the foreground service, or changes its types when it runs:
  /// `microphone` with [microphone], `camera` with [camera]. Completes with
  /// whether it runs (`false` when the app holds neither permission).
  Future<bool> startService({required bool microphone, required bool camera});

  /// Stops the foreground service.
  Future<void> stopService();

  /// The camera being paused by the system and resumed.
  Stream<CameraPauseSignal> get cameraPauses;
}

/// The system pausing the camera ([reason]) or letting it run again
/// (`reason == null`).
@immutable
class CameraPauseSignal {
  /// Creates the signal.
  const CameraPauseSignal(this.reason);

  /// Why the camera is paused, or `null` when it runs again.
  final CameraPauseReason? reason;

  @override
  bool operator ==(Object other) =>
      other is CameraPauseSignal && other.reason == reason;

  @override
  int get hashCode => reason.hashCode;

  @override
  String toString() => 'CameraPauseSignal(${reason?.name ?? 'resumed'})';
}

/// A [CameraPauseSignal] from the native code's event map
/// (`{event: cameraPaused, reason}` or `{event: cameraResumed}`), or `null`
/// for anything else.
@visibleForTesting
CameraPauseSignal? cameraPauseFromMap(Map<Object?, Object?> map) =>
    switch (map['event']) {
      'cameraPaused' => CameraPauseSignal(
        CameraPauseReason.values.asNameMap()[map['reason']] ??
            CameraPauseReason.other,
      ),
      'cameraResumed' => const CameraPauseSignal(null),
      _ => null,
    };

/// Creates a [CallBackgroundBackend]; the platform's by default.
typedef CallBackgroundBackendFactory = CallBackgroundBackend Function();

/// **Tests only:** replaces the platform backend. Reset it to `null`
/// afterwards, with `CallBackground.debugReset`.
@visibleForTesting
CallBackgroundBackendFactory? debugCallBackgroundBackendFactory;

/// Creates the backend for this platform (or
/// [debugCallBackgroundBackendFactory]'s).
CallBackgroundBackend createCallBackgroundBackend() =>
    (debugCallBackgroundBackendFactory ?? _platformBackend)();

CallBackgroundBackend _platformBackend() => isPhone
    ? MethodChannelCallBackgroundBackend()
    : const UnsupportedCallBackgroundBackend();

/// Desktops and browsers: a call keeps running in the background without
/// help, and nothing is reported.
class UnsupportedCallBackgroundBackend implements CallBackgroundBackend {
  /// Creates the backend.
  const UnsupportedCallBackgroundBackend();

  @override
  bool get runsForegroundService => false;

  @override
  bool get reportsCameraPause => false;

  @override
  Future<bool> startService({
    required bool microphone,
    required bool camera,
  }) async => false;

  @override
  Future<void> stopService() async {}

  @override
  Stream<CameraPauseSignal> get cameraPauses => const Stream.empty();
}

/// The phones' backend: this package's native code on Android and iOS.
class MethodChannelCallBackgroundBackend implements CallBackgroundBackend {
  /// Creates the backend.
  MethodChannelCallBackgroundBackend();

  static const _methods = MethodChannel(
    'dev.kammcs.cloudflare_realtime/call_background',
  );
  static const _events = EventChannel(
    'dev.kammcs.cloudflare_realtime/call_background_events',
  );

  @override
  bool get runsForegroundService => isAndroid;

  @override
  bool get reportsCameraPause => isIOS;

  @override
  Future<bool> startService({
    required bool microphone,
    required bool camera,
  }) async =>
      await _methods.invokeMethod<bool>('startService', {
        'microphone': microphone,
        'camera': camera,
      }) ??
      false;

  @override
  Future<void> stopService() => _methods.invokeMethod<void>('stopService');

  @override
  late final Stream<CameraPauseSignal> cameraPauses = _events
      .receiveBroadcastStream()
      .map((event) => event is Map ? cameraPauseFromMap(event) : null)
      .where((signal) => signal != null)
      .cast<CameraPauseSignal>()
      .asBroadcastStream();
}
