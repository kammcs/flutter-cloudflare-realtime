// The platform's screen-awake backend: the plugin on phones, `dart:ffi` on
// Windows and macOS, the Screen Wake Lock API in browsers. `dart:ffi` and
// `dart:io` aren't on the web, so browsers get their own file.
export 'screen_awake_platform_io.dart'
    if (dart.library.js_interop) 'screen_awake_platform_web.dart';
