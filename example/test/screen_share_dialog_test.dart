import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/screen_share_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class _Backend implements MediaBackend {
  _Backend(this.platform, this.desktopCapturer);

  @override
  final MediaPlatform platform;

  @override
  final DesktopCapturerBackend? desktopCapturer;

  @override
  ScreenCaptureServiceBackend? get screenCaptureService => null;

  @override
  BroadcastExtensionBackend? get broadcastExtension => null;

  @override
  Future<List<MediaDevice>> enumerateDevices() async => const [];

  @override
  Stream<void> get deviceChanges => const Stream.empty();

  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) =>
      throw UnimplementedError();

  @override
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> constraints) =>
      throw UnimplementedError();
}

class _Desktop implements DesktopCapturerBackend {
  _Desktop(this.sources);

  final List<ScreenSource> sources;

  @override
  Future<List<ScreenSource>> getSources({
    required Set<ScreenSourceType> types,
    ({int width, int height})? thumbnailSize,
  }) async => sources;

  @override
  Future<bool> updateSources({required Set<ScreenSourceType> types}) async =>
      true;

  @override
  Stream<ScreenSource> get onAdded => const Stream.empty();

  @override
  Stream<ScreenSource> get onRemoved => const Stream.empty();

  @override
  Stream<ScreenSource> get onNameChanged => const Stream.empty();

  @override
  Stream<ScreenSource> get onThumbnailChanged => const Stream.empty();
}

const _screen = ScreenSource(
  id: 's1',
  name: 'Screen 1',
  type: ScreenSourceType.screen,
);
const _window = ScreenSource(
  id: 'w1',
  name: 'Editor',
  type: ScreenSourceType.window,
);

/// Opens the dialog and returns a future of what it pops.
Future<Future<ShareChoice?>> _open(
  WidgetTester tester,
  ScreenSourcePicker? picker, {
  bool canShareAudio = false,
}) async {
  late Future<ShareChoice?> result;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => result = showDialog<ShareChoice>(
            context: context,
            builder: (_) =>
                ScreenShareDialog(picker: picker, canShareAudio: canShareAudio),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return result;
}

void main() {
  testWidgets('picks a source with the content type and audio', (tester) async {
    final picker = ScreenSourcePicker(
      backend: _Backend(MediaPlatform.windows, _Desktop([_window, _screen])),
    );
    final result = await _open(tester, picker, canShareAudio: true);

    expect(find.text('Screen 1'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);
    expect(find.textContaining('permission'), findsNothing);

    await tester.tap(find.text('Motion'));
    await tester.tap(find.text('Share audio too'));
    await tester.pump();
    await tester.tap(find.text('Screen 1'));
    await tester.pumpAndSettle();

    final choice = (await result)!;
    expect(choice.source, _screen);
    expect(choice.content, ScreenContent.motion);
    expect(choice.encodings, ScreenSharePresets.motion);
    expect(choice.options.frameRate, 30);
    expect(choice.options.captureAudio, isTrue);
    unawaited(picker.dispose()); // Cancels its re-scan timer at once.
    await tester.pump();
  });

  testWidgets('defaults to text and one layer', (tester) async {
    final picker = ScreenSourcePicker(
      backend: _Backend(MediaPlatform.windows, _Desktop([_screen])),
    );
    final result = await _open(tester, picker);
    expect(find.text('Share audio too'), findsNothing);
    await tester.tap(find.text('Screen 1'));
    await tester.pumpAndSettle();

    final choice = (await result)!;
    expect(choice.encodings, ScreenSharePresets.detail);
    expect(choice.options, const ScreenShareOptions());
    unawaited(picker.dispose());
    await tester.pump();
  });

  testWidgets('shows the Screen Recording guidance on macOS', (tester) async {
    // No screens listed: the macOS symptom of a missing permission.
    final picker = ScreenSourcePicker(
      backend: _Backend(MediaPlatform.macos, _Desktop([_window])),
    );
    await _open(tester, picker);
    expect(find.textContaining('Screen Recording'), findsOneWidget);
    expect(find.textContaining('quit and reopen'), findsOneWidget);
    unawaited(picker.dispose());
    await tester.pump();
  });

  testWidgets('on the web, leaves the source to the browser', (tester) async {
    final result = await _open(tester, null, canShareAudio: true);
    expect(find.text('Your browser asks what to share next.'), findsOneWidget);
    await tester.tap(find.text('Choose…'));
    await tester.pumpAndSettle();
    final choice = (await result)!;
    expect(choice.source, isNull);
    expect(choice.content, ScreenContent.text);
  });
}
