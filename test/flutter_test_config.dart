import 'dart:async';

import 'package:cloudflare_realtime/src/screen_awake/screen_awake_backend.dart';

/// Runs before every test file.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  // Rooms keep the screen on while video is live (docs/design.md §4.7).
  // Tests never touch the host's screen (dart:ffi on Windows and macOS):
  // `test/screen_awake/` installs a fake.
  debugScreenAwakeBackendFactory = () => const UnsupportedScreenAwakeBackend();
  await testMain();
}
