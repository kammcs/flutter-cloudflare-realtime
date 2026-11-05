import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/diagnostics/platform_info.dart'
    show isWaylandSession;
import 'package:cloudflare_realtime/src/diagnostics/platform_info_io.dart'
    show parseOsRelease;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isWaylandSession (libwebrtc\'s rule)', () {
    test('needs both XDG_SESSION_TYPE=wayland and WAYLAND_DISPLAY', () {
      expect(
        isWaylandSession({
          'XDG_SESSION_TYPE': 'wayland',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        isTrue,
      );
      expect(isWaylandSession({'XDG_SESSION_TYPE': 'wayland'}), isFalse);
      expect(isWaylandSession({'WAYLAND_DISPLAY': 'wayland-0'}), isFalse);
      expect(
        isWaylandSession({
          'XDG_SESSION_TYPE': 'x11',
          'WAYLAND_DISPLAY': 'wayland-0',
        }),
        isFalse,
      );
      expect(isWaylandSession({}), isFalse);
    });
  });

  group('LinuxPlatformInfo.fromEnvironment', () {
    const gnomeWayland = {
      'XDG_SESSION_TYPE': 'wayland',
      'WAYLAND_DISPLAY': 'wayland-0',
      'DISPLAY': ':0',
      'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME',
    };

    test('a Wayland window in GNOME on Wayland', () {
      final info = LinuxPlatformInfo.fromEnvironment(gnomeWayland);
      expect(info.displayServer, LinuxDisplayServer.wayland);
      expect(info.sessionType, 'wayland');
      expect(info.desktop, 'ubuntu:GNOME');
      expect(info.waylandSession, isTrue);
      expect(info.describe(), 'wayland (session wayland), ubuntu:GNOME');
    });

    test('GDK_BACKEND=x11 in a Wayland session is XWayland', () {
      final info = LinuxPlatformInfo.fromEnvironment({
        ...gnomeWayland,
        'GDK_BACKEND': 'x11',
      });
      expect(info.displayServer, LinuxDisplayServer.xwayland);
      // Shares still go through the portal.
      expect(info.waylandSession, isTrue);
    });

    test('an X11 session', () {
      final info = LinuxPlatformInfo.fromEnvironment({
        'XDG_SESSION_TYPE': 'x11',
        'DISPLAY': ':0',
        'XDG_SESSION_DESKTOP': 'plasma',
      });
      expect(info.displayServer, LinuxDisplayServer.x11);
      expect(info.desktop, 'plasma');
      expect(info.waylandSession, isFalse);
    });

    test('no display at all', () {
      final info = LinuxPlatformInfo.fromEnvironment({});
      expect(info.displayServer, LinuxDisplayServer.unknown);
      expect(info.sessionType, isNull);
      expect(info.desktop, isNull);
      expect(info.describe(), 'unknown (session unknown)');
    });
  });

  test('parseOsRelease reads quoted and bare values', () {
    final fields = parseOsRelease('''
# comment
PRETTY_NAME="Ubuntu 24.04.5 LTS"
NAME='Fedora Linux'
VERSION_ID=43
''');
    expect(fields['PRETTY_NAME'], 'Ubuntu 24.04.5 LTS');
    expect(fields['NAME'], 'Fedora Linux');
    expect(fields['VERSION_ID'], '43');
  });

  test('describe and toJson', () {
    const info = RealtimePlatformInfo(
      os: 'linux',
      osVersion: 'Ubuntu 24.04.5 LTS; Linux 6.8.0',
      linux: LinuxPlatformInfo(
        displayServer: LinuxDisplayServer.wayland,
        sessionType: 'wayland',
        desktop: 'KDE',
        waylandSession: true,
      ),
    );
    expect(
      info.describe(),
      'linux; Ubuntu 24.04.5 LTS; Linux 6.8.0; wayland (session wayland), KDE',
    );
    expect(info.toJson(), {
      'os': 'linux',
      'osVersion': 'Ubuntu 24.04.5 LTS; Linux 6.8.0',
      'linux': {
        'displayServer': 'wayland',
        'sessionType': 'wayland',
        'desktop': 'KDE',
        'waylandSession': true,
      },
    });
    expect(const RealtimePlatformInfo(os: 'web').describe(), 'web');
  });

  test('CloudflareRealtime.platformInfo describes this machine', () {
    final info = CloudflareRealtime.platformInfo;
    expect(info.os, isNotEmpty);
    expect(identical(info, CloudflareRealtime.platformInfo), isTrue);
  });
}
