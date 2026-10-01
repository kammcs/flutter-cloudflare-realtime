import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/media/constraints.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  group('VideoPreset', () {
    test('h720 simulcast layers match h360 and h180', () {
      expect(VideoPreset.h720.scaledDownBy(1), (width: 1280, height: 720));
      expect(VideoPreset.h720.scaledDownBy(2), (
        width: VideoPreset.h360.width,
        height: VideoPreset.h360.height,
      ));
      expect(VideoPreset.h720.scaledDownBy(4), (
        width: VideoPreset.h180.width,
        height: VideoPreset.h180.height,
      ));
    });

    test('has value equality', () {
      expect(
        const VideoPreset(width: 1280, height: 720, frameRate: 30),
        VideoPreset.h720,
      );
      expect(VideoPreset.h720, isNot(VideoPreset.h1080));
    });
  });

  group('deviceSelector', () {
    test('web uses the W3C exact deviceId', () {
      expect(deviceSelector('x', MediaPlatform.web), {
        'deviceId': {'exact': 'x'},
      });
    });

    test('native platforms use optional sourceId', () {
      for (final platform in [
        MediaPlatform.windows,
        MediaPlatform.macos,
        MediaPlatform.linux,
        MediaPlatform.android,
        MediaPlatform.ios,
      ]) {
        expect(deviceSelector('x', platform), {
          'optional': [
            {'sourceId': 'x'},
          ],
        }, reason: platform.name);
      }
    });
  });

  test('camera constraints use bare targets and facing mode natively', () {
    // Darwin reads `ideal` only as a string and Android not at all; every
    // native platform reads a bare number.
    for (final platform in [
      MediaPlatform.windows,
      MediaPlatform.macos,
      MediaPlatform.linux,
      MediaPlatform.android,
      MediaPlatform.ios,
    ]) {
      expect(
        cameraConstraints(
          const CameraOptions(
            preset: VideoPreset.h540,
            facing: CameraFacing.environment,
          ),
          platform: platform,
        ),
        {
          'audio': false,
          'video': {
            'width': 960,
            'height': 540,
            'frameRate': 30,
            'facingMode': 'environment',
          },
        },
        reason: platform.name,
      );
    }
  });

  test('camera constraints use ideals in browsers', () {
    expect(
      cameraConstraints(
        const CameraOptions(facing: CameraFacing.user),
        platform: MediaPlatform.web,
      ),
      {
        'audio': false,
        'video': {
          'width': {'ideal': 1280},
          'height': {'ideal': 720},
          'frameRate': {'ideal': 30},
          'facingMode': 'user',
        },
      },
    );
  });

  test('a chosen device overrides the facing mode', () {
    final video =
        cameraConstraints(
              const CameraOptions(facing: CameraFacing.user),
              platform: MediaPlatform.ios,
              device: cam2,
            )['video']
            as Map;
    expect(video.containsKey('facingMode'), isFalse);
    expect(video['optional'], [
      {'sourceId': 'cam-2'},
    ]);
  });

  test('microphone constraints carry the processing flags', () {
    expect(
      microphoneConstraints(
        const MicrophoneOptions(autoGainControl: false),
        platform: MediaPlatform.web,
        device: mic2,
      ),
      {
        'video': false,
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': false,
          'deviceId': {'exact': 'mic-2'},
        },
      },
    );
  });

  test('desktop screen constraints follow the flutter_webrtc example', () {
    expect(
      desktopScreenConstraints(
        const ScreenShareOptions(captureAudio: true, showCursor: false),
        sourceId: '42',
      ),
      {
        'audio': true,
        'video': {
          'deviceId': {'exact': '42'},
          'mandatory': {'frameRate': 15.0},
          'cursor': 'never',
        },
      },
    );
  });

  test('web screen constraints leave the source to the browser', () {
    expect(
      webScreenConstraints(
        const ScreenShareOptions(frameRate: 5, showCursor: true),
      ),
      {
        'audio': false,
        'video': {
          'frameRate': {'ideal': 5},
          'cursor': 'always',
        },
      },
    );
  });

  test('options have value equality and copyWith', () {
    expect(
      const CameraOptions().copyWith(preset: VideoPreset.h360),
      const CameraOptions(preset: VideoPreset.h360),
    );
    expect(
      const MicrophoneOptions().copyWith(echoCancellation: false),
      const MicrophoneOptions(echoCancellation: false),
    );
    expect(
      const ScreenShareOptions().copyWith(frameRate: 15),
      const ScreenShareOptions(frameRate: 15),
    );
  });
}
