import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'web_audio_element.dart';

export 'web_audio_element.dart';

/// The `<audio>` elements the package added for remote audio (one
/// container per room, each with the same ID).
List<WebAudioElement> remoteAudioElements() {
  final nodes = web.document.querySelectorAll(
    'div#cloudflare-realtime-remote-audio > audio',
  );
  return [
    for (var i = 0; i < nodes.length; i++)
      if (nodes.item(i) case final web.HTMLAudioElement element)
        (
          paused: element.paused,
          currentTime: element.currentTime,
          sinkId: element.sinkId,
          liveAudioTracks: _liveAudioTracks(element),
        ),
  ];
}

int _liveAudioTracks(web.HTMLAudioElement element) {
  final stream = element.srcObject;
  if (stream == null || !stream.isA<web.MediaStream>()) return 0;
  final tracks = (stream as web.MediaStream).getAudioTracks().toDart;
  return tracks.where((t) => t.readyState == 'live').length;
}
