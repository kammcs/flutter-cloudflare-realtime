import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack, createLocalMediaStream;

/// A track together with a [MediaStream] that holds it, ready for
/// `RTCVideoRenderer.srcObject` (renderers take streams, not tracks).
///
/// For a pulled remote track, the room creates [stream] and disposes it when
/// the track is replaced or unsubscribed. Don't stop [track] or dispose
/// [stream] yourself.
@immutable
final class RenderableTrack {
  /// Pairs [track] with the [stream] that holds it.
  const RenderableTrack({required this.track, required this.stream});

  /// The media track.
  final MediaStreamTrack track;

  /// A stream holding [track].
  final MediaStream stream;

  @override
  bool operator ==(Object other) =>
      other is RenderableTrack &&
      identical(other.track, track) &&
      identical(other.stream, stream);

  @override
  int get hashCode =>
      Object.hash(identityHashCode(track), identityHashCode(stream));

  @override
  String toString() => 'RenderableTrack(${track.kind}, id: ${track.id})';
}

/// Wraps a pulled [MediaStreamTrack] in a new [MediaStream].
///
/// The default, [wrapTrackInMediaStream], calls `flutter_webrtc`. Tests
/// substitute a fake, since plugins don't run under `flutter test`.
typedef MediaStreamWrapper =
    Future<MediaStream> Function(MediaStreamTrack track);

/// Creates a local [MediaStream] with `createLocalMediaStream` and adds
/// [track] to it.
///
/// The label is `local` on purpose: native `flutter_webrtc` uses it as the
/// stream's `ownerTag`, and renderers look up streams tagged `local` among
/// the local streams, where this one lives.
///
/// Disposing that stream later doesn't stop [track]: on native platforms
/// `streamDispose` only detaches the tracks it holds, and on the web it
/// does nothing.
Future<MediaStream> wrapTrackInMediaStream(MediaStreamTrack track) async {
  final stream = await createLocalMediaStream('local');
  await stream.addTrack(track);
  return stream;
}
