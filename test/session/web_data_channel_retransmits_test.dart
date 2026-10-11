// Runs only in a browser: flutter test --platform chrome [--wasm]
// test/session/web_data_channel_retransmits_test.dart
@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:cloudflare_realtime/src/session/flutter_webrtc_peer_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// Records the browser channels `RTCPeerConnection.createDataChannel`
/// creates, by wrapping it on the prototype.
class _ChannelSpy {
  _ChannelSpy() {
    _prototype =
        (globalContext['RTCPeerConnection']! as JSObject)['prototype']!
            as JSObject;
    _original = _prototype['createDataChannel']! as JSFunction;
    JSAny? spy(JSObject self, JSAny? label, JSAny? init) {
      final channel = _original.callMethod<JSObject>(
        'call'.toJS,
        self,
        label,
        init,
      );
      created.add(channel);
      return channel;
    }

    installed = spy.toJSCaptureThis;
    _prototype['createDataChannel'] = installed;
  }

  late final JSObject _prototype;
  late final JSFunction _original;
  late final JSFunction installed;
  final List<JSObject> created = [];

  JSObject get last => created.last;

  bool get stillInstalled => (_prototype['createDataChannel']! as JSObject)
      .strictEquals(installed)
      .toDart;

  void restore() => _prototype['createDataChannel'] = _original;
}

int? _maxRetransmits(JSObject channel) =>
    (channel['maxRetransmits'] as JSNumber?)?.toDartInt;

void main() {
  late _ChannelSpy spy;

  setUp(() => spy = _ChannelSpy());
  tearDown(() => spy.restore());

  test(
    'an unreliable channel reaches the browser with maxRetransmits 0',
    () async {
      final pc = await createFlutterWebrtcPeerConnection({});
      addTearDown(pc.close);

      await pc.createDataChannel(
        'pointer',
        id: 3,
        ordered: false,
        maxRetransmits: 0,
      );
      expect(_maxRetransmits(spy.last), 0);
      expect((spy.last['ordered']! as JSBoolean).toDart, isFalse);

      await pc.createDataChannel('chat', id: 4);
      expect(_maxRetransmits(spy.last), isNull, reason: 'reliable');

      await pc.createDataChannel('few', id: 5, maxRetransmits: 2);
      expect(_maxRetransmits(spy.last), 2);

      expect(spy.stillInstalled, isTrue, reason: 'the original is put back');
    },
  );

  test('dart_webrtc on its own still drops maxRetransmits 0', () async {
    // When this fails, dart_webrtc passes 0 itself, and
    // withBrowserMaxRetransmits can go (docs/design.md §9).
    final pc = await webrtc.createPeerConnection({});
    addTearDown(pc.close);
    await pc.createDataChannel(
      'pointer',
      webrtc.RTCDataChannelInit()
        ..negotiated = true
        ..id = 3
        ..ordered = false
        ..maxRetransmits = 0,
    );
    expect(_maxRetransmits(spy.last), isNull);
  });
}
