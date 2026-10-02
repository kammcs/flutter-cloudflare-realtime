import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/media/constraints.dart';
import 'package:cloudflare_realtime/src/media/device_priority.dart';
import 'package:cloudflare_realtime/src/media/flutter_webrtc_media_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('IosBroadcastExtension', () {
    const channel = MethodChannel(
      'dev.kammcs.cloudflare_realtime/screen_broadcast',
    );
    final calls = <MethodCall>[];
    Object? statusAnswer;

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return call.method == 'status' ? statusAnswer : null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('reads the setup problems and the running broadcast', () async {
      statusAnswer = {
        'problems': ['noAppGroupKey', 'extensionMissing', 'somethingNew'],
        'broadcasting': true,
      };
      final status = await const IosBroadcastExtension().status();
      expect(status.problems, [
        BroadcastSetupProblem.noAppGroupKey,
        BroadcastSetupProblem.extensionMissing,
      ]);
      expect(status.broadcasting, isTrue);
      expect(status.isReady, isFalse);

      statusAnswer = {'problems': <String>[], 'broadcasting': false};
      final ready = await const IosBroadcastExtension().status();
      expect(ready.isReady, isTrue);
      expect(ready.broadcasting, isFalse);
    });

    test('passes the settings to prepare', () async {
      await const IosBroadcastExtension().prepare(frameRate: 15, scale: 0.5);
      await const IosBroadcastExtension().abandon();
      expect(calls.map((c) => c.method), ['prepare', 'abandon']);
      expect(calls.first.arguments, {'frameRate': 15, 'scale': 0.5});
    });

    test('every problem code round-trips', () {
      for (final problem in BroadcastSetupProblem.values) {
        expect(BroadcastSetupProblem.fromCode(problem.name), problem);
        expect(problem.description, isNotEmpty);
      }
    });
  });

  group('mediaDeviceFromSource', () {
    test('reads the facing the native plugins report', () {
      // The Android plugin's entries.
      expect(
        mediaDeviceFromSource({
          'deviceId': '1',
          'kind': 'videoinput',
          'label': 'Camera 1, Facing front, Orientation 270',
          'groupId': 'camera',
          'facing': 'front',
        }),
        const MediaDevice(
          deviceId: '1',
          kind: MediaDeviceKind.videoInput,
          label: 'Camera 1, Facing front, Orientation 270',
          groupId: 'camera',
          facing: CameraFacing.user,
        ),
      );
      // Darwin: the label is localized, the position isn't.
      expect(
        mediaDeviceFromSource({
          'deviceId': 'com.apple.avfoundation.avcapturedevice.built-in_video:0',
          'kind': 'videoinput',
          'label': 'Rückkamera',
          'facing': 'back',
        })!.facing,
        CameraFacing.environment,
      );
    });

    test('leaves desktop cameras without a facing', () {
      // A Mac's built-in camera.
      expect(
        mediaDeviceFromSource({
          'deviceId': 'A1',
          'kind': 'videoinput',
          'label': 'FaceTime HD Camera',
          'facing': 'unspecified',
        })!.facing,
        isNull,
      );
      // Windows doesn't report one at all.
      expect(
        mediaDeviceFromSource({
          'deviceId': 'B2',
          'kind': 'videoinput',
          'label': 'Integrated Webcam',
        })!.facing,
        isNull,
      );
    });

    test('falls back to the label, and only for cameras', () {
      expect(
        mediaDeviceFromSource({
          'deviceId': 'x',
          'kind': 'videoinput',
          'label': 'camera2 0, facing back',
        })!.facing,
        CameraFacing.environment,
      );
      expect(
        mediaDeviceFromSource({
          'deviceId': 'm',
          'kind': 'audioinput',
          'label': 'Front Microphone',
        })!.facing,
        isNull,
      );
    });

    test('skips kinds the package does not use, tolerates missing fields', () {
      expect(mediaDeviceFromSource({'kind': 'midi'}), isNull);
      expect(
        mediaDeviceFromSource({'kind': 'audiooutput'}),
        const MediaDevice(deviceId: '', kind: MediaDeviceKind.audioOutput),
      );
    });
  });

  test('cameraFacingFromLabel reads common camera names', () {
    expect(cameraFacingFromLabel('Front Camera'), CameraFacing.user);
    expect(cameraFacingFromLabel('Front TrueDepth Camera'), CameraFacing.user);
    expect(cameraFacingFromLabel('camera2 1, facing front'), CameraFacing.user);
    expect(cameraFacingFromLabel('Back Camera'), CameraFacing.environment);
    expect(
      cameraFacingFromLabel('Back Ultra Wide Camera'),
      CameraFacing.environment,
    );
    expect(cameraFacingFromLabel('Rear camera'), CameraFacing.environment);
    expect(
      cameraFacingFromLabel('camera 0, facing environment'),
      CameraFacing.environment,
    );
    expect(cameraFacingFromLabel('FaceTime HD Camera'), isNull);
    expect(cameraFacingFromLabel('Logitech BRIO'), isNull);
    expect(cameraFacingFromLabel('Feedback Cam'), isNull);
    expect(cameraFacingFromLabel(''), isNull);
  });

  test('orderBuiltInCameras puts the plain iOS cameras first', () {
    MediaDevice cam(int n, String label, CameraFacing facing) => MediaDevice(
      deviceId: 'com.apple.avfoundation.avcapturedevice.built-in_video:$n',
      kind: MediaDeviceKind.videoInput,
      label: label,
      facing: facing,
    );
    const mic = MediaDevice(
      deviceId: 'mic',
      kind: MediaDeviceKind.audioInput,
      label: 'iPhone Microphone',
    );
    const back = CameraFacing.environment;
    // The order an iPhone on iOS 27 lists them in.
    final listed = [
      cam(7, 'Back Triple Camera', back),
      cam(3, 'Back Dual Camera', back),
      mic,
      cam(6, 'Back Dual Wide Camera', back),
      cam(0, 'Back Camera', back),
      cam(1, 'Front Camera', CameraFacing.user),
      cam(2, 'Back Telephoto Camera', back),
      cam(5, 'Back Ultra Wide Camera', back),
    ];
    final ordered = orderBuiltInCameras(listed);
    expect(
      [for (final d in ordered) d.label],
      [
        'Back Camera',
        'Front Camera',
        'iPhone Microphone',
        'Back Telephoto Camera',
        'Back Dual Camera',
        'Back Ultra Wide Camera',
        'Back Dual Wide Camera',
        'Back Triple Camera',
      ],
    );
    // So a flip from the front camera lands on the plain back camera.
    expect(
      nextCamera(
        ordered.where((d) => d.kind == MediaDeviceKind.videoInput).toList(),
        current: ordered[1],
      )!.label,
      'Back Camera',
    );
  });

  test('orderBuiltInCameras leaves other devices alone', () {
    const a = MediaDevice(
      deviceId: '47B4B64B-7067-4B9C-AD2B-AE273A71F4B5',
      kind: MediaDeviceKind.videoInput,
      label: 'FaceTime HD Camera',
    );
    const b = MediaDevice(
      deviceId: '0',
      kind: MediaDeviceKind.videoInput,
      label: 'Camera 0, Facing back',
    );
    expect(orderBuiltInCameras([a, b]), [a, b]);
  });

  test('audioInputToSelect: only Android, only a named microphone', () {
    final mic = microphoneConstraints(
      const MicrophoneOptions(),
      platform: MediaPlatform.android,
      device: const MediaDevice(
        deviceId: 'microphone-back',
        kind: MediaDeviceKind.audioInput,
        label: 'Built-in Microphone (back)',
      ),
    );
    expect(audioInputToSelect(mic, MediaPlatform.android), 'microphone-back');
    for (final other in [
      MediaPlatform.ios,
      MediaPlatform.macos,
      MediaPlatform.windows,
      MediaPlatform.web,
    ]) {
      expect(audioInputToSelect(mic, other), isNull, reason: other.name);
    }
    final anyMic = microphoneConstraints(
      const MicrophoneOptions(),
      platform: MediaPlatform.android,
    );
    expect(audioInputToSelect(anyMic, MediaPlatform.android), isNull);
    final camera = cameraConstraints(
      const CameraOptions(),
      platform: MediaPlatform.android,
      device: const MediaDevice(
        deviceId: '1',
        kind: MediaDeviceKind.videoInput,
      ),
    );
    expect(audioInputToSelect(camera, MediaPlatform.android), isNull);
  });
}
