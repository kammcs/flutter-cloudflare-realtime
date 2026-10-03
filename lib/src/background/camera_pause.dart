/// @docImport '../room/room.dart';
library;

/// Why the system paused the local camera (`docs/design.md` §4.7).
///
/// Reported on iOS by [Room.cameraPause] and [RoomCameraPausedEvent]. The
/// track stays published and live; it sends no frames until the camera runs
/// again, which it does by itself.
enum CameraPauseReason {
  /// The app went to the background. iOS doesn't let a backgrounded app
  /// use the camera.
  background,

  /// Another app took the camera.
  inUseByAnotherApp,

  /// Several apps are in the foreground (iPad Split View, Slide Over or
  /// Stage Manager) and the app doesn't have multitasking camera access.
  multipleForegroundApps,

  /// The device is too hot or too loaded.
  systemPressure,

  /// Another reason.
  other,
}
