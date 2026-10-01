import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/media/flutter_webrtc_media_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
}
