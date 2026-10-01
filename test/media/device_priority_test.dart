import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/media/device_priority.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const virtualCam = MediaDevice(
  deviceId: 'cam-v',
  kind: MediaDeviceKind.videoInput,
  label: 'OBS Virtual Camera',
);
const iphoneMic = MediaDevice(
  deviceId: 'mic-i',
  kind: MediaDeviceKind.audioInput,
  label: 'My iPhone Microphone',
);

void main() {
  test('keeps the platform order by default', () {
    expect(prioritizeDevices([cam1, cam2]), [cam1, cam2]);
  });

  test('puts the preferred device first', () {
    expect(prioritizeDevices([cam1, cam2], preferred: cam2), [cam2, cam1]);
  });

  test('matches the preferred device by label when its ID changed', () {
    const renamed = MediaDevice(
      deviceId: 'new-id',
      kind: MediaDeviceKind.videoInput,
      label: 'USB Webcam',
    );
    expect(prioritizeDevices([cam1, renamed], preferred: cam2), [
      renamed,
      cam1,
    ]);
  });

  test('pushes virtual devices and the iPhone microphone down', () {
    expect(prioritizeDevices([virtualCam, cam1, cam2]), [
      cam1,
      cam2,
      virtualCam,
    ]);
    expect(prioritizeDevices([iphoneMic, mic1]), [mic1, iphoneMic]);
  });

  test('a preferred virtual device still wins', () {
    expect(prioritizeDevices([cam1, virtualCam], preferred: virtualCam), [
      virtualCam,
      cam1,
    ]);
  });

  test('puts deprioritized devices last', () {
    expect(prioritizeDevices([cam1, virtualCam, cam2], deprioritized: [cam1]), [
      cam2,
      virtualCam,
      cam1,
    ]);
  });

  test('the preferred device beats its own deprioritization', () {
    expect(
      prioritizeDevices([cam1, cam2], preferred: cam2, deprioritized: [cam2]),
      [cam2, cam1],
    );
  });

  group('facing', () {
    const back = MediaDevice(
      deviceId: '0',
      kind: MediaDeviceKind.videoInput,
      label: 'Camera 0, Facing back',
      facing: CameraFacing.environment,
    );
    const front = MediaDevice(
      deviceId: '1',
      kind: MediaDeviceKind.videoInput,
      label: 'Camera 1, Facing front',
      facing: CameraFacing.user,
    );
    const usb = MediaDevice(
      deviceId: 'usb',
      kind: MediaDeviceKind.videoInput,
      label: 'Logitech BRIO',
    );

    test('puts cameras facing the wanted way first, then unknown', () {
      expect(prioritizeDevices([back, usb, front], facing: CameraFacing.user), [
        front,
        usb,
        back,
      ]);
      expect(
        prioritizeDevices([front, usb, back], facing: CameraFacing.environment),
        [back, usb, front],
      );
    });

    test('keeps the platform order without facing or facing info', () {
      expect(prioritizeDevices([back, front]), [back, front]);
      expect(prioritizeDevices([cam1, cam2], facing: CameraFacing.user), [
        cam1,
        cam2,
      ]);
    });

    test('the preferred device still wins, and virtual cameras sink', () {
      expect(
        prioritizeDevices(
          [back, front],
          preferred: back,
          facing: CameraFacing.user,
        ),
        [back, front],
      );
      const virtualFront = MediaDevice(
        deviceId: 'v',
        kind: MediaDeviceKind.videoInput,
        label: 'Virtual Front Camera',
        facing: CameraFacing.user,
      );
      expect(
        prioritizeDevices([virtualFront, back], facing: CameraFacing.user),
        [back, virtualFront],
      );
    });

    group('nextCamera', () {
      test('flips front and back', () {
        expect(nextCamera([back, front], current: front), back);
        expect(nextCamera([back, front], current: back), front);
      });

      test('flips to the best camera facing the other way', () {
        const virtualBack = MediaDevice(
          deviceId: 'vb',
          kind: MediaDeviceKind.videoInput,
          label: 'Virtual Back Camera',
          facing: CameraFacing.environment,
        );
        expect(nextCamera([virtualBack, front, back], current: front), back);
      });

      test('cycles through cameras that do not say which way they face', () {
        expect(nextCamera([cam1, cam2, usb], current: cam1), cam2);
        expect(nextCamera([cam1, cam2, usb], current: usb), cam1);
      });

      test('cycles with virtual and failed cameras last', () {
        expect(nextCamera([cam1, virtualCam, cam2], current: cam1), cam2);
        expect(nextCamera([cam1, virtualCam, cam2], current: cam2), virtualCam);
        expect(
          nextCamera([cam1, cam2, usb], current: cam1, deprioritized: [cam2]),
          usb,
        );
      });

      test('cycles when no camera faces the other way', () {
        expect(nextCamera([front, usb], current: front), usb);
        expect(nextCamera([front, usb], current: usb), front);
      });

      test('picks the first other camera without a current one', () {
        expect(nextCamera([cam1, cam2]), cam1);
        expect(nextCamera([cam1, cam2], current: virtualCam), cam1);
      });

      test('returns null with no other usable camera', () {
        expect(nextCamera([cam1], current: cam1), isNull);
        expect(nextCamera(const []), isNull);
        const noId = MediaDevice(
          deviceId: '',
          kind: MediaDeviceKind.videoInput,
        );
        expect(nextCamera([cam1, noId], current: cam1), isNull);
      });
    });
  });
}
