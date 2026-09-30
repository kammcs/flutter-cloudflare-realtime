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
}
