import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/media/constraints.dart';
import 'package:cloudflare_realtime/src/media/device_priority.dart';
import 'package:cloudflare_realtime/src/media/flutter_webrtc_media_backend.dart';
import 'package:cloudflare_realtime/src/media/windows_audio_defaults.dart';
import 'package:flutter/foundation.dart';
import 'package:fake_async/fake_async.dart';
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
      // No facing reported.
      expect(
        mediaDeviceFromSource({
          'deviceId': 'B2',
          'kind': 'videoinput',
          'label': 'Integrated Webcam',
        })!.facing,
        isNull,
      );
    });

    test("ignores the Windows plugin's made-up facing; the label decides", () {
      // flutter_webrtc's C++ plugin says "front" for the second camera and
      // "back" for every other one.
      expect(
        mediaDeviceFromSource({
          'deviceId': 'W0',
          'kind': 'videoinput',
          'label': 'OBSBOT Tiny 2 StreamCamera',
          'facing': 'back',
        }, pluginFacing: false)!.facing,
        isNull,
      );
      expect(
        mediaDeviceFromSource({
          'deviceId': 'W1',
          'kind': 'videoinput',
          'label': 'OBSBOT Virtual Camera',
          'facing': 'front',
        }, pluginFacing: false)!.facing,
        isNull,
      );
      expect(
        mediaDeviceFromSource({
          'deviceId': 'W2',
          'kind': 'videoinput',
          'label': 'Microsoft Camera Rear',
          'facing': 'front',
        }, pluginFacing: false)!.facing,
        CameraFacing.environment,
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

  group('system defaults', () {
    test("marks Chromium's default and communications audio entries", () {
      for (final kind in ['audioinput', 'audiooutput']) {
        for (final id in ['default', 'communications']) {
          expect(
            mediaDeviceFromSource({
              'deviceId': id,
              'kind': kind,
              'label': 'Default - Headset',
            })!.isDefault,
            isTrue,
          );
        }
        expect(
          mediaDeviceFromSource({
            'deviceId': 'abc',
            'kind': kind,
            'label': 'Headset',
          })!.isDefault,
          isFalse,
        );
      }
      expect(
        mediaDeviceFromSource({
          'deviceId': 'default',
          'kind': 'videoinput',
        })!.isDefault,
        isFalse,
      );
    });

    test('markDefaultAudioDevices marks the default input and output', () {
      const input = '{0.0.1.00000000}.{b}';
      const output = '{0.0.0.00000000}.{b}';
      const devices = [
        MediaDevice(
          deviceId: '{0.0.1.00000000}.{a}',
          kind: MediaDeviceKind.audioInput,
        ),
        MediaDevice(deviceId: input, kind: MediaDeviceKind.audioInput),
        MediaDevice(
          deviceId: '{0.0.0.00000000}.{a}',
          kind: MediaDeviceKind.audioOutput,
        ),
        MediaDevice(deviceId: output, kind: MediaDeviceKind.audioOutput),
        // Same ID as the default input, but a camera: never marked.
        MediaDevice(deviceId: input, kind: MediaDeviceKind.videoInput),
      ];
      final marked = markDefaultAudioDevices(
        devices,
        input: input,
        output: output,
      );
      expect(marked.map((d) => d.isDefault), [false, true, false, true, false]);
      expect(marked.map((d) => d.deviceId), devices.map((d) => d.deviceId));

      // The default moved: the old one is unmarked.
      final moved = markDefaultAudioDevices(marked, input: devices[0].deviceId);
      expect(moved.map((d) => d.isDefault), [true, false, false, false, false]);
    });

    test('reads the defaults from Core Audio on Windows', () {
      final defaults = readWindowsDefaultAudioEndpoints();
      if (!Platform.isWindows) {
        expect(defaults, isNull);
        return;
      }
      // A machine without audio devices (a CI runner) has none.
      expect(defaults, isNotNull);
      final endpoint = RegExp(r'^\{0\.0\.[01]\.00000000\}\.\{[0-9a-f-]{36}\}$');
      if (defaults!.input case final input?) {
        expect(input, matches(endpoint));
        expect(input, startsWith('{0.0.1.'));
      }
      if (defaults.output case final output?) {
        expect(output, matches(endpoint));
        expect(output, startsWith('{0.0.0.'));
      }
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

  test('audioInputToSelect: Android and macOS, only a named microphone', () {
    const device = MediaDevice(
      deviceId: 'microphone-back',
      kind: MediaDeviceKind.audioInput,
      label: 'Built-in Microphone (back)',
    );
    // The plugins of both read the named microphone only to report it
    // back; without selectAudioInput they capture from the last selected
    // input (macOS: the system default, such as a silent loopback device).
    for (final platform in [MediaPlatform.android, MediaPlatform.macos]) {
      final mic = microphoneConstraints(
        const MicrophoneOptions(),
        platform: platform,
        device: device,
      );
      expect(
        audioInputToSelect(mic, platform),
        'microphone-back',
        reason: platform.name,
      );
    }
    for (final other in [
      MediaPlatform.ios,
      MediaPlatform.windows,
      MediaPlatform.linux,
      MediaPlatform.web,
    ]) {
      final mic = microphoneConstraints(
        const MicrophoneOptions(),
        platform: other,
        device: device,
      );
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

  group('getUserMedia selects the microphone first', () {
    // flutter_webrtc's native method channel.
    const channel = MethodChannel('FlutterWebRTC.Method');
    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'initialize') return null;
            calls.add(call);
            if (call.method == 'getUserMedia') {
              throw PlatformException(code: 'test', message: 'no capture');
            }
            return null;
          });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<List<String>> capture(TargetPlatform target) async {
      debugDefaultTargetPlatformOverride = target;
      const backend = FlutterWebrtcMediaBackend();
      final constraints = microphoneConstraints(
        const MicrophoneOptions(),
        platform: backend.platform,
        device: const MediaDevice(
          deviceId: 'mic-2',
          kind: MediaDeviceKind.audioInput,
          label: 'MacBook Pro Microphone',
        ),
      );
      await expectLater(backend.getUserMedia(constraints), throwsA(anything));
      return [
        for (final call in calls)
          call.method == 'selectAudioInput'
              ? 'selectAudioInput ${(call.arguments as Map)['deviceId']}'
              : call.method,
      ];
    }

    test('on macOS, whose plugin ignores the constraint', () async {
      // Found on a Mac whose default input is a silent loopback device:
      // the chosen microphone never reached the audio device module.
      expect(await capture(TargetPlatform.macOS), [
        'selectAudioInput mic-2',
        'getUserMedia',
      ]);
    });

    test('on Android', () async {
      expect(await capture(TargetPlatform.android), [
        'selectAudioInput mic-2',
        'getUserMedia',
      ]);
    });

    test('not on Windows or iOS', () async {
      expect(await capture(TargetPlatform.windows), ['getUserMedia']);
      calls.clear();
      expect(await capture(TargetPlatform.iOS), ['getUserMedia']);
    });
  });

  group('MacInputReselector', () {
    test('selects the input again after each delay', () {
      fakeAsync((async) {
        final selected = <String>[];
        MacInputReselector((id) async => selected.add(id)).selected('mic');
        async.elapse(const Duration(milliseconds: 999));
        expect(selected, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(selected, ['mic']);
        async.elapse(const Duration(seconds: 7));
        expect(selected, ['mic', 'mic', 'mic', 'mic']);
        async.elapse(const Duration(minutes: 1));
        expect(selected, hasLength(4));
      });
    });

    test('leaves the system default alone', () {
      fakeAsync((async) {
        final selected = <String>[];
        MacInputReselector((id) async => selected.add(id)).selected('default');
        async.elapse(const Duration(minutes: 1));
        expect(selected, isEmpty);
      });
    });

    test('a newer selection replaces the pending ones', () {
      fakeAsync((async) {
        final selected = <String>[];
        final reselector = MacInputReselector((id) async => selected.add(id))
          ..selected('a');
        async.elapse(const Duration(seconds: 1));
        reselector.selected('default');
        async.elapse(const Duration(minutes: 1));
        expect(selected, ['a']);
        reselector.selected('b');
        async.elapse(const Duration(minutes: 1));
        expect(selected, ['a', 'b', 'b', 'b', 'b']);
      });
    });

    test('waits until no description is being applied', () {
      fakeAsync((async) {
        final selected = <String>[];
        var idle = Completer<void>();
        final reselector = MacInputReselector(
          (id) async => selected.add(id),
          whenIdle: () => idle.future,
        )..selected('mic');
        async.elapse(const Duration(seconds: 3));
        expect(selected, isEmpty, reason: 'the module is busy');
        idle.complete();
        async.flushMicrotasks();
        expect(selected, ['mic', 'mic']);

        // A newer choice cancels the selections still waiting.
        idle = Completer<void>();
        reselector.selected('a');
        async.elapse(const Duration(seconds: 2));
        reselector.selected('default');
        idle.complete();
        async.elapse(const Duration(minutes: 1));
        expect(selected, ['mic', 'mic']);
      });
    });

    test('ignores a device that is gone', () {
      fakeAsync((async) {
        var calls = 0;
        MacInputReselector((id) async {
          calls++;
          throw PlatformException(code: 'selectAudioInputFailed');
        }).selected('unplugged');
        async.elapse(const Duration(minutes: 1)); // No unhandled error.
        expect(calls, 4);
      });
    });
  });
}
