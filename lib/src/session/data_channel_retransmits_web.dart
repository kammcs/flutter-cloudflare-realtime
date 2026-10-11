import 'dart:js_interop';
import 'dart:js_interop_unsafe';

/// Runs [create], which must call the browser's
/// `RTCPeerConnection.createDataChannel` synchronously, so that a
/// [maxRetransmits] of 0 reaches the browser (`docs/design.md` §9).
///
/// `dart_webrtc` builds the browser's init dictionary itself and sets
/// `maxRetransmits` only when it is above 0, so an unreliable channel
/// (`maxRetransmits: 0`) would be retransmitted. Its connection keeps the
/// browser's `RTCPeerConnection` private, so for the length of [create]
/// this wraps the prototype's `createDataChannel` to add the missing key,
/// and puts the original back before returning. Dart is single-threaded,
/// so no other call can see the wrapper.
T withBrowserMaxRetransmits<T>(int? maxRetransmits, T Function() create) {
  if (maxRetransmits == null || maxRetransmits > 0) return create();
  final constructor = globalContext['RTCPeerConnection'];
  if (!constructor.isA<JSObject>()) return create();
  final prototype = (constructor! as JSObject)['prototype'];
  if (!prototype.isA<JSObject>()) return create();
  final methods = prototype! as JSObject;
  final method = methods['createDataChannel'];
  if (!method.isA<JSFunction>()) return create();
  final original = method! as JSFunction;

  JSAny? createDataChannel(JSObject self, JSAny? label, JSAny? init) {
    if (init.isA<JSObject>()) {
      final dictionary = init! as JSObject;
      if (!dictionary.has('maxRetransmits')) {
        dictionary['maxRetransmits'] = maxRetransmits.toJS;
      }
    }
    return original.callMethod<JSAny?>('call'.toJS, self, label, init);
  }

  methods['createDataChannel'] = createDataChannel.toJSCaptureThis;
  try {
    return create();
  } finally {
    methods['createDataChannel'] = original;
  }
}
