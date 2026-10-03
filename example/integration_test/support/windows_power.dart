// Windows' power requests, read with dart:ffi (docs/design.md §4.7,
// Keeping the screen on). `null` elsewhere.
export 'windows_power_stub.dart' if (dart.library.ffi) 'windows_power_ffi.dart';
