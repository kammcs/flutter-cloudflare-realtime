import 'package:cloudflare_realtime/src/screen_awake/screen_awake_linux.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('appIdFromSystemdUnit', () {
    test('reads launched apps, as xdg-desktop-portal does', () {
      expect(
        appIdFromSystemdUnit('app-gnome-com.kammcs.Example-12345.scope'),
        'com.kammcs.Example',
      );
      expect(
        appIdFromSystemdUnit('app-gnome-org.gnome.Terminal-ab12cd.scope'),
        'org.gnome.Terminal',
      );
      expect(
        appIdFromSystemdUnit('app-org.kde.konsole@a1b2c3.service'),
        'org.kde.konsole',
      );
      expect(
        appIdFromSystemdUnit('app-flatpak-org.example.App-4242.scope'),
        'org.example.App',
      );
    });

    test('is null without a valid application ID', () {
      // No dot: not a valid application ID.
      expect(appIdFromSystemdUnit('app-gnome-firefox-1234.scope'), isNull);
      // Not an app unit.
      expect(appIdFromSystemdUnit('session-2.scope'), isNull);
      expect(appIdFromSystemdUnit('vte-spawn-1a2b.scope'), isNull);
      expect(appIdFromSystemdUnit('user@1000.service'), isNull);
      expect(appIdFromSystemdUnit(''), isNull);
    });
  });

  test('the default order follows whether the portal can name the app', () {
    expect(
      defaultLinuxInhibitors(),
      linuxPortalKnowsApp()
          ? [LinuxInhibitor.portal, LinuxInhibitor.screenSaver]
          : [LinuxInhibitor.screenSaver, LinuxInhibitor.portal],
    );
  });
}
