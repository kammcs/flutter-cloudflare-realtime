import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:cloudflare_realtime_example/device_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

/// Lists two speakers; nothing is captured.
class _SpeakersBackend implements MediaBackend {
  @override
  Future<List<MediaDevice>> enumerateDevices() async => const [
    MediaDevice(
      deviceId: 'spk-1',
      kind: MediaDeviceKind.audioOutput,
      label: 'Desk Speakers',
      isDefault: true,
    ),
    MediaDevice(
      deviceId: 'spk-2',
      kind: MediaDeviceKind.audioOutput,
      label: 'Headset',
    ),
  ];

  @override
  Stream<void> get deviceChanges => const Stream.empty();

  @override
  MediaPlatform get platform => MediaPlatform.web;

  @override
  DesktopCapturerBackend? get desktopCapturer => null;

  @override
  ScreenCaptureServiceBackend? get screenCaptureService => null;

  @override
  BroadcastExtensionBackend? get broadcastExtension => null;

  @override
  Future<MediaStream> getUserMedia(Map<String, dynamic> constraints) =>
      throw UnimplementedError();

  @override
  Future<MediaStream> getDisplayMedia(Map<String, dynamic> constraints) =>
      throw UnimplementedError();
}

/// A room whose output switch fails with [refusal] (or succeeds, if null).
class _OutputRoom implements Room {
  _OutputRoom(this.refusal);

  AudioOutputFailure? refusal;
  final List<String> asked = [];

  @override
  Future<void> setAudioOutputDevice(String deviceId) async {
    asked.add(deviceId);
    final reason = refusal;
    if (reason != null) {
      throw AudioOutputException(reason, deviceId: deviceId);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _desk = 'Desk Speakers (system default)';

void main() {
  late MediaDeviceList devices;
  late ValueNotifier<String?> output;

  setUp(() {
    devices = MediaDeviceList(backend: _SpeakersBackend());
    output = ValueNotifier(null);
  });

  tearDown(() {
    devices.dispose();
    output.dispose();
  });

  Future<void> pump(WidgetTester tester, Room room) async {
    await tester.runAsync(() => devices.ready);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AudioOutputDropdown(
            room: room,
            devices: devices,
            output: output,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> chooseHeadset(WidgetTester tester) async {
    await tester.tap(find.text(_desk));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Headset').last);
    await tester.pumpAndSettle();
  }

  testWidgets('an accepted speaker stays chosen', (tester) async {
    final room = _OutputRoom(null);
    await pump(tester, room);
    await chooseHeadset(tester);

    expect(room.asked, ['spk-2']);
    expect(output.value, 'spk-2');
    expect(find.text('Headset'), findsOneWidget);
    expect(find.text(_desk), findsNothing);
  });

  testWidgets('a refused speaker snaps back and says why', (tester) async {
    final room = _OutputRoom(AudioOutputFailure.permissionDenied);
    await pump(tester, room);
    await chooseHeadset(tester);

    expect(room.asked, ['spk-2']);
    expect(output.value, isNull);
    expect(find.text(_desk), findsOneWidget, reason: 'snapped back');
    expect(find.text('Headset'), findsNothing);
    expect(
      find.text(refusalMessage(AudioOutputFailure.permissionDenied)),
      findsOneWidget,
    );
  });

  test('every reason has its own message', () {
    final messages = {
      for (final r in AudioOutputFailure.values) refusalMessage(r),
    };
    expect(messages, hasLength(AudioOutputFailure.values.length));
  });
}
