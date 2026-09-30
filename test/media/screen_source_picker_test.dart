import 'dart:typed_data';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

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
    expect(picker.currentState.sources, isEmpty);
    await picker.start();

    final state = picker.currentState;
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
    picker.state.listen(states.add);
    await picker.start();
    await pumpEventQueue();
    expect(states.map((s) => (s.sources.length, s.isLoading)), [
      (0, false),
      (0, true),
      (3, false),
    ]);
    expect((await picker.state.first).sources, hasLength(3));
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
    expect(picker.currentState.sources, [editor]);
    desktop.added.add(
      const ScreenSource(
        id: 'screen-3',
        name: 'S3',
        type: ScreenSourceType.screen,
      ),
    );
    await pumpEventQueue();
    expect(picker.currentState.sources, [editor]);
    expect(picker.currentState.error, isNull);
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
      expect(picker.currentState.sources.map((s) => s.id), [
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
      expect(picker.currentState.sources, [screen1, screen2]);
    });

    test('renames sources', () async {
      desktop.nameChanged.add(editor.copyWith(name: 'Editor - main.dart'));
      await pumpEventQueue();
      expect(picker.currentState.windows.single.name, 'Editor - main.dart');
    });

    test('updates thumbnails, keeping them across renames', () async {
      final thumbnail = Uint8List.fromList([1, 2, 3]);
      desktop.thumbnailChanged.add(screen2.copyWith(thumbnail: thumbnail));
      await pumpEventQueue();
      final updated = picker.currentState.screens.last;
      expect(updated.thumbnail, same(thumbnail));
      expect(updated.name, 'Screen 2');

      // A name event without a thumbnail doesn't clear it.
      desktop.nameChanged.add(screen2.copyWith(name: 'Display 2'));
      await pumpEventQueue();
      expect(picker.currentState.screens.last.thumbnail, same(thumbnail));
      expect(picker.currentState.screens.last.name, 'Display 2');
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
      expect(picker.currentState.error, isNull);
      expect(picker.currentState.sources, hasLength(3));
    });

    test(
      'a persistent failure becomes a typed error; refresh retries',
      () async {
        desktop.getSourcesErrors.addAll(['Bad Arguments', 'Bad Arguments']);
        await picker.start();

        final error = picker.currentState.error!;
        expect(error, isA<ScreenSourcesException>());
        expect(error.noScreens, isFalse);
        expect(error.cause, 'Bad Arguments');
        expect(picker.currentState.isLoading, isFalse);
        expect(picker.currentState.sources, isEmpty);

        await picker.refresh();
        expect(picker.currentState.error, isNull);
        expect(picker.currentState.sources, hasLength(3));
      },
    );

    test('a failed refresh keeps the previous list', () async {
      await picker.start();
      desktop.getSourcesErrors.addAll(['boom', 'boom']);
      await picker.refresh();
      expect(picker.currentState.error, isNotNull);
      expect(picker.currentState.sources, hasLength(3));
    });

    test('a listing without screens is reported', () async {
      desktop.sources = [editor];
      await picker.start();
      final error = picker.currentState.error!;
      expect(error.noScreens, isTrue);
      expect(picker.currentState.sources, [editor]);
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

  test('dispose stops listening and completes the state stream', () async {
    await picker.start();
    final done = picker.state.drain<void>();
    await picker.dispose();
    await done;
    desktop.added.add(browser);
    expect(desktop.added.hasListener, isFalse);
    expect(picker.start, throwsStateError);
  });
}
