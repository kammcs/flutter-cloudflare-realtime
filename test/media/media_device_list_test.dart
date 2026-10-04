import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeMediaBackend backend;

  setUp(() => backend = FakeMediaBackend(devices: [cam1, mic1, speaker1]));
  tearDown(() => backend.close());

  test('enumerates when first used and splits by kind', () async {
    final list = MediaDeviceList(backend: backend);
    await pumpEventQueue();
    expect(backend.enumerateCalls, 0);
    expect(list.devices, isEmpty);
    await list.ready;
    expect(list.devices, [cam1, mic1, speaker1]);
    expect(list.devicesOfKind(MediaDeviceKind.videoInput), [cam1]);
    expect(list.audioInputs, [mic1]);
    expect(list.videoInputs, [cam1]);
    expect(list.audioOutputs, [speaker1]);
    expect(await list.audioInputsChanges.first, [mic1]);
    expect(await list.videoInputsChanges.first, [cam1]);
    expect(await list.audioOutputsChanges.first, [speaker1]);
    await list.dispose();
  });

  test('each use starts it, once', () async {
    for (final use in <String, Future<void> Function(MediaDeviceList)>{
      'ready': (l) => l.ready,
      'refresh': (l) => l.refresh(),
      'devices': (l) async => l.devices,
      'audioInputs': (l) async => l.audioInputs,
      'devicesChanges': (l) => l.devicesChanges.first,
      'videoInputsChanges': (l) => l.videoInputsChanges.first,
    }.entries) {
      backend.enumerateCalls = 0;
      final list = MediaDeviceList(backend: backend);
      await use.value(list);
      await list.ready;
      expect(backend.enumerateCalls, 1, reason: use.key);
      expect(list.devices, [cam1, mic1, speaker1], reason: use.key);
      await list.dispose();
    }
  });

  test('ignores device changes until used', () async {
    final list = MediaDeviceList(backend: backend);
    backend.setDevices([cam1, mic1, mic2, speaker1]);
    await pumpEventQueue();
    expect(backend.enumerateCalls, 0);
    await list.ready;
    expect(list.audioInputs, [mic1, mic2]);
    backend.setDevices([cam1, mic1, speaker1]);
    await pumpEventQueue();
    expect(backend.enumerateCalls, 2);
    expect(list.audioInputs, [mic1]);
    await list.dispose();
  });

  test('re-enumerates on devicechange and emits only real changes', () async {
    final list = MediaDeviceList(backend: backend);
    await list.ready;
    final all = <List<MediaDevice>>[];
    final cameras = <List<MediaDevice>>[];
    list.devicesChanges.listen(all.add);
    list.videoInputsChanges.listen(cameras.add);
    await pumpEventQueue();

    backend.setDevices([cam1, mic1, speaker1]); // Same list.
    await pumpEventQueue();
    backend.setDevices([cam1, mic1, mic2, speaker1]); // A new microphone.
    await pumpEventQueue();
    backend.setDevices([cam1, cam2, mic1, mic2, speaker1]);
    await pumpEventQueue();

    expect(all, hasLength(3));
    expect(cameras, [
      [cam1],
      [cam1, cam2],
    ]);
    await list.dispose();
  });

  test('coalesces bursts of devicechange events', () async {
    final list = MediaDeviceList(backend: backend);
    await list.ready;
    backend.enumerateCalls = 0;
    for (var i = 0; i < 5; i++) {
      backend.setDevices([cam1, cam2, mic1]);
    }
    await pumpEventQueue();
    expect(backend.enumerateCalls, 2);
    expect(list.devices, [cam1, cam2, mic1]);
    await list.dispose();
  });

  test('dispose stops watching and completes the stream', () async {
    final list = MediaDeviceList(backend: backend);
    final done = list.devicesChanges.drain<void>();
    await list.dispose();
    await done;
    backend.setDevices([cam2]);
    await pumpEventQueue();
    await list.refresh();
    expect(list.devices, isNot(contains(cam2)));
  });
}
