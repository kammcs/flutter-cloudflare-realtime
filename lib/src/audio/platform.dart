// The real OS, for call audio routing. Not `defaultTargetPlatform`, which
// is Android in widget tests on any host. `dart:io` isn't on the web, so
// the web gets constants.
export 'platform_io.dart' if (dart.library.js_interop) 'platform_web.dart';
