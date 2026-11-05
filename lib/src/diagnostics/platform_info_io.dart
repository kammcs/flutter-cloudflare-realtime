import 'dart:io';

import 'platform_info.dart';

/// Native platforms: `dart:io`'s names, and on Linux `/etc/os-release` and
/// the environment.
RealtimePlatformInfo readPlatformInfoNow() {
  if (!Platform.isLinux) {
    return RealtimePlatformInfo(
      os: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
    );
  }
  final distribution = _osReleaseName();
  return RealtimePlatformInfo(
    os: Platform.operatingSystem,
    osVersion: [?distribution, Platform.operatingSystemVersion].join('; '),
    linux: LinuxPlatformInfo.fromEnvironment(Platform.environment),
  );
}

/// `PRETTY_NAME` (else `NAME` and `VERSION_ID`) from os-release, or `null`.
String? _osReleaseName() {
  for (final path in const ['/etc/os-release', '/usr/lib/os-release']) {
    try {
      final fields = parseOsRelease(File(path).readAsStringSync());
      final pretty = fields['PRETTY_NAME'];
      if (pretty != null && pretty.isNotEmpty) return pretty;
      final name = fields['NAME'];
      if (name != null && name.isNotEmpty) {
        return [name, ?fields['VERSION_ID']].join(' ');
      }
    } on FileSystemException {
      continue;
    }
  }
  return null;
}

/// The `KEY=value` lines of an os-release file, with their quotes removed.
Map<String, String> parseOsRelease(String text) {
  final fields = <String, String>{};
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final equals = trimmed.indexOf('=');
    if (equals <= 0) continue;
    var value = trimmed.substring(equals + 1).trim();
    if (value.length >= 2 &&
        (value.startsWith('"') && value.endsWith('"') ||
            value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    fields[trimmed.substring(0, equals)] = value.replaceAll(r'\"', '"');
  }
  return fields;
}
