/// @docImport 'local_media_source.dart';
/// @docImport 'screen_source_picker.dart';
library;

import 'media_backend.dart';
import 'media_types.dart';

/// A failure in the media layer, reported on [LocalMediaSource.errors] or
/// in [ScreenPickerState.error].
///
/// `flutter_webrtc` reports most native failures as plain strings, so
/// [cause] is often a `String`. Don't show it to users verbatim.
sealed class MediaException implements Exception {
  const MediaException(this.message, {this.cause});

  /// What went wrong, for logs.
  final String message;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType: $message${cause == null ? '' : ' ($cause)'}';
}

/// The user or the OS denied access to the camera, microphone or screen.
///
/// The source stops trying other devices when it sees this, because every
/// device would fail the same way.
final class MediaPermissionDeniedException extends MediaException {
  /// Creates the exception.
  const MediaPermissionDeniedException(super.message, {super.cause});
}

/// The OS doesn't let this app capture the screen, or probably doesn't.
///
/// On macOS, capturing the screen needs the user's **Screen Recording**
/// permission (System Settings → Privacy & Security → Screen & System Audio
/// Recording; "Screen Recording" on macOS 14 and earlier). There is no
/// entitlement or `Info.plist` key for it, and `flutter_webrtc` 1.6 neither
/// asks for it nor reports it: without it, windows go missing from the
/// source list, thumbnails come back empty or black, and a share starts but
/// never delivers a frame. The package detects those symptoms, so this is
/// usually a suspicion ([suspected]) rather than a verdict. macOS applies a
/// newly granted permission only after the app restarts.
///
/// Reported in [ScreenPickerState.permissionProblem] and by the room when a
/// screen share on macOS sends no frames. Show [guidance] to the user.
final class ScreenCapturePermissionException
    extends MediaPermissionDeniedException {
  /// Creates the exception.
  const ScreenCapturePermissionException(
    super.message, {
    this.platform = MediaPlatform.macos,
    this.suspected = true,
    super.cause,
  });

  /// The platform whose permission is missing.
  final MediaPlatform platform;

  /// Whether this is inferred from symptoms (the usual case) rather than
  /// reported by the OS.
  final bool suspected;

  /// What the user should do, in a sentence or two, ready to show.
  String get guidance => switch (platform) {
    MediaPlatform.macos => macOSGuidance,
    MediaPlatform.web =>
      'Allow screen sharing for this site in the browser, then try again.',
    _ =>
      'Allow screen capture for this app in the system settings, then '
          'try again.',
  };

  /// [guidance] on macOS.
  static const macOSGuidance =
      'Open System Settings → Privacy & Security → Screen & System Audio '
      'Recording (Screen Recording on macOS 14 and earlier), turn this app '
      'on, then quit and reopen it. macOS applies the permission only after '
      'a restart.';
}

/// The app isn't set up for screen share on this platform: on iOS, the
/// Broadcast Upload Extension, its App Group or the Info.plist keys are
/// missing (`docs/design.md` §10).
///
/// This is a developer's mistake, not the user's: the share can't start
/// until the app is rebuilt. Log [guidance]; tell the user only that screen
/// sharing isn't available.
final class ScreenShareSetupException extends MediaException {
  /// Creates the exception.
  const ScreenShareSetupException(
    super.message, {
    this.problems = const [],
    super.cause,
  });

  /// What's missing.
  final List<BroadcastSetupProblem> problems;

  /// What to fix, for developers: one line per problem, then where the
  /// setup is described.
  String get guidance => [
    for (final problem in problems) problem.description,
    'See "iOS screen share setup" in the cloudflare_realtime README.',
  ].join('\n');
}

/// Every candidate device failed to produce a track.
///
/// Named after partytracks' `DevicesExhaustedError`. [failures] holds each
/// device's error, in the order the devices were tried.
final class DevicesExhaustedException extends MediaException {
  /// Creates the exception.
  const DevicesExhaustedException(
    super.message, {
    this.failures = const [],
    super.cause,
  });

  /// Each device that was tried, with its error. A `null` device means an
  /// unconstrained request (no device list was available).
  final List<(MediaDevice?, Object)> failures;
}

/// Capture failed for a reason other than permissions, for example
/// `getDisplayMedia` rejecting its constraints.
final class MediaCaptureException extends MediaException {
  /// Creates the exception.
  const MediaCaptureException(super.message, {super.cause});
}

/// Listing desktop screens and windows failed.
///
/// On Windows, `desktopCapturer.getSources` sometimes throws, returns null
/// or leaves out a display (flutter-webrtc #1539, #1085). This is reported
/// as data, not thrown: the picker keeps working, and
/// [ScreenSourcePicker.refresh] retries.
final class ScreenSourcesException extends MediaException {
  /// Creates the exception.
  const ScreenSourcesException(
    super.message, {
    this.noScreens = false,
    super.cause,
  });

  /// Whether listing "succeeded" but returned no screens even though screens
  /// were requested. Every desktop has at least one display, so this is a
  /// listing failure too.
  final bool noScreens;
}

/// `getDisplayMedia` couldn't find the chosen screen or window, even after
/// the source list was refreshed and capture retried.
///
/// The window was probably closed, or the display unplugged, between
/// picking and capturing (flutter-webrtc #1085 shows this as
/// "source not found!").
final class ScreenSourceNotFoundException extends MediaException {
  /// Creates the exception.
  const ScreenSourceNotFoundException(
    super.message, {
    required this.sourceId,
    super.cause,
  });

  /// The ID of the source that couldn't be captured.
  final String sourceId;
}

/// Whether [error], as thrown by `getUserMedia`/`getDisplayMedia`, means
/// permission was denied.
///
/// `flutter_webrtc` throws strings such as
/// `"Unable to getUserMedia: NotAllowedError: Permission denied"`, so this
/// matches on text.
bool isPermissionError(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains('notallowederror') ||
      text.contains('permission denied') ||
      text.contains('permissiondenied') ||
      text.contains('securityerror');
}

/// Whether [error], as thrown by the desktop `getDisplayMedia`, means the
/// requested source isn't in the plugin's source list.
///
/// Windows and Linux say "source not found!". macOS answers
/// `{error: "No source found for id: ..."}` instead of throwing, which
/// `flutter_webrtc` 1.6 then fails to read (a `TypeError` about a `Null`
/// `streamId`), so on [platform] macOS that `TypeError` counts too.
bool isSourceNotFoundError(Object error, {MediaPlatform? platform}) {
  final text = error.toString().toLowerCase();
  if (text.contains('source not found') || text.contains('no source found')) {
    return true;
  }
  return platform == MediaPlatform.macos &&
      error is TypeError &&
      text.contains('null');
}
