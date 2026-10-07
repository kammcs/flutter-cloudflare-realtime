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
  /// Android, or `null` elsewhere.
  ScreenCaptureServiceBackend? get screenCaptureService;

  /// The host app's Broadcast Upload Extension, through which a screen
  /// share captures on iOS, or `null` elsewhere.
  BroadcastExtensionBackend? get broadcastExtension;
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

/// What a screen share needs around `getDisplayMedia` on iOS
/// (`docs/design.md` §10): the host app's Broadcast Upload Extension, set
/// up as the README's "iOS screen share setup" describes.
///
/// A share checks [status], calls [prepare], then `getDisplayMedia` with
/// `deviceId: 'broadcast'` (which shows the system's broadcast picker), and
/// waits for [BroadcastExtensionEvent.started] on [events]. A
/// [BroadcastExtensionEvent.finished] while sharing means the user stopped
/// the broadcast.
abstract interface class BroadcastExtensionBackend {
  /// Whether the app is set up for a broadcast, and whether one is running.
  Future<BroadcastExtensionStatus> status();

  /// Hands the capture settings to the extension, which reads them when
  /// the broadcast starts: at most [frameRate] frames per second, each
  /// scaled by [scale] (0 < scale <= 1).
  Future<void> prepare({required int frameRate, required double scale});

  /// Called after a share stopped waiting for the broadcast to start, so
  /// that a broadcast started later can't attach to the abandoned capture.
  Future<void> abandon();

  /// The extension's broadcast starting and finishing. A broadcast stream.
  Stream<BroadcastExtensionEvent> get events;
}

/// What the Broadcast Upload Extension reports to the app.
enum BroadcastExtensionEvent {
  /// The user started the broadcast; frames are about to arrive.
  started,

  /// The broadcast ended: the user stopped it, or the app's capture ended.
  finished,
}

/// Something the iOS screen share setup is missing. The README's "iOS
/// screen share setup" covers each one.
enum BroadcastSetupProblem {
  /// The app's Info.plist has no `RTCAppGroupIdentifier`.
  noAppGroupKey(
    "The app's Info.plist has no RTCAppGroupIdentifier (the App Group the "
    'app and its broadcast extension share).',
  ),

  /// The app's Info.plist has no `RTCScreenSharingExtension`.
  noExtensionKey(
    "The app's Info.plist has no RTCScreenSharingExtension (the broadcast "
    "extension's bundle identifier).",
  ),

  /// The App Group's container can't be opened: the app isn't signed with
  /// that App Group.
  appGroupUnavailable(
    "The App Group in RTCAppGroupIdentifier isn't in the app's "
    'entitlements, or not registered for its team.',
  ),

  /// No Broadcast Upload Extension is embedded in the app.
  extensionMissing(
    'The app has no Broadcast Upload Extension embedded (check the '
    '"Embed Foundation Extensions" build phase).',
  ),

  /// No embedded extension has the bundle ID in `RTCScreenSharingExtension`.
  extensionIdMismatch(
    "RTCScreenSharingExtension doesn't match the embedded broadcast "
    "extension's bundle identifier.",
  ),

  /// The extension's `RTCAppGroupIdentifier` isn't the app's.
  extensionAppGroupMismatch(
    "The broadcast extension's RTCAppGroupIdentifier isn't the app's.",
  );

  const BroadcastSetupProblem(this.description);

  /// What's wrong, in a sentence, for developers.
  final String description;

  /// The problem a `status` call reports as [code], or `null` if unknown.
  static BroadcastSetupProblem? fromCode(String code) {
    for (final problem in values) {
      if (problem.name == code) return problem;
    }
    return null;
  }
}

/// The iOS screen share setup as the app finds it: what's missing, and
/// whether a broadcast is running.
final class BroadcastExtensionStatus {
  /// Creates a status.
  const BroadcastExtensionStatus({
    this.problems = const [],
    this.broadcasting = false,
  });

  /// What's missing. Empty when the app is set up.
  final List<BroadcastSetupProblem> problems;

  /// Whether a broadcast is running (it started and hasn't finished).
  final bool broadcasting;

  /// Whether the app is set up for a broadcast.
  bool get isReady => problems.isEmpty;
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

  /// Where [source] is on the desktop now, and its scale, or `null` where
  /// that isn't known (see [ScreenGeometry]).
  ///
  /// The production backend reads it from the operating system on macOS
  /// and Windows (and fills [ScreenSource.geometry] of the sources it
  /// lists the same way); elsewhere it answers `null`. A share polls it
  /// while running (`ScreenShareSource.sourceGeometry`), so it should be
  /// cheap. A fake that has no geometry can answer `null`.
  Future<ScreenGeometry?> geometryOf(ScreenSource source);

  /// Why [source] has no geometry now ([geometryOf] answers `null`): its
  /// window was closed, hidden or minimized, or its display disconnected.
  /// `null` if it still has geometry, or where the operating system can't
  /// tell (see [ScreenSourceEndCause]). A fake can answer `null`.
  Future<ScreenSourceEndCause?> endCauseOf(ScreenSource source);
}
