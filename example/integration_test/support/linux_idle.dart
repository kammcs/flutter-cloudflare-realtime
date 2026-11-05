// gnome-session's inhibited actions on Linux (docs/design.md §4.7, Keeping
// the screen on). `null` elsewhere.
export 'linux_idle_stub.dart' if (dart.library.io) 'linux_idle_io.dart';
