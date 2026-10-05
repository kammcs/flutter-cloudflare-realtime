import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/remote_audio_sink_native.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

/// `Helper.selectAudioOutput` on Windows, for an ID it doesn't know.
final _windowsNotFound = PlatformException(
  code: 'Bad Arguments',
  message: 'Not found device id: speaker-9',
);

void main() {
  test('an accepted device is selected', () async {
    final selected = <String>[];
    final sink = NativeRemoteAudioSink(
      selectOutput: (id) async => selected.add(id),
      listOutputs: () async => ['speaker-1'],
    );
    await sink.setOutputDevice('speaker-1');
    expect(selected, ['speaker-1']);
  });

  test('a refused device that is not listed is notFound', () async {
    final sink = NativeRemoteAudioSink(
      selectOutput: (id) async => throw _windowsNotFound,
      listOutputs: () async => ['speaker-1', 'speaker-2'],
    );
    await expectLater(
      sink.setOutputDevice('speaker-9'),
      throwsA(
        isA<AudioOutputException>()
            .having((e) => e.reason, 'reason', AudioOutputFailure.notFound)
            .having((e) => e.deviceId, 'deviceId', 'speaker-9')
            .having((e) => e.cause, 'cause', same(_windowsNotFound)),
      ),
    );
  });

  test('a refused device that is listed is other', () async {
    final error = PlatformException(
      code: 'selectAudioOutputFailed',
      message: 'Error: the route could not be overridden',
    );
    final sink = NativeRemoteAudioSink(
      selectOutput: (id) async => throw error,
      listOutputs: () async => ['Speaker', 'Receiver'],
    );
    await expectLater(
      sink.setOutputDevice('Receiver'),
      throwsA(
        isA<AudioOutputException>()
            .having((e) => e.reason, 'reason', AudioOutputFailure.other)
            .having((e) => e.cause, 'cause', same(error)),
      ),
    );
  });

  test('when the list fails too, the reason is other', () async {
    final sink = NativeRemoteAudioSink(
      selectOutput: (id) async => throw _windowsNotFound,
      listOutputs: () async => throw StateError('no devices'),
    );
    await expectLater(
      sink.setOutputDevice('speaker-9'),
      throwsA(
        isA<AudioOutputException>()
            .having((e) => e.reason, 'reason', AudioOutputFailure.other)
            .having((e) => e.cause, 'cause', same(_windowsNotFound)),
      ),
    );
  });

  test('any error is wrapped, a synchronous one too', () async {
    final sink = NativeRemoteAudioSink(
      selectOutput: (id) => throw ArgumentError('bad'),
      listOutputs: () async => const [],
    );
    await expectLater(
      sink.setOutputDevice('x'),
      throwsA(
        isA<AudioOutputException>()
            .having((e) => e.reason, 'reason', AudioOutputFailure.notFound)
            .having((e) => e.cause, 'cause', isArgumentError),
      ),
    );
  });

  test('toString names the reason, the device and the cause type', () {
    expect(
      const AudioOutputException(
        AudioOutputFailure.needsUserGesture,
        deviceId: 'speaker-2',
        cause: 'NotAllowedError: no gesture',
      ).toString(),
      'AudioOutputException(needsUserGesture, deviceId: speaker-2, '
      'cause: String)',
    );
    expect(
      const AudioOutputException(
        AudioOutputFailure.other,
        deviceId: 'x',
      ).toString(),
      'AudioOutputException(other, deviceId: x)',
    );
  });
}
