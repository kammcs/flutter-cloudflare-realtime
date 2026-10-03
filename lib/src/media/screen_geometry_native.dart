/// The operating system's view of displays and windows (internal).
///
/// `dart:ffi` on macOS (Core Graphics) and Windows (user32, shcore,
/// dwmapi), without a plugin or a package dependency; nothing elsewhere.
/// Browsers get a stub.
library;

export 'screen_geometry_native_stub.dart'
    if (dart.library.ffi) 'screen_geometry_ffi.dart';
