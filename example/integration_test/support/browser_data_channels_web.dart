import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Records the channels the browser's `RTCPeerConnection.createDataChannel`
/// creates, by wrapping it on the prototype until [stop].
class BrowserDataChannels {
  /// Starts recording.
  BrowserDataChannels() {
    final original = _prototype['createDataChannel']! as JSFunction;
    _original = original;
    JSAny? record(JSObject self, JSAny? label, JSAny? init) {
      final channel = original.callMethod<JSObject>(
        'call'.toJS,
        self,
        label,
        init,
      );
      _created.add(channel);
      return channel;
    }

    _prototype['createDataChannel'] = record.toJSCaptureThis;
  }

  static JSObject get _prototype =>
      (globalContext['RTCPeerConnection']! as JSObject)['prototype']!
          as JSObject;

  late final JSFunction _original;
  final List<JSObject> _created = [];

  /// The `maxRetransmits` of each browser channel labelled [label], in the
  /// order they were created.
  List<int?> maxRetransmitsOf(String label) => [
    for (final channel in _created)
      if ((channel['label']! as JSString).toDart == label)
        (channel['maxRetransmits'] as JSNumber?)?.toDartInt,
  ];

  /// Stops recording.
  void stop() => _prototype['createDataChannel'] = _original;
}
