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

  test('pushes known virtual camera apps down, cameras only', () {
    const broadcastCam = MediaDevice(
      deviceId: 'cam-nv',
      kind: MediaDeviceKind.videoInput,
      label: 'Camera (NVIDIA Broadcast)',
    );
    const obsbot = MediaDevice(
      deviceId: 'cam-obsbot',
      kind: MediaDeviceKind.videoInput,
      label: 'OBSBOT Tiny 2',
    );
    const obsbotVirtual = MediaDevice(
      deviceId: 'cam-obsbot-v',
      kind: MediaDeviceKind.videoInput,
      label: 'OBSBOT Virtual Camera',
    );
    // OBSBOT is a real webcam: "obs" alone mustn't sink it.
    expect(prioritizeDevices([broadcastCam, obsbot, obsbotVirtual]), [
      obsbot,
      broadcastCam,
      obsbotVirtual,
    ]);
    for (final label in [
      'Snap Camera',
      'XSplit VCam',
      'ManyCam Video Source',
      'mmhmm Camera',
    ]) {
      final app = MediaDevice(
        deviceId: 'cam-app',
        kind: MediaDeviceKind.videoInput,
        label: label,
      );
      expect(prioritizeDevices([app, cam1]), [cam1, app], reason: label);
    }
    // People choose NVIDIA Broadcast's noise-removal microphone on purpose.
    const broadcastMic = MediaDevice(
      deviceId: 'mic-nv',
      kind: MediaDeviceKind.audioInput,
      label: 'Microphone (NVIDIA Broadcast)',
    );
    expect(prioritizeDevices([broadcastMic, mic1]), [broadcastMic, mic1]);
  });

  test('switchCamera cycles past known virtual camera apps last', () {
    const broadcastCam = MediaDevice(
      deviceId: 'cam-nv',
      kind: MediaDeviceKind.videoInput,
      label: 'Camera (NVIDIA Broadcast)',
    );
    expect(nextCamera([broadcastCam, cam1, cam2], current: cam1), cam2);
    expect(nextCamera([broadcastCam, cam1, cam2], current: cam2), broadcastCam);
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

  group('system default', () {
    MediaDevice mic(String id, String label, {bool isDefault = false}) =>
        MediaDevice(
          deviceId: '{0.0.1.00000000}.{$id}',
          kind: MediaDeviceKind.audioInput,
          label: label,
          isDefault: isDefault,
        );

    // A Windows desktop with many inputs, in the order flutter_webrtc lists
    // them: Core Audio's enumeration order, by endpoint ID, which has
    // nothing to do with the user's choice.
    List<MediaDevice> windowsInputs({String? defaultId}) => [
      for (final (id, label) in const [
        ('0e1a', 'Headset Microphone (Arctis Pro Wireless Chat)'),
        (
          '1013',
          'SteelSeries Sonar - Microphone '
              '(SteelSeries Sonar Virtual Audio Device)',
        ),
        ('26fb', 'Microphone (Virtual Desktop Audio)'),
        ('ae45', 'OBSBOT Tiny2 Microphone (OBSBOT Tiny2 Audio)'),
        ('cd4b', 'Microphone (NVIDIA Broadcast)'),
        ('fab8', 'Microphone (Steam Streaming Microphone)'),
      ])
        mic(id, label, isDefault: id == defaultId),
    ];

    String labelOf(MediaDevice device) => device.label;

    test('without a default, the first listed real device wins (the '
        'checkpoint bug: not what the user chose)', () {
      expect(
        labelOf(prioritizeDevices(windowsInputs()).first),
        'Headset Microphone (Arctis Pro Wireless Chat)',
      );
    });

    test('the default comes first, even when it is virtual', () {
      final sorted = prioritizeDevices(windowsInputs(defaultId: '1013'));
      expect(sorted.map(labelOf), [
        'SteelSeries Sonar - Microphone '
            '(SteelSeries Sonar Virtual Audio Device)',
        'Headset Microphone (Arctis Pro Wireless Chat)',
        'OBSBOT Tiny2 Microphone (OBSBOT Tiny2 Audio)',
        'Microphone (NVIDIA Broadcast)',
        'Microphone (Steam Streaming Microphone)',
        'Microphone (Virtual Desktop Audio)',
      ]);
    });

    test('a real default in the middle of the list comes first', () {
      expect(
        labelOf(prioritizeDevices(windowsInputs(defaultId: 'cd4b')).first),
        'Microphone (NVIDIA Broadcast)',
      );
    });

    test('the preferred device beats the default', () {
      final inputs = windowsInputs(defaultId: '1013');
      expect(prioritizeDevices(inputs, preferred: inputs[3]).first, inputs[3]);
    });

    test('a default that failed goes last', () {
      final inputs = windowsInputs(defaultId: 'ae45');
      final sorted = prioritizeDevices(inputs, deprioritized: [inputs[3]]);
      expect(sorted.first, inputs[0]);
      expect(sorted.last, inputs[3]);
    });

    test("a browser's default entries keep their place; a default iPhone "
        'microphone still sinks', () {
      const defaultEntry = MediaDevice(
        deviceId: 'default',
        kind: MediaDeviceKind.audioInput,
        label: 'Default - SteelSeries Sonar - Microphone (Virtual Audio)',
        isDefault: true,
      );
      const communications = MediaDevice(
        deviceId: 'communications',
        kind: MediaDeviceKind.audioInput,
        label: 'Communications - Headset Microphone',
        isDefault: true,
      );
      expect(prioritizeDevices([mic1, defaultEntry, communications, mic2]), [
        defaultEntry,
        communications,
        mic1,
        mic2,
      ]);
      const iphoneDefault = MediaDevice(
        deviceId: 'default',
        kind: MediaDeviceKind.audioInput,
        label: 'Default - My iPhone Microphone',
        isDefault: true,
      );
      expect(prioritizeDevices([iphoneDefault, mic1]), [mic1, iphoneDefault]);
    });
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
