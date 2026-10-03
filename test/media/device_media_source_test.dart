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
      camera.trackChanges.listen(tracks.add);

      expect(await camera.enable(), isTrue);
      expect(camera.isEnabled, isTrue);
      final captured = camera.track!;
      expect(captured.device, cam1);
      expect(captured.track.kind, 'video');
      expect(camera.activeDevice, cam1);

      await camera.disable();
      expect(camera.isEnabled, isFalse);
      expect(camera.track, isNull);
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
      expect(mic.track!.device, mic1);
      await mic.dispose();
    });

    test('a microphone opens the system default, even a virtual one, and '
        'switches live to a chosen one', () async {
      const sonar = MediaDevice(
        deviceId: '{0.0.1.00000000}.{1013}',
        kind: MediaDeviceKind.audioInput,
        label: 'Sonar - Microphone (Sonar Virtual Audio Device)',
        isDefault: true,
      );
      final windows = FakeMediaBackend(devices: [mic1, mic2, sonar]);
      final mic = MicrophoneSource(backend: windows);
      await mic.startBroadcasting();
      final audio = windows.userMediaCalls.single['audio'] as Map;
      expect(audio['optional'], [
        {'sourceId': sonar.deviceId},
      ]);
      expect(mic.track!.device, sonar);
      expect(mic.activeDevice, sonar);

      final first = mic.track!;
      final broadcast = <CapturedTrack?>[];
      mic.broadcastTrackChanges.listen(broadcast.add);
      await mic.setPreferredDevice(mic2);
      expect(mic.track!.device, mic2);
      expect(mic.activeDevice, mic2);
      expect((first.track as FakeTrack).stopped, isTrue);
      await pumpEventQueue();
      // The new track replaces the old one with no gap (a publication's
      // sender gets replaceTrack, no renegotiation).
      expect(broadcast, [first, mic.track]);
      await mic.dispose();
      await windows.close();
    });

    test('the camera requests its preset', () async {
      final camera = CameraSource(
        backend: backend,
        options: const CameraOptions(preset: VideoPreset.h360),
      );
      await camera.enable();
      final video = backend.userMediaCalls.single['video'] as Map;
      expect(video['width'], 640);
      expect(video['height'], 360);
      expect(video['frameRate'], 30);
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
        expect(camera.track, isNull);
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
      expect(mic.broadcastTrack, mic.track);
      await mic.dispose();
    });

    test('keepCapture: muting keeps the track live', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.startBroadcasting();
      final captured = mic.track!;

      await mic.stopBroadcasting();
      expect(mic.isBroadcasting, isFalse);
      expect(mic.isEnabled, isTrue);
      expect(mic.broadcastTrack, isNull);
      expect(mic.track, captured);
      expect((captured.track as FakeTrack).stopped, isFalse);

      // Unmuting is instant: no new capture.
      await mic.startBroadcasting();
      expect(mic.broadcastTrack, captured);
      expect(backend.userMediaCalls, hasLength(1));
      await mic.dispose();
    });

    test('releaseCapture: muting releases the capture', () async {
      final camera = CameraSource(backend: backend);
      expect(camera.mutePolicy, MutePolicy.releaseCapture);
      await camera.startBroadcasting();
      final captured = camera.track!;

      await camera.stopBroadcasting();
      expect(camera.isEnabled, isFalse);
      expect(camera.track, isNull);
      expect((captured.track as FakeTrack).stopped, isTrue);

      await camera.startBroadcasting();
      expect(camera.broadcastTrack, isNot(captured));
      expect(backend.userMediaCalls, hasLength(2));
      await camera.dispose();
    });

    test('enabled but not broadcasting previews without sending', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(camera.track, isNotNull);
      expect(camera.broadcastTrack, isNull);
      await camera.dispose();
    });

    test('disable stops broadcasting', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.startBroadcasting();
      await mic.disable();
      expect(mic.isBroadcasting, isFalse);
      expect(mic.broadcastTrack, isNull);
      await mic.dispose();
    });
  });

  group('device fallback', () {
    test('an unplugged device is replaced by the next one', () async {
      final camera = CameraSource(backend: backend);
      final tracks = <CapturedTrack?>[];
      camera.trackChanges.listen(tracks.add);
      await camera.startBroadcasting();
      final first = camera.track!;
      expect(first.device, cam1);

      backend.setDevices([cam2, mic1]);
      await pumpEventQueue();

      final second = camera.track!;
      expect(second.device, cam2);
      expect(camera.activeDevice, cam2);
      expect(camera.broadcastTrack, second);
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
      expect(camera.track!.device, cam2);

      backend.setDevices([cam1]);
      await pumpEventQueue();
      expect(camera.track!.device, cam1);

      backend.setDevices([cam1, cam2]);
      await pumpEventQueue();
      expect(camera.track!.device, cam2);
      expect(backend.userMediaCalls, hasLength(3));
      await camera.dispose();
    });

    test('unrelated device changes do not restart capture', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      final captured = camera.track;

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

      expect(camera.track, captured);
      expect(backend.userMediaCalls, hasLength(1));
      await camera.dispose();
    });

    test('a failing device is skipped and tried last', () async {
      backend.failingDeviceIds.add('cam-1');
      final camera = CameraSource(backend: backend);
      expect(await camera.enable(), isTrue);
      expect(camera.track!.device, cam2);
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
      final first = camera.track!;

      backend.failingDeviceIds.add('cam-1'); // The device is dead now.
      (first.track as FakeTrack).endExternally();
      await pumpEventQueue();

      expect(camera.track!.device, cam2);
      expect((first.track as FakeTrack).stopped, isTrue);
      await camera.dispose();
    });

    test('uses the device the platform actually opened', () async {
      // Native Windows opens the first camera when the requested one is
      // missing; the track's settings tell the truth.
      backend.redirects['cam-2'] = 'cam-1';
      final camera = CameraSource(backend: backend, preferredDevice: cam2);
      await camera.enable();
      expect(camera.track!.device, cam1);
      expect(camera.activeDevice, cam1);
      await camera.dispose();
    });
  });

  group('device selection', () {
    test('lists devices of its kind', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.deviceList.ready;
      expect(mic.devices, [mic1, mic2]);
      expect(await mic.devicesChanges.first, [mic1, mic2]);
      expect(mic.activeDevice, mic1);
      await mic.dispose();
    });

    test('setPreferredDevice switches a running capture', () async {
      final mic = MicrophoneSource(backend: backend);
      await mic.startBroadcasting();
      final first = mic.track!;

      await mic.setPreferredDevice(mic2);
      expect(mic.preferredDevice, mic2);
      expect(mic.track!.device, mic2);
      expect(mic.broadcastTrack, mic.track);
      expect((first.track as FakeTrack).stopped, isTrue);
      await mic.dispose();
    });

    test('setPreferredDevice while disabled only changes the choice', () async {
      final camera = CameraSource(backend: backend);
      await camera.deviceList.ready;
      await camera.setPreferredDevice(cam2);
      expect(camera.activeDevice, cam2);
      expect(backend.userMediaCalls, isEmpty);
      await camera.enable();
      expect(camera.track!.device, cam2);
      await camera.dispose();
    });

    test('choosing a failed device gives it another chance', () async {
      backend.failingDeviceIds.add('cam-1');
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(camera.track!.device, cam2);

      backend.failingDeviceIds.clear();
      await camera.setPreferredDevice(cam1);
      expect(camera.track!.device, cam1);
      await camera.dispose();
    });

    test('setOptions captures again with the new options', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      final first = camera.track!;

      await camera.setOptions(const CameraOptions(preset: VideoPreset.h1080));
      final video = backend.userMediaCalls.last['video'] as Map;
      expect(video['width'], 1920);
      expect(camera.track, isNot(first));
      expect(camera.track!.device, cam1);
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
      expect(camera.devices, [cam1, cam2]);
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

  group('camera facing and switchCamera', () {
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

    setUp(() {
      // Android lists the back camera first.
      backend = FakeMediaBackend(
        platform: MediaPlatform.android,
        devices: [back, front, mic1],
      );
    });

    test('opens the front camera by default', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(camera.track!.device, front);
      expect(camera.facing, CameraFacing.user);
      await camera.dispose();
    });

    test('CameraOptions.facing picks the back camera; null keeps the '
        'platform order', () async {
      final camera = CameraSource(
        backend: backend,
        options: const CameraOptions(facing: CameraFacing.environment),
      );
      await camera.enable();
      expect(camera.track!.device, back);
      await camera.dispose();

      final unordered = CameraSource(
        backend: backend,
        options: const CameraOptions(facing: null),
      );
      await unordered.enable();
      expect(unordered.track!.device, back);
      await unordered.dispose();
    });

    test('changing the facing switches a running capture', () async {
      final camera = CameraSource(backend: backend);
      await camera.enable();
      await camera.setOptions(
        camera.options.copyWith(facing: CameraFacing.environment),
      );
      expect(camera.track!.device, back);
      await camera.dispose();
    });

    test('switchCamera flips front and back while capturing', () async {
      final camera = CameraSource(backend: backend);
      await camera.startBroadcasting();
      final first = camera.track!;

      expect(await camera.switchCamera(), back);
      expect(camera.track!.device, back);
      expect(camera.broadcastTrack, camera.track);
      expect(camera.preferredDevice, back);
      expect((first.track as FakeTrack).stopped, isTrue);

      expect(await camera.switchCamera(), front);
      expect(camera.track!.device, front);
      await camera.dispose();
    });

    test('switchCamera while disabled only changes the choice', () async {
      final camera = CameraSource(backend: backend);
      expect(await camera.switchCamera(), back);
      expect(backend.userMediaCalls, isEmpty);
      await camera.enable();
      expect(camera.track!.device, back);
      await camera.dispose();
    });

    test('switchCamera cycles through desktop cameras', () async {
      backend = FakeMediaBackend(devices: [cam1, cam2, mic1]);
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(camera.facing, isNull);
      expect(await camera.switchCamera(), cam2);
      expect(camera.track!.device, cam2);
      expect(await camera.switchCamera(), cam1);
      expect(camera.track!.device, cam1);
      await camera.dispose();
    });

    test('switchCamera does nothing with one camera', () async {
      backend = FakeMediaBackend(devices: [cam1]);
      final camera = CameraSource(backend: backend);
      await camera.enable();
      expect(await camera.switchCamera(), cam1);
      expect(backend.userMediaCalls, hasLength(1));
      expect(camera.preferredDevice, isNull);
      await camera.dispose();
    });

    test(
      'switchCamera before permission (web) flips the facing mode',
      () async {
        backend = FakeMediaBackend(
          platform: MediaPlatform.web,
          devices: const [
            MediaDevice(deviceId: '', kind: MediaDeviceKind.videoInput),
          ],
        );
        final camera = CameraSource(backend: backend);
        await camera.enable();
        expect(
          (backend.userMediaCalls.last['video'] as Map)['facingMode'],
          'user',
        );

        await camera.switchCamera();
        expect(camera.options.facing, CameraFacing.environment);
        expect(
          (backend.userMediaCalls.last['video'] as Map)['facingMode'],
          'environment',
        );
        await camera.dispose();
      },
    );
  });

  group('dispose', () {
    test('stops the track and completes every stream', () async {
      final camera = CameraSource(backend: backend);
      await camera.startBroadcasting();
      final captured = camera.track!;
      final done = Future.wait([
        camera.trackChanges.drain<void>(),
        camera.enabledChanges.drain<void>(),
        camera.broadcastTrackChanges.drain<void>(),
        camera.activeDeviceChanges.drain<void>(),
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
      expect(mic.track, isNotNull);
      await mic.dispose();
      await devices.refresh();
      expect(devices.devices, isNotEmpty);
      await devices.dispose();
    });
  });
}
