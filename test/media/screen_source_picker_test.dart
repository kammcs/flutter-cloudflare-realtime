import 'dart:typed_data';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';
import 'tiff.dart';

/// A capturer that, like `flutter_webrtc` on macOS, announces each source
/// with its thumbnail (`onAdded`) while listing, and returns the list
/// without thumbnails.
class _AnnouncingCapturer extends FakeDesktopCapturer {
  _AnnouncingCapturer(super.sources, this.thumbnails);

  final Map<String, Uint8List> thumbnails;

  @override
  Future<List<ScreenSource>> getSources({
    required Set<ScreenSourceType> types,
    ({int width, int height})? thumbnailSize,
  }) async {
    for (final source in sources) {
      final thumbnail = thumbnails[source.id];
      if (thumbnail != null) added.add(source.copyWith(thumbnail: thumbnail));
    }
    return super.getSources(types: types, thumbnailSize: thumbnailSize);
  }
}

const screen1 = ScreenSource(
  id: 'screen-1',
  name: 'Screen 1',
  type: ScreenSourceType.screen,
);
const screen2 = ScreenSource(
  id: 'screen-2',
  name: 'Screen 2',
  type: ScreenSourceType.screen,
);
const editor = ScreenSource(
  id: 'window-1',
  name: 'Editor',
  type: ScreenSourceType.window,
);
const browser = ScreenSource(
  id: 'window-2',
  name: 'Browser',
  type: ScreenSourceType.window,
);

