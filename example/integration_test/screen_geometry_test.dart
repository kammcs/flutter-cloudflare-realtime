// Display and window geometry of desktop screen-share sources
// (docs/design.md §10, Display and window geometry). Needs no broker.
//
// Lists the capturer's screens and windows and checks each one's
// ScreenSource.geometry against what the system reports through another
// path:
//
// - Screens: Flutter's own display list (PlatformDispatcher.displays; on
//   macOS each NSScreen, keyed by its CGDirectDisplayID, with its pixel
//   size and backing scale). Exactly one screen is primary, at the origin.
// - Windows: this app's own window, found by its title, must have the
//   Flutter view's width and its height plus the title bar.
// - A share of that window: ScreenShareSource.sourceGeometry follows it,
//   and clears when the share stops.
//
// Every value is printed on a `GEOMETRY` line, so it can be compared with
// the window server's from outside the sandbox (NSScreen frames and
// CGWindowListCopyWindowInfo, docs/design.md §10). Listing windows needs the
// Screen Recording permission on macOS. Skipped off desktop.

import 'dart:ui' show PlatformDispatcher, Rect;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

final _desktop =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

const _appTitle = 'cloudflare_realtime_example';

void _log(String message) => debugPrint('GEOMETRY $message');

String _rect(Rect r) => '${r.left},${r.top} ${r.width}x${r.height}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('screen sources carry the OS geometry', (tester) async {
    await tester.pumpWidget(const SizedBox.expand());
    final capturer = FlutterWebrtcMediaBackend().desktopCapturer!;
    final sources = await capturer.getSources(
      types: {ScreenSourceType.screen, ScreenSourceType.window},
    );
    final screens = sources
        .where((s) => s.type == ScreenSourceType.screen)
        .toList();
    final windows = sources
        .where((s) => s.type == ScreenSourceType.window)
        .toList();
    _log('${screens.length} screens, ${windows.length} windows');

    // Screens.
    expect(screens, isNotEmpty);
    for (final s in screens) {
      final g = s.geometry;
      _log(
        'screen id=${s.id} name="${s.name}" '
        '${g == null ? 'none' : '${_rect(g.bounds)} scale=${g.scaleFactor} '
                  'primary=${g.isPrimary}'}',
      );
      expect(g, isNotNull, reason: 'screen ${s.id}');
      expect(g!.bounds.width, greaterThan(0));
      expect(g.scaleFactor, greaterThanOrEqualTo(1));
    }
    final primaries = screens.where((s) => s.geometry!.isPrimary).toList();
    expect(primaries, hasLength(1));
    expect(primaries.single.geometry!.bounds.topLeft, Offset.zero);

    final displays = PlatformDispatcher.instance.displays.toList();
    for (final d in displays) {
      _log(
        'flutter display id=${d.id} size=${d.size.width}x${d.size.height} '
        'dpr=${d.devicePixelRatio}',
      );
    }
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      // Flutter's macOS embedder reports each NSScreen by its
      // CGDirectDisplayID ("NSScreenNumber"): the screen source's ID.
      expect(displays, hasLength(screens.length));
      for (final s in screens) {
        final d = displays.singleWhere((d) => '${d.id}' == s.id);
        final g = s.geometry!;
        expect(g.scaleFactor, d.devicePixelRatio, reason: 'screen ${s.id}');
        expect(
          g.bounds.width * g.scaleFactor,
          moreOrLessEquals(d.size.width, epsilon: 1),
        );
        expect(
          g.bounds.height * g.scaleFactor,
          moreOrLessEquals(d.size.height, epsilon: 1),
        );
      }
    }

    // Windows.
    final withFrame = windows.where((w) => w.geometry != null).length;
    _log('$withFrame of ${windows.length} windows have a frame');
    for (final w in windows) {
      final g = w.geometry;
      _log(
        'window id=${w.id} name="${w.name}" '
        '${g == null ? 'none' : '${_rect(g.bounds)} scale=${g.scaleFactor}'}',
      );
    }
    if (windows.isEmpty) {
      _log('no windows listed: is Screen Recording allowed?');
      return;
    }
    expect(withFrame, windows.length, reason: 'listed windows exist');

    final view = tester.view;
    final viewSize = view.physicalSize / view.devicePixelRatio;
    _log('this app\'s view: ${viewSize.width}x${viewSize.height}');
    final own = windows.where((w) => w.name.contains(_appTitle)).toList();
    expect(own, isNotEmpty, reason: 'this app\'s window is listed');
    final ownWindow = own.firstWhere(
      (w) =>
          (w.geometry!.bounds.width - viewSize.width).abs() <= 1 &&
          w.geometry!.bounds.height >= viewSize.height,
      orElse: () => own.first,
    );
    final ownFrame = ownWindow.geometry!.bounds;
    expect(ownFrame.width, moreOrLessEquals(viewSize.width, epsilon: 1));
    final titleBar = ownFrame.height - viewSize.height;
    _log('own window id=${ownWindow.id}: title bar $titleBar');
    expect(titleBar, inInclusiveRange(0, 60));
    expect(ownWindow.geometry!.scaleFactor, view.devicePixelRatio);

    // Sharing it: sourceGeometry follows the window.
    final share = ScreenShareSource(
      geometryWatchInterval: const Duration(milliseconds: 200),
    );
    addTearDown(share.dispose);
    expect(await share.start(source: ownWindow), isTrue);
    final shared = await share.sourceGeometryChanges
        .firstWhere((g) => g != null)
        .timeout(const Duration(seconds: 5));
    _log('shared window: ${_rect(shared!.bounds)} scale=${shared.scaleFactor}');
    expect(shared.bounds, ownFrame);
    await share.stop();
    expect(share.sourceGeometry, isNull);
  }, skip: !_desktop);
}
