/// @docImport 'local_media_source.dart';
/// @docImport 'screen_source_picker.dart';
library;

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Which way a camera faces.
enum CameraFacing {
  /// Toward the user: a phone's front ("selfie") camera.
  user,

  /// Away from the user: a phone's back camera.
  environment,
}

/// The platform the media layer runs on.
///
/// Capture works differently per platform: device selection constraints,
/// screen-share APIs and which events `flutter_webrtc` delivers all vary.
enum MediaPlatform {
  /// A browser.
  web,

  /// Windows desktop.
  windows,

  /// macOS desktop.
  macos,

  /// Linux desktop.
  linux,

  /// Android.
  android,

  /// iOS.
  ios,

  /// Anything else (for example Fuchsia).
  unknown;

  /// Whether this is Windows, macOS or Linux.
  bool get isDesktop => this == windows || this == macos || this == linux;

  /// Whether this is Android or iOS.
  bool get isMobile => this == android || this == ios;
}

/// What kind of device a [MediaDevice] is.
enum MediaDeviceKind {
  /// A microphone (`audioinput`).
  audioInput('audioinput'),

  /// A camera (`videoinput`).
  videoInput('videoinput'),

  /// A speaker or headset output (`audiooutput`).
  audioOutput('audiooutput');

  const MediaDeviceKind(this.wireName);

  /// The W3C `MediaDeviceInfo.kind` string.
  final String wireName;

  /// Parses a W3C `MediaDeviceInfo.kind` string. Returns `null` for anything
  /// else.
  static MediaDeviceKind? fromWireName(String? name) {
    for (final kind in values) {
      if (kind.wireName == name) return kind;
    }
    return null;
  }
}

/// A camera, microphone or audio output, as listed by `enumerateDevices`.
///
/// Two devices are equal when all their fields are equal.
@immutable
final class MediaDevice {
  /// Creates a device description.
  const MediaDevice({
    required this.deviceId,
    required this.kind,
    this.label = '',
    this.groupId,
    this.facing,
    this.isDefault = false,
  });

  /// The platform's identifier for this device.
  ///
  /// On the web it's empty until the user grants media permission.
  final String deviceId;

  /// What kind of device this is.
  final MediaDeviceKind kind;

  /// A human-readable name, such as "External USB Webcam".
  ///
  /// On the web it's empty until the user grants media permission.
  final String label;

  /// Devices with the same group ID belong to the same physical device.
  final String? groupId;

  /// Which way this camera faces, when known: from the platform on Android
  /// and iOS, and from the label in browsers ("Front Camera", "camera2 0,
  /// facing back"). `null` for desktop cameras, which don't say, and for
  /// microphones and speakers.
  final CameraFacing? facing;

  /// Whether the system names this device as its default for calls, so
  /// capture prefers it (see `prioritizeDevices`).
  ///
  /// - **Windows:** the default communications device of Sound settings,
  ///   read from the OS (Core Audio), for microphones and speakers.
  ///   `flutter_webrtc` lists Windows audio devices in an order of their
  ///   own (by endpoint ID) and doesn't say which one is the default.
  /// - **Browsers:** the `default` and `communications` entries that
  ///   Chromium lists ("Default - Headset Microphone").
  /// - `false` elsewhere: the other native plugins don't mark one (phones
  ///   route audio themselves), and no OS has a default camera.
  final bool isDefault;

  /// Whether this device is the same physical device as [other].
  ///
  /// Matches on [deviceId], or on a non-empty [label] of the same [kind].
  /// Device IDs can change between runs on some platforms, and partytracks
  /// matches remembered devices by label for the same reason.
  bool sameDeviceAs(MediaDevice other) =>
      kind == other.kind &&
      ((deviceId.isNotEmpty && deviceId == other.deviceId) ||
          (label.isNotEmpty && label == other.label));

  @override
  bool operator ==(Object other) =>
      other is MediaDevice &&
      other.deviceId == deviceId &&
      other.kind == kind &&
      other.label == label &&
      other.groupId == groupId &&
      other.facing == facing &&
      other.isDefault == isDefault;

  @override
  int get hashCode =>
      Object.hash(deviceId, kind, label, groupId, facing, isDefault);

  @override
  String toString() =>
      'MediaDevice(${kind.wireName}, "$label", $deviceId'
      '${facing == null ? '' : ', ${facing!.name}'}'
      '${isDefault ? ', default' : ''})';
}

/// A local track captured by a [LocalMediaSource], with the stream it
/// belongs to.
///
/// Renderers need the [stream] (`RTCVideoRenderer.srcObject`); publishing
/// needs the [track]. The source owns both: it stops the track and disposes
/// the stream when it replaces or releases the capture. Don't stop them
/// yourself.
@immutable
final class CapturedTrack {
  /// Wraps a captured [track] and its [stream].
  const CapturedTrack({required this.track, required this.stream, this.device});

  /// The captured media track.
  final MediaStreamTrack track;

  /// The stream [track] came from.
  final MediaStream stream;

  /// The camera or microphone the track captures, when known.
  ///
  /// `null` for screen shares, and when the platform didn't report which
  /// device it opened.
  final MediaDevice? device;

  /// The track's ID.
  String? get id => track.id;

