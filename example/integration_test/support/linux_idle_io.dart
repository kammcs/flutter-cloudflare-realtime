import 'dart:io';

/// gnome-session's `InhibitedActions` (8 is idle), read with `busctl`, or
/// `null` off Linux and where gnome-session doesn't answer (KDE, Xfce).
Future<int?> readGnomeInhibitedActions() async {
  if (!Platform.isLinux) return null;
  try {
    final result = await Process.run('busctl', [
      '--user',
      'get-property',
      'org.gnome.SessionManager',
      '/org/gnome/SessionManager',
      'org.gnome.SessionManager',
      'InhibitedActions',
    ]);
    if (result.exitCode != 0) return null;
    // "u 8"
    return int.tryParse((result.stdout as String).trim().split(' ').last);
  } on ProcessException {
    return null;
  }
}
