// The Linux backend against the real session bus. Skipped unless it runs on
// a GNOME desktop with CF_REALTIME_LIVE_DBUS=1, since it takes a real idle
// inhibitor (for a second) and reads it back from gnome-session.
//
// GNOME's portal refuses an inhibitor for a host app without an application
// ID, so run it in a scope named like a launched app (the way GNOME Shell
// starts a .desktop app):
//
//   CF_REALTIME_LIVE_DBUS=1 systemd-run --user --scope \
//     --unit=app-gnome-dev.kammcs.CloudflareRealtimeTest-$$ \
//     flutter test test/screen_awake/linux_screen_awake_live_test.dart
@TestOn('linux')
library;

import 'dart:io';

import 'package:cloudflare_realtime/src/screen_awake/screen_awake_linux.dart';
import 'package:flutter_test/flutter_test.dart';

final _live =
    Platform.isLinux &&
    Platform.environment['CF_REALTIME_LIVE_DBUS'] == '1' &&
    (Platform.environment['XDG_CURRENT_DESKTOP'] ?? '').contains('GNOME');

/// The reasons of gnome-session's current inhibitors with the idle flag.
Future<List<String>> _idleInhibitorReasons() async {
  Future<String> busctl(List<String> args) async {
    final result = await Process.run('busctl', ['--user', ...args]);
    if (result.exitCode != 0) throw StateError('busctl: ${result.stderr}');
    return result.stdout as String;
  }

  final list = await busctl([
    'call',
    'org.gnome.SessionManager',
    '/org/gnome/SessionManager',
    'org.gnome.SessionManager',
    'GetInhibitors',
  ]);
  final paths = RegExp(r'"(/[^"]+)"').allMatches(list).map((m) => m[1]!);
  final reasons = <String>[];
  for (final path in paths) {
    final flags = await busctl([
      'call',
      'org.gnome.SessionManager',
      path,
      'org.gnome.SessionManager.Inhibitor',
      'GetFlags',
    ]);
    if ((int.parse(flags.trim().split(' ').last) & 8) == 0) continue;
    final reason = await busctl([
      'call',
      'org.gnome.SessionManager',
      path,
      'org.gnome.SessionManager.Inhibitor',
      'GetReason',
    ]);
    reasons.add(reason.trim());
  }
  return reasons;
}

void main() {
  for (final kind in LinuxInhibitor.values) {
    test('${kind.name}: holds an idle inhibitor and releases it', () async {
      Future<int> ours() async => (await _idleInhibitorReasons())
          .where((r) => r.contains('Video call'))
          .length;

      final before = await ours();
      final backend = LinuxScreenAwakeBackend(inhibitors: [kind]);
      expect(await backend.setKeepAwake(true), isTrue);
      expect(backend.activeInhibitor, kind);
      // Taking it twice holds one.
      expect(await backend.setKeepAwake(true), isTrue);
      expect(await ours(), before + 1);

      expect(await backend.setKeepAwake(false), isFalse);
      expect(backend.activeInhibitor, isNull);
      // gnome-session drops it as the request closes.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(await ours(), before);
    }, skip: !_live);
  }

  test('falls back to ScreenSaver when no portal answers', () async {
    final backend = LinuxScreenAwakeBackend(
      portalBusName: 'org.example.NoSuchPortal',
    );
    expect(await backend.setKeepAwake(true), isTrue);
    expect(backend.activeInhibitor, LinuxInhibitor.screenSaver);
    expect(await backend.setKeepAwake(false), isFalse);
  }, skip: !_live);

  test('prefers the portal when it can name the app', () async {
    expect(linuxPortalKnowsApp(), isTrue, reason: 'run it in an app scope');
    final backend = LinuxScreenAwakeBackend();
    expect(await backend.setKeepAwake(true), isTrue);
    expect(backend.activeInhibitor, LinuxInhibitor.portal);
    expect(await backend.setKeepAwake(false), isFalse);
  }, skip: !_live);
}