void main() {
  late FakeDesktopCapturer desktop;
  late FakeMediaBackend backend;
  late ScreenSourcePicker picker;

  setUp(() {
    // The platform lists a window before the screens; the picker puts
    // screens first.
    desktop = FakeDesktopCapturer([editor, screen1, screen2]);
    backend = FakeMediaBackend(desktop: desktop);
    picker = ScreenSourcePicker(backend: backend);
  });

  tearDown(() async {
    await picker.dispose();
    await backend.close();
  });

  test('lists screens first, then windows', () async {
    expect(picker.isSupported, isTrue);
    expect(picker.state.sources, isEmpty);
    await picker.start();

    final state = picker.state;
    expect(state.sources, [screen1, screen2, editor]);
    expect(state.screens, [screen1, screen2]);
    expect(state.windows, [editor]);
    expect(state.isLoading, isFalse);
    expect(state.error, isNull);
    expect(desktop.lastThumbnailSize, (width: 320, height: 180));
    // The first re-scan starts at once, for Windows' late thumbnails.
    expect(desktop.updateSourcesCalls, 1);
  });

  test('state replays and shows loading', () async {
    final states = <ScreenPickerState>[];
    picker.stateChanges.listen(states.add);
    await picker.start();
    await pumpEventQueue();
    expect(states.map((s) => (s.sources.length, s.isLoading)), [
      (0, false),
      (0, true),
      (3, false),
    ]);
    expect((await picker.stateChanges.first).sources, hasLength(3));
  });

  test('start is idempotent', () async {
    await Future.wait([picker.start(), picker.start()]);
    await picker.start();
    expect(desktop.getSourcesCalls, 1);
  });

  test('only lists the requested types', () async {
    await picker.dispose();
    picker = ScreenSourcePicker(
      backend: backend,
      types: const {ScreenSourceType.window},
    );
    await picker.start();
    expect(picker.state.sources, [editor]);
    desktop.added.add(
      const ScreenSource(
        id: 'screen-3',
        name: 'S3',
        type: ScreenSourceType.screen,
      ),
    );
    await pumpEventQueue();
    expect(picker.state.sources, [editor]);
    expect(picker.state.error, isNull);
  });

  group('live updates', () {
    setUp(() => picker.start());

    test('adds new sources, keeping screens first', () async {
      desktop.added.add(browser);
      desktop.added.add(
        const ScreenSource(
          id: 'screen-3',
          name: 'Screen 3',
          type: ScreenSourceType.screen,
        ),
      );
      desktop.added.add(browser); // Duplicate: ignored.
      await pumpEventQueue();
      expect(picker.state.sources.map((s) => s.id), [
        'screen-1',
        'screen-2',
        'screen-3',
        'window-1',
        'window-2',
      ]);
    });

    test('removes sources', () async {
      desktop.removed.add(editor);
      desktop.removed.add(browser); // Unknown: ignored.
      await pumpEventQueue();
      expect(picker.state.sources, [screen1, screen2]);
    });

    test('renames sources', () async {
      desktop.nameChanged.add(editor.copyWith(name: 'Editor - main.dart'));
      await pumpEventQueue();
      expect(picker.state.windows.single.name, 'Editor - main.dart');
    });

    test('updates thumbnails, keeping them across renames', () async {
      final thumbnail = Uint8List.fromList([1, 2, 3]);
      desktop.thumbnailChanged.add(screen2.copyWith(thumbnail: thumbnail));
      await pumpEventQueue();
      final updated = picker.state.screens.last;
      expect(updated.thumbnail, same(thumbnail));
      expect(updated.name, 'Screen 2');

      // A name event without a thumbnail doesn't clear it.
      desktop.nameChanged.add(screen2.copyWith(name: 'Display 2'));
      await pumpEventQueue();
      expect(picker.state.screens.last.thumbnail, same(thumbnail));
      expect(picker.state.screens.last.name, 'Display 2');
    });
  });

  test('re-scans every refreshInterval until disposed', () {
    fakeAsync((async) {
      final timed = ScreenSourcePicker(
        backend: backend,
        refreshInterval: const Duration(seconds: 3),
      );
      timed.start();
      async.flushMicrotasks();
      expect(desktop.updateSourcesCalls, 1);
      async.elapse(const Duration(seconds: 7));
      expect(desktop.updateSourcesCalls, 3);
      timed.dispose();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 30));
      expect(desktop.updateSourcesCalls, 3);
    });
  });

  group('listing failures (#1539, #1085)', () {
    test('a transient failure is retried at once', () async {
      desktop.getSourcesErrors.add(
        Exception('getDesktopSources return null, something wrong'),
      );
      await picker.start();
      expect(desktop.getSourcesCalls, 2);
      expect(picker.state.error, isNull);
      expect(picker.state.sources, hasLength(3));
    });

    test(
      'a persistent failure becomes a typed error; refresh retries',
      () async {
        desktop.getSourcesErrors.addAll(['Bad Arguments', 'Bad Arguments']);
        await picker.start();

        final error = picker.state.error!;
        expect(error, isA<ScreenSourcesException>());
        expect(error.noScreens, isFalse);
        expect(error.cause, 'Bad Arguments');
        expect(picker.state.isLoading, isFalse);
        expect(picker.state.sources, isEmpty);

        await picker.refresh();
        expect(picker.state.error, isNull);
        expect(picker.state.sources, hasLength(3));
      },
    );

    test('a failed refresh keeps the previous list', () async {
      await picker.start();
      desktop.getSourcesErrors.addAll(['boom', 'boom']);
      await picker.refresh();
      expect(picker.state.error, isNotNull);
      expect(picker.state.sources, hasLength(3));
    });

    test('a listing without screens is reported', () async {
      desktop.sources = [editor];
      await picker.start();
      final error = picker.state.error!;
      expect(error.noScreens, isTrue);
      expect(picker.state.sources, [editor]);
    });
  });

  test('is unsupported without a desktop capturer', () async {
    final web = ScreenSourcePicker(
      backend: FakeMediaBackend(platform: MediaPlatform.web),
    );
    expect(web.isSupported, isFalse);
    expect(web.start, throwsUnsupportedError);
    await web.dispose();
  });

  group('thumbnails', () {
    test('survive a new listing, which carries none', () async {
      await picker.start();
      final thumbnail = Uint8List.fromList([1, 2, 3]);
      desktop.thumbnailChanged.add(screen1.copyWith(thumbnail: thumbnail));
      await picker.refresh();
      expect(picker.state.screens.first.thumbnail, same(thumbnail));

      // A source that is no longer listed forgets its thumbnail.
      desktop.sources = [editor, screen2];
      await picker.refresh();
      desktop.sources = [editor, screen1, screen2];
      await picker.refresh();
      expect(picker.state.screens.first.thumbnail, isNull);
    });

    test('announced while listing are kept (macOS)', () async {
      final thumbnail = Uint8List.fromList([4, 5, 6]);
      final listing = _AnnouncingCapturer(
        [screen1, editor],
        {screen1.id: thumbnail},
      );
      final mac = ScreenSourcePicker(
        backend: FakeMediaBackend(
          platform: MediaPlatform.macos,
          desktop: listing,
        ),
      );
      await mac.start();
      expect(mac.state.screens.single.thumbnail, same(thumbnail));
      await mac.dispose();
    });

    test('an empty thumbnail reads as none', () async {
      await picker.start();
      desktop.thumbnailChanged.add(
        screen1.copyWith(thumbnail: Uint8List.fromList([7])),
      );
      desktop.thumbnailChanged.add(screen1.copyWith(thumbnail: Uint8List(0)));
      await pumpEventQueue();
      expect(picker.state.screens.first.thumbnail, isNull);
      expect(picker.state.permissionProblem, isNull, reason: 'Windows');
    });
  });

  group('macOS Screen Recording permission', () {
    late ScreenSourcePicker mac;

    setUp(() {
      backend.platform = MediaPlatform.macos;
      mac = ScreenSourcePicker(backend: backend);
    });

    tearDown(() => mac.dispose());

    test('is suspected when every screen thumbnail is blank', () async {
      await mac.start();
      expect(mac.state.permissionProblem, isNull, reason: 'unknown');

      desktop.thumbnailChanged.add(screen1.copyWith(thumbnail: Uint8List(0)));
      await pumpEventQueue();
      expect(mac.state.permissionProblem, isNull, reason: 'one left');

      final black = solidTiff(32, 18, rgb: (0, 0, 0));
      desktop.thumbnailChanged.add(screen2.copyWith(thumbnail: black));
      await pumpEventQueue();
      final problem = mac.state.permissionProblem!;
      expect(problem, isA<MediaPermissionDeniedException>());
      expect(problem.suspected, isTrue);
      expect(problem.platform, MediaPlatform.macos);
      expect(problem.guidance, contains('Screen Recording'));
      expect(problem.guidance, contains('quit and reopen'));
      // The black TIFF still shows (as a thumbnail); the empty one doesn't.
      expect(mac.state.screens.last.thumbnail, same(black));

      // A screen that shows something clears it.
      desktop.thumbnailChanged.add(
        screen1.copyWith(thumbnail: solidTiff(32, 18, rgb: (30, 90, 200))),
      );
      await pumpEventQueue();
      expect(mac.state.permissionProblem, isNull);
    });

    test('is suspected when no screen is listed', () async {
      desktop.sources = [editor];
      await mac.start();
      expect(mac.state.error!.noScreens, isTrue);
      expect(mac.state.permissionProblem, isNotNull);

      desktop.sources = [editor, screen1];
      await mac.refresh();
      expect(mac.state.permissionProblem, isNull);
    });

    test('is never reported on other platforms', () async {
      backend.platform = MediaPlatform.windows;
      desktop.sources = [editor];
      await picker.start();
      expect(picker.state.error!.noScreens, isTrue);
      expect(picker.state.permissionProblem, isNull);
    });
  });

  test('dispose stops listening and completes the state stream', () async {
    await picker.start();
    final done = picker.stateChanges.drain<void>();
    await picker.dispose();
    await done;
    desktop.added.add(browser);
    expect(desktop.added.hasListener, isFalse);
    expect(picker.start, throwsStateError);
  });
}
