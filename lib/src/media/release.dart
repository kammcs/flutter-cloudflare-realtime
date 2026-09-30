import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// Stops every track in [stream], then disposes the stream.
///
/// Clears each track's `onEnded` first, so a deliberate stop isn't mistaken
/// for the device or share ending. Errors are logged, not thrown: releasing
/// must always finish.
Future<void> releaseStream(MediaStream stream) async {
  for (final track in stream.getTracks()) {
    track.onEnded = null;
    try {
      await track.stop();
    } catch (error) {
      debugPrint('cloudflare_realtime: stopping a track failed: $error');
    }
  }
  try {
    await stream.dispose();
  } catch (error) {
    debugPrint('cloudflare_realtime: disposing a stream failed: $error');
  }
}
