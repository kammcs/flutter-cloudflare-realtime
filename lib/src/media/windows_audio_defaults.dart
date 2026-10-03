/// Reads Windows' default audio devices (internal).
///
/// `flutter_webrtc` doesn't say which audio device is the system default on
/// Windows, so the media backend asks Core Audio itself, through `dart:ffi`
/// (no plugin, no package dependency). Browsers get a stub.
library;

export 'windows_audio_defaults_stub.dart'
    if (dart.library.ffi) 'windows_audio_defaults_ffi.dart';
