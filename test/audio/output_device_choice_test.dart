import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/output_device_choice.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for an `<audio>` element and its `sinkId`.
class _Element {
  _Element(this.name);

  final String name;
  String sinkId = '';

  @override
  String toString() => name;
}

/// Stands in for a browser's `DOMException`: its text starts with its
/// name, as a JS `DOMException`'s does.
class _DomError {
  _DomError(this.name);

  final String name;

  @override
  String toString() => '$name: refused';
}

/// Plays the browser: accepts `setSinkId` unless the device is refused
/// (Safari outside a user gesture), and records every call.
class _Browser {
  final Set<String> refused = {};
  final Set<_Element> failing = {};
  final List<String> calls = [];
  Object error = _DomError('NotAllowedError');

  Future<void> setSinkId(_Element element, String deviceId) async {
    calls.add('$element:$deviceId');
    if (refused.contains(deviceId) || failing.contains(element)) {
      throw error;
    }
    element.sinkId = deviceId;
  }
}

Matcher _refused(AudioOutputFailure reason, String deviceId) => throwsA(
  isA<AudioOutputException>()
      .having((e) => e.reason, 'reason', reason)
      .having((e) => e.deviceId, 'deviceId', deviceId),
);

void main() {
  late _Browser browser;
  late OutputDeviceChoice<_Element> choice;
  late List<_Element> probes;

  _Element probe() {
    final element = _Element('probe${probes.length}');
    probes.add(element);
    return element;
  }

  setUp(() {
    browser = _Browser();
    choice = OutputDeviceChoice(browser.setSinkId);
    probes = [];
  });

  test('an accepted device moves every element and is kept', () async {
    final a = _Element('a'), b = _Element('b');
    await choice.choose('speaker-2', [a, b], probe: probe);
    expect(choice.deviceId, 'speaker-2');
    expect([a.sinkId, b.sinkId], ['speaker-2', 'speaker-2']);
    expect(probes, isEmpty, reason: 'elements exist: no probe');
  });

  test('a refused device is not kept and elements stay put', () async {
    final a = _Element('a'), b = _Element('b');
    await choice.choose('speaker-2', [a, b], probe: probe);
    browser.refused.add('speaker-3');

    await expectLater(
      choice.choose('speaker-3', [a, b], probe: probe),
      _refused(AudioOutputFailure.needsUserGesture, 'speaker-3'),
    );
    expect(choice.deviceId, 'speaker-2', reason: 'the previous choice stays');
    expect([a.sinkId, b.sinkId], ['speaker-2', 'speaker-2']);
  });

  test('a refusal before any choice leaves the default', () async {
    browser.refused.add('speaker-2');
    final a = _Element('a');
    await expectLater(
      choice.choose('speaker-2', [a], probe: probe),
      throwsA(isA<AudioOutputException>()),
    );
    expect(choice.deviceId, isNull);
    expect(a.sinkId, '');
  });

  test('elements the browser moved go back when another refused', () async {
    final a = _Element('a'), b = _Element('b');
    await choice.choose('speaker-2', [a, b], probe: probe);
    browser.failing.add(b);

    await expectLater(
      choice.choose('speaker-3', [a, b], probe: probe),
      throwsA(isA<AudioOutputException>()),
    );
    expect(choice.deviceId, 'speaker-2');
    expect(a.sinkId, 'speaker-2', reason: 'moved back');
    expect(b.sinkId, 'speaker-2', reason: 'never moved');
    expect(browser.calls.skip(2), [
      'a:speaker-3',
      'b:speaker-3',
      'a:speaker-2',
    ]);
  });

  test('with no elements, a probe checks the device now', () async {
    browser.refused.add('speaker-2');
    await expectLater(
      choice.choose('speaker-2', [], probe: probe),
      throwsA(isA<AudioOutputException>()),
    );
    expect(choice.deviceId, isNull, reason: 'later elements stay on default');
    expect(probes, hasLength(1));

    browser.refused.clear();
    await choice.choose('speaker-2', [], probe: probe);
    expect(choice.deviceId, 'speaker-2');
    expect(browser.calls, ['probe0:speaker-2', 'probe1:speaker-2']);
  });

  test('every element is asked synchronously, inside the gesture', () {
    final a = _Element('a'), b = _Element('b');
    // Not awaited: the calls must already have been made.
    final done = choice.choose('speaker-2', [a, b], probe: probe);
    expect(browser.calls, ['a:speaker-2', 'b:speaker-2']);
    return done;
  });

  test('a synchronous throw counts as a refusal', () async {
    final sync = OutputDeviceChoice<_Element>(
      (element, deviceId) => throw StateError('NotAllowedError'),
    );
    await expectLater(
      sync.choose('speaker-2', [_Element('a')], probe: probe),
      _refused(AudioOutputFailure.needsUserGesture, 'speaker-2'),
    );
    expect(sync.deviceId, isNull);
  });

  group('the reason comes from the browser\'s error name', () {
    for (final (name, reason) in [
      ('NotAllowedError', AudioOutputFailure.needsUserGesture),
      ('NotFoundError', AudioOutputFailure.notFound),
      ('SecurityError', AudioOutputFailure.other),
      ('AbortError', AudioOutputFailure.other),
    ]) {
      test('$name: ${reason.name}', () async {
        final a = _Element('a');
        await choice.choose('speaker-2', [a], probe: probe);
        final error = _DomError(name);
        browser
          ..error = error
          ..refused.add('speaker-3');

        final thrown = await choice
            .choose('speaker-3', [a], probe: probe)
            .then<Object?>((_) => null, onError: (Object e) => e);
        expect(
          thrown,
          isA<AudioOutputException>()
              .having((e) => e.reason, 'reason', reason)
              .having((e) => e.deviceId, 'deviceId', 'speaker-3')
              .having((e) => e.cause, 'cause', same(error)),
        );
        expect(choice.deviceId, 'speaker-2', reason: 'rolled back');
        expect(a.sinkId, 'speaker-2');
      });
    }
  });

  test('a non-DOMException refusal is other, with the error kept', () async {
    final error = Exception('boom');
    browser
      ..error = error
      ..refused.add('speaker-2');
    await expectLater(
      choice.choose('speaker-2', [_Element('a')], probe: probe),
      throwsA(
        isA<AudioOutputException>()
            .having((e) => e.reason, 'reason', AudioOutputFailure.other)
            .having((e) => e.cause, 'cause', same(error)),
      ),
    );
  });

  test(
    'failureOf reads the reason; if it throws, the reason is other',
    () async {
      browser.refused.add('speaker-2');
      final typed = OutputDeviceChoice<_Element>(
        browser.setSinkId,
        failureOf: (error) => AudioOutputFailure.notFound,
      );
      await expectLater(
        typed.choose('speaker-2', [_Element('a')], probe: probe),
        _refused(AudioOutputFailure.notFound, 'speaker-2'),
      );
      final broken = OutputDeviceChoice<_Element>(
        browser.setSinkId,
        failureOf: (error) => throw StateError('unreadable'),
      );
      await expectLater(
        broken.choose('speaker-2', [_Element('a')], probe: probe),
        _refused(AudioOutputFailure.other, 'speaker-2'),
      );
    },
  );

  test('the stack trace is the browser error\'s', () async {
    final sync = OutputDeviceChoice<_Element>(
      (element, deviceId) => _throwFromHere(),
    );
    try {
      await sync.choose('speaker-2', [_Element('a')], probe: probe);
      fail('not refused');
    } on AudioOutputException catch (_, stack) {
      expect(stack.toString(), contains('_throwFromHere'));
    }
  });
}

Never _throwFromHere() => throw StateError('NotAllowedError');
