import 'dart:ui' show Rect;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/media/screen_geometry.dart';
import 'package:flutter_test/flutter_test.dart';

/// A scriptable [NativeScreenGeometry].
class FakeNativeGeometry implements NativeScreenGeometry {
  FakeNativeGeometry({this.displayList = const [], Map<String, Rect>? windows})
    : windows = windows ?? {};

  List<NativeDisplay> displayList;
  final Map<String, Rect> windows;
  final Map<String, ScreenSourceEndCause> windowEndCauses = {};
  Object? error;
  int displayCalls = 0;

  @override
  List<NativeDisplay> displays() {
    displayCalls++;
    if (error case final error?) throw error;
    return displayList;
  }

  @override
  Rect? windowFrame(String id) {
    if (error case final error?) throw error;
    return windows[id];
  }

  @override
  ScreenSourceEndCause? windowEndCause(String id) {
    if (error case final error?) throw error;
    return windowEndCauses[id];
  }
}

// macOS-like: a Retina laptop as the primary display, an external display
// to its upper left (negative origin) at scale 1, one to its right.
const NativeDisplay laptop = (
  id: '1',
  bounds: Rect.fromLTWH(0, 0, 1512, 982),
  scaleFactor: 2.0,
  isPrimary: true,
);
const NativeDisplay leftMonitor = (
  id: '2',
  bounds: Rect.fromLTWH(-1920, -200, 1920, 1080),
  scaleFactor: 1.0,
  isPrimary: false,
);
const NativeDisplay rightMonitor = (
  id: '3',
  bounds: Rect.fromLTWH(1512, -200, 2560, 1440),
  scaleFactor: 1.5,
  isPrimary: false,
);

ScreenSource screen(String id) =>
    ScreenSource(id: id, name: 'Screen $id', type: ScreenSourceType.screen);
ScreenSource window(String id) =>
    ScreenSource(id: id, name: 'Window $id', type: ScreenSourceType.window);

