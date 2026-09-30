import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

void main() {
  late FakeMediaBackend backend;

  setUp(() => backend = FakeMediaBackend(devices: [cam1, mic1, speaker1]));
  tearDown(() => backend.close());

  test('enumerates at creation and splits by kind', () async {
    final list = MediaDeviceList(backend: backend);
    expect(list.currentDevices, isEmpty);
    await list.ready;
    expect(list.currentDevices, [cam1, mic1, speaker1]);
    expect(list.currentDevicesOfKind(MediaDeviceKind.videoInput), [cam1]);
    expect(await list.audioInputs.first, [mic1]);
    expect(await list.videoInputs.first, [cam1]);
    expect(await list.audioOutputs.first, [speaker1]);
    await list.dispose();
  });

  test('re-enumerates on devicechange and emits only real changes', () async {
    final list = MediaDeviceList(backend: backend);
    await list.ready;
    final all = <List<MediaDevice>>[];
    final cameras = <List<MediaDevice>>[];
    list.devices.listen(all.add);
    list.videoInputs.listen(cameras.add);
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
    expect(list.currentDevices, [cam1, cam2, mic1]);
    await list.dispose();
  });

  test('dispose stops watching and completes the stream', () async {
    final list = MediaDeviceList(backend: backend);
    final done = list.devices.drain<void>();
    await list.dispose();
    await done;
    backend.setDevices([cam2]);
    await pumpEventQueue();
    await list.refresh();
    expect(list.currentDevices, isNot(contains(cam2)));
  });
}
