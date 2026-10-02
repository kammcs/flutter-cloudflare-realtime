/// @docImport 'flutter_webrtc_media_backend.dart';
library;

import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'media_types.dart';

/// The `flutter_webrtc` media APIs the media layer uses, behind an interface
/// so that everything above it can be unit-tested with fakes.
///
/// The production implementation is [FlutterWebrtcMediaBackend]. Plugins
/// don't run under `flutter test`, so tests pass their own implementation.
///
/// Constraint maps are passed through unchanged: the media layer builds
/// them in the shape each platform expects (see `constraints.dart`).
abstract interface class MediaBackend {
  /// The platform this backend captures on.
  MediaPlatform get platform;

  /// `navigator.mediaDevices.getUserMedia`.
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints);

  /// `navigator.mediaDevices.getDisplayMedia`.
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> constraints);

  /// `navigator.mediaDevices.enumerateDevices`, converted to [MediaDevice]s.
  ///
  /// Entries whose kind isn't one of [MediaDeviceKind] are dropped.
  Future<List<MediaDevice>> enumerateDevices();

  /// Emits whenever the OS reports that devices were added or removed
  /// (`ondevicechange`).
  ///
  /// A broadcast stream. Events carry no data; re-enumerate to see what
  /// changed.
  Stream<void> get deviceChanges;

  /// The desktop screen/window capturer, or `null` where there is none
  /// (web, Android, iOS).
  DesktopCapturerBackend? get desktopCapturer;

  /// The system consent and foreground service a screen share needs on
  /// Android, or `null` where `getDisplayMedia` needs neither (desktop,
  /// web) or screen share isn't available (iOS, for now).
  ScreenCaptureServiceBackend? get screenCaptureService;
}

/// What a screen share needs around `getDisplayMedia` on Android
/// (`docs/design.md` §10): the MediaProjection consent dialog, and a
/// foreground service of type `mediaProjection`, which Android 14+ requires
/// to be running after consent and before the projection is created.
///
/// A share calls [requestConsent], then [startService], then
/// `getDisplayMedia`, then [watch] with the video track's ID; and
/// [stopService] once the capture is released (or failed).
abstract interface class ScreenCaptureServiceBackend {
  /// Shows the system's screen-capture consent dialog. Completes with
  /// `false` if the user cancelled it.
  ///
  /// May first ask for the notification permission (Android 13+), so the
  /// service's notification shows; a denial doesn't stop the share.
  Future<bool> requestConsent();

  /// Starts the foreground service and completes once it is in the
  /// foreground. Throws if it can't start.
  Future<void> startService();

  /// Watches the projection behind the screen track [trackId], so a share
  /// the user stops from the system arrives on [stopped]. Completes with
  /// whether it can.
  Future<bool> watch(String trackId);

  /// Stops the foreground service and the watch. Safe to call when nothing
  /// runs.
  Future<void> stopService();

  /// Emits when the user ends the share outside the app: from the system
  /// (the projection's `onStop`, with the track ID [watch] was given) or
  /// from the service's notification (`null`: whichever share is running).
  Stream<String?> get stopped;
}

/// `flutter_webrtc`'s `desktopCapturer`, converted to immutable
/// [ScreenSource] snapshots.
///
/// Its events only cover sources returned by the last [getSources] call, and
/// they only fire while something calls [updateSources] periodically; the
/// plugin doesn't poll on its own.
abstract interface class DesktopCapturerBackend {
  /// Lists the sources of the given [types].
  ///
  /// Also resets the plugin's internal source list, which `getDisplayMedia`
  /// looks the chosen source up in.
  Future<List<ScreenSource>> getSources({
    required Set<ScreenSourceType> types,
    ({int width, int height})? thumbnailSize,
  });

  /// Asks the plugin to re-scan sources of the given [types].
  ///
  /// Differences from the previous scan arrive on [onAdded], [onRemoved],
  /// [onNameChanged] and [onThumbnailChanged].
  Future<bool> updateSources({required Set<ScreenSourceType> types});

  /// A source appeared, such as a newly opened window.
  Stream<ScreenSource> get onAdded;

  /// A source went away, such as a closed window or unplugged display.
  Stream<ScreenSource> get onRemoved;

  /// A source's name changed, such as a window title. Carries the new name.
  Stream<ScreenSource> get onNameChanged;

  /// A source has a new thumbnail. Carries the new thumbnail.
  Stream<ScreenSource> get onThumbnailChanged;
}
