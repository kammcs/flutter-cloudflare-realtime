// Runs only in a browser: flutter test --platform chrome [--wasm]
// test/audio/web_audio_output_failure_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/output_device_choice.dart';
import 'package:cloudflare_realtime/src/audio/remote_audio_sink_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;

/// What `await promise.toDart` throws when the browser rejects with a
/// `DOMException` named [name], as `setSinkId` does.
Future<Object> _rejection(String name) async {
  final promise = (globalContext['Promise'] as JSObject)
      .callMethod<JSPromise<JSAny?>>(
        'reject'.toJS,
        web.DOMException('refused', name),
      );
  try {
    await promise.toDart;
  } catch (error) {
    return error;
  }
  fail('the promise was not rejected');
}

void main() {
  test('a DOMException is read by its name', () async {
    expect(
      webAudioOutputFailure(await _rejection('NotAllowedError')),
      AudioOutputFailure.needsUserGesture,
    );
    expect(
      webAudioOutputFailure(await _rejection('NotFoundError')),
      AudioOutputFailure.notFound,
    );
    expect(
      webAudioOutputFailure(await _rejection('SecurityError')),
      AudioOutputFailure.permissionDenied,
    );
    expect(
      webAudioOutputFailure(await _rejection('AbortError')),
      AudioOutputFailure.other,
    );
  });

  test('the name wins over the text', () async {
    // The text alone would say NotAllowedError: the DOMException was read.
    final promise = (globalContext['Promise'] as JSObject)
        .callMethod<JSPromise<JSAny?>>(
          'reject'.toJS,
          web.DOMException('not a NotAllowedError', 'NotFoundError'),
        );
    final error = await promise.toDart.then<Object?>(
      (_) => null,
      onError: (Object e) => e,
    );
    expect(webAudioOutputFailure(error!), AudioOutputFailure.notFound);
  });

  test('a Dart error falls back to its text', () {
    expect(
      webAudioOutputFailure(StateError('NotAllowedError')),
      AudioOutputFailure.needsUserGesture,
    );
    expect(webAudioOutputFailure('boom'), AudioOutputFailure.other);
  });

  test('a refused setSinkId comes out as an AudioOutputException', () async {
    final choice = OutputDeviceChoice<web.HTMLAudioElement>(
      (element, deviceId) => element.setSinkId(deviceId).toDart,
      failureOf: webAudioOutputFailure,
    );
    final element = web.HTMLAudioElement();
    if (!(element as JSObject).has('setSinkId')) {
      markTestSkipped('this browser has no setSinkId');
      return;
    }
    // An unknown device. Headless Chrome, with no microphone permission,
    // rejects with `SecurityError` ("No permission to use requested
    // device"); with one, or in Firefox, it is `NotFoundError`.
    await expectLater(
      choice.choose('no-such-device', [element], probe: () => element),
      throwsA(
        isA<AudioOutputException>()
            .having((e) => e.deviceId, 'deviceId', 'no-such-device')
            .having((e) => e.cause, 'cause', isNotNull)
            .having(
              (e) => e.reason,
              'reason',
              isIn([
                AudioOutputFailure.permissionDenied,
                AudioOutputFailure.notFound,
              ]),
            ),
      ),
    );
    expect(choice.deviceId, isNull);
  });
}
