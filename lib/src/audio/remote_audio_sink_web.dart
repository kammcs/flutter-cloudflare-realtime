import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_webrtc/dart_webrtc.dart' show MediaStreamTrackWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;
import 'package:web/web.dart' as web;

import 'audio_output_exception.dart';
import 'output_device_choice.dart';
import 'remote_audio_sink.dart';

/// The sink for the web.
RemoteAudioSink createPlatformRemoteAudioSink(
  AudioBlockedListener onBlockedChanged,
) => WebRemoteAudioSink(onBlockedChanged);

/// Why the browser refused an output device, from the error `setSinkId`
/// rejected with: the `DOMException`'s `name`, or its text when the error
/// can't be read as one.
///
/// A rejected promise completes with the JS value itself, under JavaScript
/// and WebAssembly alike; under WebAssembly it has no Dart type, so the
/// check goes through `dart:js_interop`.
AudioOutputFailure webAudioOutputFailure(Object error) {
  // `is JSObject` means "a JS object" under dart2js, DDC and dart2wasm,
  // which is all this asks; `isA` then checks for a DOMException
  // (test/audio/web_audio_output_failure_test.dart runs it in a browser).
  // ignore: invalid_runtime_check_with_js_interop_types
  if (error is JSObject && error.isA<web.DOMException>()) {
    return audioOutputFailureForName((error as web.DOMException).name);
  }
  return audioOutputFailureFromText(error);
}

/// Plays each remote audio track in its own hidden `<audio>` element.
///
/// Browsers refuse `play()` (`NotAllowedError`) until the page has had a
/// user gesture, unless the site may autoplay (for example after the user
/// allowed the microphone). A refused element is remembered and reported
/// as blocked; [resume], called from a gesture, plays them all. Any later
/// successful `play()` means the page may play now, so the refused ones are
/// retried then too.
class WebRemoteAudioSink implements RemoteAudioSink {
  /// Creates the sink. [_onBlockedChanged] hears when playback becomes
  /// blocked or unblocked.
  WebRemoteAudioSink(this._onBlockedChanged);

  final AudioBlockedListener _onBlockedChanged;
  final Map<String, web.HTMLAudioElement> _elements = {};
  final Set<String> _refused = {};
  web.HTMLDivElement? _container;
  final OutputDeviceChoice<web.HTMLAudioElement> _output = OutputDeviceChoice(
    (element, deviceId) => element.setSinkId(deviceId).toDart,
    failureOf: webAudioOutputFailure,
  );
  bool _blocked = false;
  bool _disposed = false;

  @override
  void attach(String id, MediaStreamTrack track) {
    if (_disposed || track is! MediaStreamTrackWeb) return;
    final element = _elements[id] ??= _createElement();
    element.srcObject = web.MediaStream(
      <web.MediaStreamTrack>[track.jsTrack].toJS,
    );
    unawaited(_play(id, element));
  }

  @override
  void detach(String id) {
    final element = _elements.remove(id);
    _refused.remove(id);
    if (element != null) _release(element);
    // Nothing waits for a gesture any more.
    if (_refused.isEmpty) _setBlocked(false);
  }

  @override
  Future<bool> resume() async {
    if (_disposed) return true;
    // `play()` runs synchronously in each `_play` call, while the gesture
    // that called us is still current.
    await Future.wait([
      for (final MapEntry(key: id, value: element) in _elements.entries)
        if (element.paused || _refused.contains(id)) _play(id, element),
    ]);
    if (_refused.isEmpty) _setBlocked(false);
    return !_blocked;
  }

  @override
  bool get supportsOutputSelection => _canSetSinkId;

  static final bool _canSetSinkId = (web.HTMLAudioElement() as JSObject).has(
    'setSinkId',
  );

  @override
  Future<void> setOutputDevice(String deviceId) async {
    if (!supportsOutputSelection) {
      throw UnsupportedError(
        'This browser cannot choose the audio output (setSinkId).',
      );
    }
    // Kept only once the browser accepted it (see OutputDeviceChoice):
    // Safari refuses a non-default device outside a user gesture.
    final ids = _elements.keys.toSet();
    await _output.choose(deviceId, [
      for (final id in ids) _elements[id]!,
    ], probe: web.HTMLAudioElement.new);
    // Elements created while the browser answered started on the old one.
    // (By ID: JS objects don't compare reliably under WebAssembly.)
    for (final MapEntry(key: id, value: element) in _elements.entries) {
      if (!ids.contains(id)) _applySinkId(element);
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final element in _elements.values) {
      _release(element);
    }
    _elements.clear();
    _refused.clear();
    _container?.remove();
    _container = null;
    // No callback: the room is going away.
    _blocked = false;
  }

  web.HTMLAudioElement _createElement() {
    final element = web.HTMLAudioElement()
      ..autoplay = true
      // iOS Safari: play inline rather than in a fullscreen player.
      ..setAttribute('playsinline', '');
    _applySinkId(element);
    _containerElement.append(element);
    return element;
  }

  /// Puts [element] on the accepted output device, if one was chosen.
  void _applySinkId(web.HTMLAudioElement element) {
    final sinkId = _output.deviceId;
    if (sinkId == null || !_canSetSinkId) return;
    unawaited(
      element.setSinkId(sinkId).toDart.then<void>((_) {}, onError: (_) {}),
    );
  }

  web.HTMLDivElement get _containerElement {
    final existing = _container;
    if (existing != null) return existing;
    final container = web.HTMLDivElement()
      ..id = 'cloudflare-realtime-remote-audio';
    container.style.display = 'none';
    web.document.body?.append(container);
    return _container = container;
  }

  static void _release(web.HTMLAudioElement element) {
    element
      ..pause()
      ..srcObject = null
      ..remove();
  }

  Future<void> _play(String id, web.HTMLAudioElement element) async {
    try {
      await element.play().toDart;
    } catch (error) {
      if (_disposed || !identical(_elements[id], element)) return;
      // Only the autoplay policy counts; an `AbortError` means a new
      // source interrupted this start, and that one plays instead.
      if (error.toString().contains('NotAllowedError')) {
        _refused.add(id);
        _setBlocked(true);
      }
      return;
    }
    if (_disposed || !identical(_elements[id], element)) return;
    _refused.remove(id);
    if (_refused.isEmpty) {
      _setBlocked(false);
      return;
    }
    // The page may play now: start the ones refused earlier.
    for (final other in _refused.toList()) {
      final refused = _elements[other];
      if (refused != null) unawaited(_play(other, refused));
    }
  }

  void _setBlocked(bool blocked) {
    if (_blocked == blocked) return;
    _blocked = blocked;
    _onBlockedChanged(blocked);
  }
}
