/// @docImport '../media/screen_share_source.dart';
/// @docImport '../room/cloudflare_realtime.dart';
library;

import 'package:flutter/foundation.dart';

import 'platform_info_platform.dart';

/// How a Linux app's window reaches the screen, and what the session runs.
enum LinuxDisplayServer {
  /// A Wayland window in a Wayland session.
  wayland,

  /// An X11 window through XWayland, inside a Wayland session (GTK told to
  /// use X11, with `GDK_BACKEND=x11`).
  xwayland,

  /// An X11 window in an X11 session.
  x11,

  /// Neither could be told (no `WAYLAND_DISPLAY` or `DISPLAY`).
  unknown,
}

/// What the package reads about the platform it runs on, for diagnostics:
/// the operating system and, on Linux, the display server and the desktop.
///
/// Read with [CloudflareRealtime.platformInfo]. Logged once, at the
/// `info` level, when the first room joins. Holds no identifiers: no host
/// name, user name or device ID.
@immutable
final class RealtimePlatformInfo {
  /// Creates a description. For tests and fakes; the package reads its
  /// own with [CloudflareRealtime.platformInfo].
  const RealtimePlatformInfo({required this.os, this.osVersion, this.linux});

  /// The operating system, as `dart:io`'s `Platform.operatingSystem`
  /// names it (`linux`, `windows`, `macos`, `android`, `ios`), or `web`.
  final String os;

  /// The operating system's version: on Linux the distribution's
  /// `PRETTY_NAME` from `/etc/os-release` and the kernel ("Ubuntu 24.04.5
  /// LTS; Linux 6.8.0-45-generic"); elsewhere `Platform.operatingSystemVersion`.
  /// `null` on the web.
  final String? osVersion;

  /// The Linux details, or `null` on other platforms.
  final LinuxPlatformInfo? linux;

  /// A one-line description, for a log or a support report.
  String describe() => [
    os,
    ?osVersion,
    if (linux case final linux?) linux.describe(),
  ].join('; ');

  /// The fields as a JSON-ready map.
  Map<String, Object?> toJson() => {
    'os': os,
    'osVersion': osVersion,
    if (linux case final linux?) 'linux': linux.toJson(),
  };

  @override
  String toString() => 'RealtimePlatformInfo(${describe()})';

  @override
  bool operator ==(Object other) =>
      other is RealtimePlatformInfo &&
      other.os == os &&
      other.osVersion == osVersion &&
      other.linux == linux;

  @override
  int get hashCode => Object.hash(os, osVersion, linux);
}

/// The Linux part of [RealtimePlatformInfo].
@immutable
final class LinuxPlatformInfo {
  /// Creates the Linux part.
  const LinuxPlatformInfo({
    required this.displayServer,
    this.sessionType,
    this.desktop,
    required this.waylandSession,
  });

  /// Reads it from an environment (`Platform.environment` in the app).
  ///
  /// - [displayServer]: GTK's own choice, as the environment drives it: X11
  ///   when `GDK_BACKEND` asks for it first (XWayland when the session is
  ///   Wayland), else Wayland when `WAYLAND_DISPLAY` is set, else X11 when
  ///   `DISPLAY` is.
  /// - [sessionType]: `XDG_SESSION_TYPE`.
  /// - [desktop]: `XDG_CURRENT_DESKTOP` ("ubuntu:GNOME", "KDE"), else
  ///   `XDG_SESSION_DESKTOP` or `DESKTOP_SESSION`.
  /// - [waylandSession]: [isWaylandSession].
  factory LinuxPlatformInfo.fromEnvironment(Map<String, String> environment) {
    String? read(String name) {
      final value = environment[name]?.trim();
      return value == null || value.isEmpty ? null : value;
    }

    final wayland = isWaylandSession(environment);
    final gdkBackend = read('GDK_BACKEND');
    final x11First =
        gdkBackend != null &&
        gdkBackend.split(',').first.trim().toLowerCase() == 'x11';
    final LinuxDisplayServer server;
    if (x11First && read('DISPLAY') != null) {
      server = wayland ? LinuxDisplayServer.xwayland : LinuxDisplayServer.x11;
    } else if (read('WAYLAND_DISPLAY') != null) {
      server = LinuxDisplayServer.wayland;
    } else if (read('DISPLAY') != null) {
      server = wayland ? LinuxDisplayServer.xwayland : LinuxDisplayServer.x11;
    } else {
      server = LinuxDisplayServer.unknown;
    }
    return LinuxPlatformInfo(
      displayServer: server,
      sessionType: read('XDG_SESSION_TYPE'),
      desktop:
          read('XDG_CURRENT_DESKTOP') ??
          read('XDG_SESSION_DESKTOP') ??
          read('DESKTOP_SESSION'),
      waylandSession: wayland,
    );
  }

  /// How the app's window reaches the screen.
  final LinuxDisplayServer displayServer;

  /// The session's type (`XDG_SESSION_TYPE`: `wayland`, `x11`, `tty`), or
  /// `null` when it isn't set.
  final String? sessionType;

  /// The desktop (`XDG_CURRENT_DESKTOP`: "ubuntu:GNOME", "KDE",
  /// "XFCE"), or `null` when it isn't set.
  final String? desktop;

  /// Whether the session is Wayland by WebRTC's own rule
  /// ([isWaylandSession]). Screen shares then go through the system's
  /// ScreenCast portal ([ScreenShareSource.usesSystemPicker]), whatever
  /// [displayServer] the app's window uses.
  final bool waylandSession;

  /// A short description: "wayland (session wayland), ubuntu:GNOME".
  String describe() => [
    '${displayServer.name} (session ${sessionType ?? 'unknown'})',
    ?desktop,
  ].join(', ');

  /// The fields as a JSON-ready map.
  Map<String, Object?> toJson() => {
    'displayServer': displayServer.name,
    'sessionType': sessionType,
    'desktop': desktop,
    'waylandSession': waylandSession,
  };

  @override
  bool operator ==(Object other) =>
      other is LinuxPlatformInfo &&
      other.displayServer == displayServer &&
      other.sessionType == sessionType &&
      other.desktop == desktop &&
      other.waylandSession == waylandSession;

  @override
  int get hashCode =>
      Object.hash(displayServer, sessionType, desktop, waylandSession);
}

/// Whether [environment] is a Wayland session by WebRTC's own rule
/// (`DesktopCapturer::IsRunningUnderWayland`): `XDG_SESSION_TYPE` starts
/// with `wayland` and `WAYLAND_DISPLAY` is set. libwebrtc then captures
/// screens through the ScreenCast portal and PipeWire, so the package and
/// the capturer always agree on it.
bool isWaylandSession(Map<String, String> environment) {
  final type = environment['XDG_SESSION_TYPE'] ?? '';
  final display = environment['WAYLAND_DISPLAY'] ?? '';
  return type.startsWith('wayland') && display.isNotEmpty;
}

/// **Tests only:** replaces what [readPlatformInfo] returns. Reset it to
/// `null` afterwards.
@visibleForTesting
RealtimePlatformInfo? debugPlatformInfoOverride;

RealtimePlatformInfo? _cached;

/// What the package reads about this platform, read once and kept.
RealtimePlatformInfo readPlatformInfo() =>
    debugPlatformInfoOverride ?? (_cached ??= readPlatformInfoNow());

/// Whether this is Linux in a Wayland session ([isWaylandSession]).
bool get runsInWaylandSession =>
    readPlatformInfo().linux?.waylandSession ?? false;
