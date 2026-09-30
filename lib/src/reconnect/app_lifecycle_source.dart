/// @docImport '../room/cloudflare_realtime.dart';
/// @docImport 'reconnect_trigger.dart';
library;

import 'package:flutter/widgets.dart';

/// Tells a room when the app goes to the background and comes back
/// (`docs/design.md` §8).
///
/// Mobile OSes may kill a backgrounded app's sockets while its peer
/// connection still reports `connected`. So coming back after at least
/// [ReconnectTriggerConfig.backgroundThreshold] replaces the session, and
/// coming back at all re-checks the reconnection timers, which may not have
/// run while the app was suspended.
///
/// [FlutterAppLifecycleSource] is the default. Tests and apps with their
/// own lifecycle handling can pass another to [CloudflareRealtime].
abstract interface class AppLifecycleSource {
  /// The app's lifecycle states as they change. Only
  /// [AppLifecycleState.paused] (background) and [AppLifecycleState.resumed]
  /// (foreground) matter; others are ignored.
  ///
  /// Every room listens while it is joined, so this must allow several
  /// listeners over time (a broadcast stream, or a new stream per call).
  Stream<AppLifecycleState> get states;
}

/// The Flutter app's lifecycle, from an [AppLifecycleListener] per
/// listener.
///
/// Without a Flutter binding (a plain Dart test that never called
/// `WidgetsFlutterBinding.ensureInitialized`), the stream emits nothing.
class FlutterAppLifecycleSource implements AppLifecycleSource {
  /// Creates the source.
  const FlutterAppLifecycleSource();

  @override
  Stream<AppLifecycleState> get states => Stream.multi((controller) {
    AppLifecycleListener? listener;
    try {
      listener = AppLifecycleListener(onStateChange: controller.add);
    } catch (_) {
      // No binding: there is no lifecycle to follow.
    }
    controller.onCancel = () => listener?.dispose();
  });
}