  @override
  bool operator ==(Object other) =>
      other is CapturedTrack &&
      identical(other.track, track) &&
      identical(other.stream, stream) &&
      other.device == device;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(track), identityHashCode(stream), device);

  @override
  String toString() =>
      'CapturedTrack(${track.kind}, id: ${track.id}, device: $device)';
}

/// Whether a desktop capture source is a whole screen or a single window.
enum ScreenSourceType {
  /// A whole display.
  screen,

  /// A single application window.
  window,
}

/// Where a shared display or window is on the desktop, and its scale.
///
/// Coordinates are the operating system's own desktop coordinates, the ones
/// its input and window APIs take, so an app can map a point in the shared
/// picture to a point on the sharer's desktop (remote pointers, annotation,
/// remote control):
///
/// - **macOS:** points in Core Graphics' global display space
///   (`CGDisplayBounds`, `CGWindowListCopyWindowInfo`, `CGEvent`
///   locations). The origin is the top-left corner of the primary display
///   ([isPrimary]), y grows downwards, and displays left of or above it
///   have negative coordinates. AppKit's `NSScreen` frames use the same
///   units with y flipped (origin at the primary display's bottom-left, y
///   upwards). A display's pixels are `bounds.size * scaleFactor`.
/// - **Windows:** physical pixels in the virtual screen (`GetMonitorInfo`,
///   `SetCursorPos`), as a per-monitor DPI-aware app (Flutter's default
///   runner) sees them. The origin is the top-left corner of the primary
///   monitor, y grows downwards, and monitors left of or above it have
///   negative coordinates. With mixed scale factors the virtual screen has
///   no common logical unit, so [bounds] stays in pixels.
///
/// Elsewhere (the web, Android, iOS, Linux) sources have no geometry.
@immutable
final class ScreenGeometry {
  /// Creates a geometry.
  const ScreenGeometry({
    required this.bounds,
    required this.scaleFactor,
    this.isPrimary = false,
  });

  /// A display's bounds, or a window's frame, in the desktop coordinates
  /// described on [ScreenGeometry].
  ///
  /// A window's frame is the one the user sees: on macOS the window
  /// server's bounds (title bar included), on Windows the frame without
  /// the invisible resize borders (`DWMWA_EXTENDED_FRAME_BOUNDS`).
  final Rect bounds;

  /// Physical pixels per logical point: the display's backing scale on
  /// macOS (2.0 on a Retina display), its effective DPI over 96 on Windows
  /// (1.5 at 150 %). For a window, the scale of the display that shows most
  /// of it.
  final double scaleFactor;

  /// Whether this is the primary display: on macOS the one at the origin of
  /// the global display space (`CGMainDisplayID`), on Windows the primary
  /// monitor (`MONITORINFOF_PRIMARY`). Always `false` for a window.
  final bool isPrimary;

  @override
  bool operator ==(Object other) =>
      other is ScreenGeometry &&
      other.bounds == bounds &&
      other.scaleFactor == scaleFactor &&
      other.isPrimary == isPrimary;

  @override
  int get hashCode => Object.hash(bounds, scaleFactor, isPrimary);

  @override
  String toString() =>
      'ScreenGeometry(${bounds.left}, ${bounds.top}, '
      '${bounds.width} x ${bounds.height}, scale: $scaleFactor'
      '${isPrimary ? ', primary' : ''})';
}

/// A screen or window that can be shared on desktop, as listed by
/// `desktopCapturer.getSources`.
///
/// Instances are immutable snapshots. A [ScreenSourcePicker] replaces a
/// source with a new snapshot when its name or thumbnail changes.
@immutable
final class ScreenSource {
  /// Creates a source description.
  const ScreenSource({
    required this.id,
    required this.name,
    required this.type,
    this.thumbnail,
    this.geometry,
  });

  /// The platform's identifier for the source. Screen shares pass it as
  /// `deviceId: {exact: id}` to `getDisplayMedia`.
  final String id;

  /// A screen's name ("Screen 1", "Entire screen") or a window's title.
  final String name;

  /// Whether this is a screen or a window.
  final ScreenSourceType type;

  /// A JPEG/PNG thumbnail, or `null` until the platform has produced one.
  ///
  /// On Windows the first listing has no thumbnails; they arrive shortly
  /// after, through the picker's live updates.
  final Uint8List? thumbnail;

  /// Where the display or window was on the desktop when the source was
  /// listed, and its scale; `null` where that isn't known.
  ///
  /// Read on macOS and Windows (see [ScreenGeometry] for the coordinates);
  /// `null` on other platforms, and for a source the operating system no
  /// longer knows (or, on Windows, a minimized window). Windows move: while
  /// a source is shared, `ScreenShareSource.sourceGeometry` follows it.
  final ScreenGeometry? geometry;

  /// Returns a copy with the given fields replaced.
  ScreenSource copyWith({
    String? name,
    Uint8List? thumbnail,
    ScreenGeometry? geometry,
  }) => ScreenSource(
    id: id,
    name: name ?? this.name,
    type: type,
    thumbnail: thumbnail ?? this.thumbnail,
    geometry: geometry ?? this.geometry,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenSource &&
      other.id == id &&
      other.name == name &&
      other.type == type &&
      identical(other.thumbnail, thumbnail) &&
      other.geometry == geometry;

  @override
  int get hashCode =>
      Object.hash(id, name, type, identityHashCode(thumbnail), geometry);

  @override
  String toString() => 'ScreenSource(${type.name}, "$name", $id)';
}
