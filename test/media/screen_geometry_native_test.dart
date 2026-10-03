// Runs the real `dart:ffi` readers on the host that runs the tests: Core
// Graphics on a Mac, user32 on Windows (CI). It checks that the bindings
// load and answer sanely; `example/integration_test/screen_geometry_test.dart`
// checks the values against the capturer's sources on a desktop.
@TestOn('vm')
library;

import 'dart:io' show Platform;

import 'package:cloudflare_realtime/src/media/screen_geometry_native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final native = createNativeScreenGeometry();

  test('is there on macOS and Windows only', () {
    expect(native != null, Platform.isMacOS || Platform.isWindows);
  });

  test('lists displays: at most one primary, at the origin, with a scale', () {
    final displays = native!.displays();
    // No active display: a headless runner, or a Mac whose display sleeps
    // or is locked (Core Graphics then lists none).
    if (displays.isEmpty) {
      markTestSkipped('no active display');
      return;
    }
    final primaries = displays.where((d) => d.isPrimary).toList();
    expect(primaries.length, lessThanOrEqualTo(1));
    if (Platform.isMacOS) expect(primaries, hasLength(1));
    for (final primary in primaries) {
      expect(primary.bounds.topLeft.dx, 0);
      expect(primary.bounds.topLeft.dy, 0);
    }
    for (final display in displays) {
      expect(int.tryParse(display.id), isNotNull);
      expect(display.bounds.width, greaterThan(0));
      expect(display.bounds.height, greaterThan(0));
      expect(display.scaleFactor, inInclusiveRange(1, 4));
    }
    expect(
      displays.map((d) => d.id).toSet(),
      hasLength(displays.length),
      reason: 'unique IDs',
    );
  }, skip: native == null);

  test('has no frame for windows that do not exist', () {
    expect(native!.windowFrame('0'), isNull);
    expect(native.windowFrame('-1'), isNull);
    expect(native.windowFrame('not-a-number'), isNull);
    // Not a window ID either platform hands out.
    expect(native.windowFrame('4294967295'), isNull);
  }, skip: native == null);
}
