/// @docImport 'local_media_source.dart';
/// @docImport 'screen_source_picker.dart';
library;

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
bool isSourceNotFoundError(Object error) =>
    error.toString().toLowerCase().contains('source not found');
