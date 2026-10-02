import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/main.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Lists fixed devices and desktop sources. Capture isn't exercised here:
/// rendering a captured track needs the native plugin.
class _ListingOnlyBackend implements MediaBackend {
  _ListingOnlyBackend(this.desktopCapturer);

  @override
  final DesktopCapturerBackend? desktopCapturer;

  @override
  ScreenCaptureServiceBackend? get screenCaptureService => null;

  @override
  MediaPlatform get platform => MediaPlatform.windows;

  @override
  Future<List<MediaDevice>> enumerateDevices() async => const [
    MediaDevice(
      deviceId: 'cam-1',
      kind: MediaDeviceKind.videoInput,
      label: 'Test Camera',
    ),
    MediaDevice(
      deviceId: 'mic-1',
      kind: MediaDeviceKind.audioInput,
      label: 'Test Microphone',
    ),
    MediaDevice(
      deviceId: 'spk-1',
      kind: MediaDeviceKind.audioOutput,
      label: 'Test Speakers',
    ),
  ];

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
  final _removed = StreamController<ScreenSource>.broadcast();

  @override
  Future<List<ScreenSource>> getSources({
    required Set<ScreenSourceType> types,
    ({int width, int height})? thumbnailSize,
  }) async => const [
    ScreenSource(id: 's1', name: 'Screen 1', type: ScreenSourceType.screen),
    ScreenSource(id: 'w1', name: 'Editor', type: ScreenSourceType.window),
  ];

  @override
  Future<bool> updateSources({required Set<ScreenSourceType> types}) async =>
      true;

  @override
  Stream<ScreenSource> get onAdded => const Stream.empty();

  @override
  Stream<ScreenSource> get onRemoved => _removed.stream;

  @override
  Stream<ScreenSource> get onNameChanged => const Stream.empty();

  @override
  Stream<ScreenSource> get onThumbnailChanged => const Stream.empty();
}

void main() {
  testWidgets('the local media page lists devices and screen sources', (
    tester,
  ) async {
    final desktop = _Desktop();
    await tester.pumpWidget(
      ExampleApp(
        hub: InMemorySignalingHub(),
        mediaBackend: _ListingOnlyBackend(desktop),
      ),
    );
    await tester.tap(find.byTooltip('Local media'));
    await tester.pumpAndSettle();

    expect(find.text('Local media'), findsOneWidget);
    final page = find.byType(Scrollable).first;
    expect(find.text('Test Camera'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Test Microphone'),
      200,
      scrollable: page,
    );
    expect(find.text('Test Microphone'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Test Speakers'),
      200,
      scrollable: page,
    );
    expect(find.text('Test Speakers'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Editor'), 200, scrollable: page);
    expect(find.text('Screen 1'), findsOneWidget);
    expect(find.text('Editor'), findsOneWidget);

    // A window closing disappears from the grid.
    desktop._removed.add(
      const ScreenSource(
        id: 'w1',
        name: 'Editor',
        type: ScreenSourceType.window,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Editor'), findsNothing);

    // Leaving the page disposes the picker and its re-scan timer.
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Join a room'), findsOneWidget);
  });
}
