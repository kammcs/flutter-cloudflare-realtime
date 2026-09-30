import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeMediaBackend backend;

  setUp(() {
    backend = FakeMediaBackend(devices: [cam1, cam2, mic1, mic2, speaker1]);
  });

  tearDown(() => backend.close());

  FakeStream streamOf(CapturedTrack? captured) =>
      captured!.stream as FakeStream;

  group('enable and disable', () {
    test('captures on enable and releases on disable', () async {
      final camera = CameraSource(backend: backend);
      final tracks = <CapturedTrack?>[];
      camera.track.listen(tracks.add);

      expect(await camera.enable(), isTrue);
      expect(camera.isEnabled, isTrue);
      final captured = camera.currentTrack!;
      expect(captured.device, cam1);
      expect(captured.track.kind, 'video');
      expect(camera.currentActiveDevice, cam1);

      await camera.disable();
      expect(camera.isEnabled, isFalse);
      expect(camera.currentTrack, isNull);
      expect((captured.track as FakeTrack).stopped, isTrue);
      expect(streamOf(captured).disposed, isTrue);

      await pumpEventQueue();
      expect(tracks, [null, captured, null]);
      await camera.dispose();
    });

    test('a microphone requests its processing options', () async {
      final mic = MicrophoneSource(
        backend: backend,
        options: const MicrophoneOptions(noiseSuppression: false),
      );
      await mic.enable();
      final audio = backend.userMediaCalls.single['audio'] as Map;
      expect(audio['echoCancellation'], isTrue);
      expect(audio['noiseSuppression'], isFalse);
      expect(audio['autoGainControl'], isTrue);
      expect(backend.userMediaCalls.single['video'], isFalse);
      expect(mic.currentTrack!.device, mic1);
      await mic.dispose();
    });

    test('the camera requests its preset', () async {
      final camera = CameraSource(
        backend: backend,
        options: const CameraOptions(preset: VideoPreset.h360),
      );
      await camera.enable();
      final video = backend.userMediaCalls.single['video'] as Map;
      expect(video['width'], {'ideal': 640});
      expect(video['height'], {'ideal': 360});
      expect(video['frameRate'], {'ideal': 30});
      expect(video['optional'], [
        {'sourceId': 'cam-1'},
      ]);
      await camera.dispose();
    });

    test('concurrent enable calls capture once', () async {
      final camera = CameraSource(backend: backend);
      await Future.wait([camera.enable(), camera.enable(), camera.enable()]);
      expect(backend.userMediaCalls, hasLength(1));
      await camera.dispose();
    });

    test(
      'disabling while capture is in flight releases the new track',
      () async {
        final camera = CameraSource(backend: backend);
        final enabling = camera.enable();
        final disabling = camera.disable();
        expect(await enabling, isFalse);
        await disabling;
        expect(camera.currentTrack, isNull);
        expect(backend.streams.every((s) => s.disposed), isTrue);
        await camera.dispose();
      },
    );
  });

  group('broadcasting and the mute policy', () {
    test('startBroadcasting enables; broadcastTrack follows', () async {
      final mic = MicrophoneSource(backend: backend);
      expect(mic.mutePolicy, MutePolicy.keepCapture);
      expect(await mic.startBroadcasting(), isTrue);
      expect(mic.isEnabled, isTrue);
      expect(mic.isBroadcasting, isTrue);
      expect(mic.currentBroadcastTrack, mic.currentTrack);
      await mic.dispose();
    });

    test('keepCapture: muting keeps the track live', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.startBroadcasting();
      final captured = mic.currentTrack!;

      await mic.stopBroadcasting();
      expect(mic.isBroadcasting, isFalse);
      expect(mic.isEnabled, isTrue);
      expect(mic.currentBroadcastTrack, isNull);
      expect(mic.currentTrack, captured);
      expect((captured.track as FakeTrack).stopped, isFalse);

      // Unmuting is instant: no new capture.
      await mic.startBroadcasting();
      expect(mic.currentBroadcastTrack, captured);
      expect(backend.userMediaCalls, hasLength(1));
      await mic.dispose();
    });

    test('releaseCapture: muting releases the capture', () async {
      final camera = CameraSource(backend: backend);
      expect(camera.mutePolicy, MutePolicy.releaseCapture);
      await camera.startBroadcasting();
      final captured = camera.currentTrack!;

      await camera.stopBroadcasting();
      expect(camera.isEnabled, isFalse);
      expect(camera.currentTrack, isNull);
      expect((captured.track as FakeTrack).stopped, isTrue);

      await camera.startBroadcasting();
      expect(camera.currentBroadcastTrack, isNot(captured));
      expect(backend.userMediaCalls, hasLength(2));
      await camera.dispose();
    });

    test('enabled but not broadcasting previews without sending', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(camera.currentTrack, isNotNull);
      expect(camera.currentBroadcastTrack, isNull);
      await camera.dispose();
    });

    test('disable stops broadcasting', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.startBroadcasting();
      await mic.disable();
      expect(mic.isBroadcasting, isFalse);
      expect(mic.currentBroadcastTrack, isNull);
      await mic.dispose();
    });
  });

  group('device fallback', () {
    test('an unplugged device is replaced by the next one', () async {
      final camera = CameraSource(backend: backend);
      final tracks = <CapturedTrack?>[];
      camera.track.listen(tracks.add);
      await camera.startBroadcasting();
      final first = camera.currentTrack!;
      expect(first.device, cam1);

      backend.setDevices([cam2, mic1]);
      await pumpEventQueue();

      final second = camera.currentTrack!;
      expect(second.device, cam2);
      expect(camera.currentActiveDevice, cam2);
      expect(camera.currentBroadcastTrack, second);
      expect((first.track as FakeTrack).stopped, isTrue);
      expect(camera.isEnabled, isTrue);
      // Listeners saw the replacement without re-subscribing, and never a
      // gap.
      expect(tracks, [null, first, second]);
      await camera.dispose();
    });

    test('returns to the preferred device when it comes back', () async {
      final camera = CameraSource(backend: backend, preferredDevice: cam2);
      await camera.enable();
      expect(camera.currentTrack!.device, cam2);

      backend.setDevices([cam1]);
      await pumpEventQueue();
      expect(camera.currentTrack!.device, cam1);

      backend.setDevices([cam1, cam2]);
      await pumpEventQueue();
      expect(camera.currentTrack!.device, cam2);
      expect(backend.userMediaCalls, hasLength(3));
      await camera.dispose();
    });

    test('unrelated device changes do not restart capture', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      final captured = camera.currentTrack;

      backend.setDevices([cam1, cam2, mic1]); // mic2 and speaker unplugged
      await pumpEventQueue();
      backend.setDevices([
        cam1,
        cam2,
        mic1,
        const MediaDevice(
          deviceId: 'cam-3',
          kind: MediaDeviceKind.videoInput,
          label: 'Another camera',
        ),
      ]);
      await pumpEventQueue();

      expect(camera.currentTrack, captured);
      expect(backend.userMediaCalls, hasLength(1));
      await camera.dispose();
    });

    test('a failing device is skipped and tried last', () async {
      backend.failingDeviceIds.add('cam-1');
      final camera = CameraSource(backend: backend);
      expect(await camera.enable(), isTrue);
      expect(camera.currentTrack!.device, cam2);
      expect(camera.devicePriority, [cam2, cam1]);
      await camera.dispose();
    });

    test(
      'when every device fails, reports DevicesExhaustedException',
      () async {
        backend.failingDeviceIds.addAll(['cam-1', 'cam-2']);
        final camera = CameraSource(backend: backend);
        final errors = <MediaException>[];
        camera.errors.listen(errors.add);

        expect(await camera.startBroadcasting(), isFalse);
        await pumpEventQueue();
        expect(camera.isEnabled, isFalse);
        expect(camera.isBroadcasting, isFalse);
        final error = errors.single as DevicesExhaustedException;
        expect(error.failures.map((f) => f.$1), [cam1, cam2]);
        await camera.dispose();
      },
    );

    test('a permission error stops the search at once', () async {
      backend.userMediaError =
          'Unable to getUserMedia: NotAllowedError: Permission denied';
      final mic = MicrophoneSource(backend: backend);
      final errors = <MediaException>[];
      mic.errors.listen(errors.add);

      expect(await mic.enable(), isFalse);
      await pumpEventQueue();
      expect(errors.single, isA<MediaPermissionDeniedException>());
      expect(backend.userMediaCalls, hasLength(1));
      await mic.dispose();
    });

    test('an ended track is captured again (web unplug)', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      final first = camera.currentTrack!;

      backend.failingDeviceIds.add('cam-1'); // The device is dead now.
      (first.track as FakeTrack).endExternally();
      await pumpEventQueue();

      expect(camera.currentTrack!.device, cam2);
      expect((first.track as FakeTrack).stopped, isTrue);
      await camera.dispose();
    });

    test('uses the device the platform actually opened', () async {
      // Native Windows opens the first camera when the requested one is
      // missing; the track's settings tell the truth.
      backend.redirects['cam-2'] = 'cam-1';
      final camera = CameraSource(backend: backend, preferredDevice: cam2);
      await camera.enable();
      expect(camera.currentTrack!.device, cam1);
      expect(camera.currentActiveDevice, cam1);
      await camera.dispose();
    });
  });

  group('device selection', () {
    test('lists devices of its kind', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.deviceList.ready;
      expect(mic.currentDevices, [mic1, mic2]);
      expect(await mic.devices.first, [mic1, mic2]);
      expect(mic.currentActiveDevice, mic1);
      await mic.dispose();
    });

    test('setPreferredDevice switches a running capture', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.startBroadcasting();
      final first = mic.currentTrack!;

      await mic.setPreferredDevice(mic2);
      expect(mic.currentPreferredDevice, mic2);
      expect(mic.currentTrack!.device, mic2);
      expect(mic.currentBroadcastTrack, mic.currentTrack);
      expect((first.track as FakeTrack).stopped, isTrue);
      await mic.dispose();
    });

    test('setPreferredDevice while disabled only changes the choice', () async {
      final camera = CameraSource(backend: backend);
      await camera.deviceList.ready;
      await camera.setPreferredDevice(cam2);
      expect(camera.currentActiveDevice, cam2);
      expect(backend.userMediaCalls, isEmpty);
      await camera.enable();
      expect(camera.currentTrack!.device, cam2);
      await camera.dispose();
    });

    test('choosing a failed device gives it another chance', () async {
      backend.failingDeviceIds.add('cam-1');
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(camera.currentTrack!.device, cam2);

      backend.failingDeviceIds.clear();
      await camera.setPreferredDevice(cam1);
      expect(camera.currentTrack!.device, cam1);
      await camera.dispose();
    });

    test('setOptions captures again with the new options', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      final first = camera.currentTrack!;

      await camera.setOptions(const CameraOptions(preset: VideoPreset.h1080));
      final video = backend.userMediaCalls.last['video'] as Map;
      expect(video['width'], {'ideal': 1920});
      expect(camera.currentTrack, isNot(first));
      expect(camera.currentTrack!.device, cam1);
      expect((first.track as FakeTrack).stopped, isTrue);
      await camera.dispose();
    });

    test('before permission (web): captures unconstrained, then '
        'refreshes the device list', () async {
      backend = FakeMediaBackend(
        platform: MediaPlatform.web,
        devices: const [
          MediaDevice(deviceId: '', kind: MediaDeviceKind.videoInput),
        ],
      );
      // Granting permission reveals the real devices, without a
      // devicechange event.
      backend.afterUserMedia = () => backend.setDevicesSilently([cam1, cam2]);
      final camera = CameraSource(backend: backend);

      expect(await camera.enable(), isTrue);
      final video = backend.userMediaCalls.single['video'] as Map;
      expect(video.containsKey('deviceId'), isFalse);

      await pumpEventQueue();
      expect(camera.currentDevices, [cam1, cam2]);
      // The running capture is kept.
      expect(backend.userMediaCalls, hasLength(1));
      await camera.dispose();
    });

    test('web uses deviceId exact', () async {
      backend.platform = MediaPlatform.web;
      final mic = MicrophoneSource(backend: backend);
      await mic.enable();
      final audio = backend.userMediaCalls.single['audio'] as Map;
      expect(audio['deviceId'], {'exact': 'mic-1'});
      expect(audio.containsKey('optional'), isFalse);
      await mic.dispose();
    });
  });

  group('dispose', () {
    test('stops the track and completes every stream', () async {
      final camera = CameraSource(backend: backend);
      await camera.startBroadcasting();
      final captured = camera.currentTrack!;
      final done = Future.wait([
        camera.track.drain<void>(),
        camera.enabled.drain<void>(),
        camera.broadcastTrack.drain<void>(),
        camera.activeDevice.drain<void>(),
        camera.errors.drain<void>(),
      ]);

      await camera.dispose();
      await done;
      expect((captured.track as FakeTrack).stopped, isTrue);
      expect(streamOf(captured).disposed, isTrue);
      expect(camera.isDisposed, isTrue);
      expect(() => camera.enable(), throwsStateError);
      expect(() => camera.setPreferredDevice(cam2), throwsStateError);
      await camera.dispose(); // Twice is fine.
    });

    test('a shared device list is left open', () async {
      final devices = MediaDeviceList(backend: backend);
      final camera = CameraSource(backend: backend, deviceList: devices);
      final mic = MicrophoneSource(backend: backend, deviceList: devices);
      await camera.dispose();
      await mic.enable();
      expect(mic.currentTrack, isNotNull);
      await mic.dispose();
      await devices.refresh();
      expect(devices.currentDevices, isNotEmpty);
      await devices.dispose();
    });
  });
}
