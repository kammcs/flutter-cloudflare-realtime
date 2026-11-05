// Reading the platform: dart:io on native platforms, a fixed answer in
// browsers, which have no dart:io.
export 'platform_info_io.dart'
    if (dart.library.js_interop) 'platform_info_web.dart';
