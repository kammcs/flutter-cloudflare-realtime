part of 'room.dart';

/// Plays the room's pulled remote audio (`docs/design.md` §4.3, Remote
/// audio): every audio [RemoteTrackPublication] reports its current track
/// here, and the platform's [RemoteAudioSink] plays it. On native platforms
/// the sink does nothing; on the web it attaches each track to a hidden
/// `<audio>` element and reports the browser's autoplay policy.
class _RoomAudio {
  _RoomAudio() {
    _sink = createRemoteAudioSink(_onBlockedChanged);
  }

  late final RemoteAudioSink _sink;
  final StateStream<bool> blocked = StateStream(false, distinct: true);
  // The native track playing per publication ID, so a re-emitted track
  // isn't attached again.
  final Map<String, MediaStreamTrack> _playing = {};
  bool _disposed = false;

  /// [publication]'s pulled track is now [track] (or none).
  void trackChanged(
    RemoteTrackPublication publication,
    MediaStreamTrack? track,
  ) {
    if (_disposed || publication.kind != TrackKind.audio) return;
    final id = publication.id;
    if (track == null) {
      if (_playing.remove(id) != null) _sink.detach(id);
      return;
    }
    if (identical(_playing[id], track)) return;
    _playing[id] = track;
    _sink.attach(id, track);
  }

  Future<bool> start() {
    if (_disposed) return Future.value(!blocked.value);
    return _sink.resume();
  }

  bool get canSelectOutput => _sink.supportsOutputSelection;

  Future<void> setOutput(String deviceId) {
    if (!_sink.supportsOutputSelection) {
      throw UnsupportedError('This platform cannot choose the audio output.');
    }
    return _sink.setOutputDevice(deviceId);
  }

  void _onBlockedChanged(bool value) {
    if (_disposed || blocked.isClosed) return;
    blocked.set(value);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _playing.clear();
    try {
      _sink.dispose();
    } catch (_) {
      // Best effort.
    }
    if (!blocked.isClosed) blocked.set(false);
    await blocked.close();
  }
}