void main() {
  late FakeNativeGeometry native;
  late ScreenGeometryLookup lookup;

  setUp(() {
    native = FakeNativeGeometry(
      displayList: [laptop, leftMonitor, rightMonitor],
      windows: {
        // On the laptop.
        '100': const Rect.fromLTWH(100, 50, 800, 600),
        // Mostly on the left monitor, a little on the laptop.
        '200': const Rect.fromLTWH(-1000, 100, 1200, 700),
        // Off every display.
        '300': const Rect.fromLTWH(-5000, 5000, 400, 300),
      },
    );
    lookup = ScreenGeometryLookup(native);
  });

  group('screens', () {
    test('map the source ID to the display with that ID', () {
      expect(lookup.isAvailable, isTrue);
      expect(
        lookup.geometryOf(ScreenSourceType.screen, '1'),
        const ScreenGeometry(
          bounds: Rect.fromLTWH(0, 0, 1512, 982),
          scaleFactor: 2,
          isPrimary: true,
        ),
      );
    });

    test('keep negative origins and mixed scale factors', () {
      final left = lookup.geometryOf(ScreenSourceType.screen, '2')!;
      expect(left.bounds, const Rect.fromLTWH(-1920, -200, 1920, 1080));
      expect(left.scaleFactor, 1);
      expect(left.isPrimary, isFalse);

      final right = lookup.geometryOf(ScreenSourceType.screen, '3')!;
      expect(right.bounds.left, 1512);
      expect(right.bounds.top, -200);
      expect(right.scaleFactor, 1.5);
      expect(right.isPrimary, isFalse);
    });

    test('are null for an ID no display has', () {
      expect(lookup.geometryOf(ScreenSourceType.screen, '9'), isNull);
      // A window's ID isn't a display's.
      expect(lookup.geometryOf(ScreenSourceType.screen, '100'), isNull);
    });
  });

  group('windows', () {
    test('take their frame, and the scale of their display', () {
      expect(
        lookup.geometryOf(ScreenSourceType.window, '100'),
        const ScreenGeometry(
          bounds: Rect.fromLTWH(100, 50, 800, 600),
          scaleFactor: 2,
        ),
      );
    });

    test('across two displays take the scale of the one showing most', () {
      final geometry = lookup.geometryOf(ScreenSourceType.window, '200')!;
      expect(geometry.bounds, const Rect.fromLTWH(-1000, 100, 1200, 700));
      expect(geometry.scaleFactor, 1);
      expect(geometry.isPrimary, isFalse);
    });

    test('off every display take the nearest display\'s scale', () {
      // Nearest to (-4800, 5150): the left monitor.
      expect(lookup.geometryOf(ScreenSourceType.window, '300')!.scaleFactor, 1);
    });

    test('are null when the window is gone (or minimized on Windows)', () {
      expect(lookup.geometryOf(ScreenSourceType.window, '999'), isNull);
    });

    test('follow the window: each lookup reads its frame again', () {
      native.windows['100'] = const Rect.fromLTWH(1600, 0, 800, 600);
      final moved = lookup.geometryOf(ScreenSourceType.window, '100')!;
      expect(moved.bounds, const Rect.fromLTWH(1600, 0, 800, 600));
      expect(moved.scaleFactor, 1.5, reason: 'now on the right monitor');
    });
  });

  group('end causes', () {
    test('a display no longer listed was disconnected', () {
      expect(lookup.endCauseOf(ScreenSourceType.screen, '1'), isNull);
      expect(
        lookup.endCauseOf(ScreenSourceType.screen, '9'),
        ScreenSourceEndCause.closed,
      );
    });

    test('a window answers what the platform says', () {
      native.windowEndCauses['400'] = ScreenSourceEndCause.hidden;
      native.windowEndCauses['500'] = ScreenSourceEndCause.minimized;
      expect(lookup.endCauseOf(ScreenSourceType.window, '100'), isNull);
      expect(
        lookup.endCauseOf(ScreenSourceType.window, '400'),
        ScreenSourceEndCause.hidden,
      );
      expect(
        lookup.endCauseOf(ScreenSourceType.window, '500'),
        ScreenSourceEndCause.minimized,
      );
    });

    test('are null when the platform fails or there is none', () {
      native.error = StateError('EnumDisplayMonitors failed');
      expect(lookup.endCauseOf(ScreenSourceType.screen, '9'), isNull);
      expect(lookup.endCauseOf(ScreenSourceType.window, '400'), isNull);
      expect(
        ScreenGeometryLookup(null).endCauseOf(ScreenSourceType.window, '1'),
        isNull,
      );
    });
  });

  test('windowScaleFactor is 1 without displays', () {
    expect(windowScaleFactor(const Rect.fromLTWH(0, 0, 10, 10), const []), 1);
  });

  test('withGeometry fills a listing, reading the displays once', () {
    final listed = lookup.withGeometry([
      screen('1'),
      screen('2'),
      screen('42'),
      window('100'),
      window('999'),
    ]);
    expect(native.displayCalls, 1);
    expect(listed.map((s) => s.geometry?.bounds), [
      const Rect.fromLTWH(0, 0, 1512, 982),
      const Rect.fromLTWH(-1920, -200, 1920, 1080),
      null,
      const Rect.fromLTWH(100, 50, 800, 600),
      null,
    ]);
    expect(listed.map((s) => s.id), ['1', '2', '42', '100', '999']);
    expect(listed[0].name, 'Screen 1');
  });

  test('withGeometryOf fills one source', () {
    expect(lookup.withGeometryOf(screen('1')).geometry?.isPrimary, isTrue);
    expect(lookup.withGeometryOf(screen('9')).geometry, isNull);
  });

  test('a failing platform answers null, and leaves sources as they are', () {
    native.error = StateError('CGGetActiveDisplayList failed');
    expect(lookup.geometryOf(ScreenSourceType.screen, '1'), isNull);
    expect(lookup.geometryOf(ScreenSourceType.window, '100'), isNull);
    final sources = [screen('1'), window('100')];
    expect(lookup.withGeometry(sources), sources);
  });

  test('without a platform reader everything is null', () {
    final none = ScreenGeometryLookup(null);
    expect(none.isAvailable, isFalse);
    expect(none.geometryOf(ScreenSourceType.screen, '1'), isNull);
    final sources = [screen('1')];
    expect(none.withGeometry(sources), same(sources));
    expect(none.withGeometryOf(sources.first), same(sources.first));
  });

  group('value types', () {
    const geometry = ScreenGeometry(
      bounds: Rect.fromLTWH(-1920, 0, 1920, 1080),
      scaleFactor: 1.25,
    );

    test('ScreenGeometry compares by value', () {
      expect(
        geometry,
        const ScreenGeometry(
          bounds: Rect.fromLTWH(-1920, 0, 1920, 1080),
          scaleFactor: 1.25,
        ),
      );
      expect(
        geometry,
        isNot(
          const ScreenGeometry(
            bounds: Rect.fromLTWH(-1920, 0, 1920, 1080),
            scaleFactor: 1.25,
            isPrimary: true,
          ),
        ),
      );
      expect(geometry.isPrimary, isFalse);
      expect(geometry.toString(), contains('-1920'));
    });

    test('ScreenSource carries its geometry through copyWith and ==', () {
      final source = screen('1').copyWith(geometry: geometry);
      expect(source.geometry, geometry);
      expect(source.copyWith(name: 'Renamed').geometry, geometry);
      expect(source, isNot(screen('1')));
      expect(source, screen('1').copyWith(geometry: geometry));
      expect(
        source.hashCode,
        screen('1').copyWith(geometry: geometry).hashCode,
      );
    });
  });
}
