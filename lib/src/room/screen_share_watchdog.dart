part of 'room.dart';

/// Reports a local screen share whose capture delivers no frames
/// ([LocalScreenShareStalledEvent]; `docs/design.md` §10).
///
/// On macOS a missing Screen Recording permission doesn't make
/// `getDisplayMedia` fail: `flutter_webrtc` returns a live track and
/// ScreenCaptureKit fails to start in the background, so the share just
/// stays empty. The only signal left is the stats.
///
/// For each capture (each new track of the share: a start, an unmute, a
/// source switch) it polls the room's session every [interval] and looks
/// for frames: the video `media-source` of the track (`frames`,
/// `framesPerSecond`) or the publication's `outbound-rtp` (`framesEncoded`,
/// `framesSent`). Polls count towards the timeout only while the room is
/// connected (the encoder drops frames before the transport is up) and
/// only when a report for the track was found (a platform without these
/// stats never triggers it). The first frame ends the watch for that
/// capture; the timeout reports it once.
class _ScreenShareWatchdog {
  _ScreenShareWatchdog(
    this._room,
    this._publication,
    this._share, {
    required this.timeout,
  }) {
    _tracks = _share.track.listen(_onTrack);
  }

  final Room _room;
  final LocalMediaPublication _publication;
  final ScreenShareSource _share;

  /// How long without frames (while connected) before reporting.
  final Duration timeout;

  /// How often the stats are read.
  static const interval = Duration(seconds: 1);

  late final StreamSubscription<CapturedTrack?> _tracks;
  Timer? _timer;
  CapturedTrack? _watching;
  Duration _withoutFrames = Duration.zero;
  bool _polling = false;
  bool _disposed = false;

  void _onTrack(CapturedTrack? track) {
    if (identical(track?.track, _watching?.track)) return;
    _stopTimer();
    _watching = track;
    _withoutFrames = Duration.zero;
    if (track == null || _disposed) return;
    _timer = Timer.periodic(interval, (_) => _poll(track));
  }

  Future<void> _poll(CapturedTrack track) async {
    if (_polling || _disposed) return;
    if (_room._left || !_publication.isPublished) {
      dispose();
      return;
    }
    if (_room.currentConnectionState != RoomConnectionState.connected ||
        _room.isReconnecting) {
      return;
    }
    _polling = true;
    final bool? flowing;
    try {
      flowing = await _framesFlowing(track);
    } catch (_) {
      // getStats can fail briefly (renegotiation, a replaced session).
      return;
    } finally {
      _polling = false;
    }
    if (_disposed || !identical(track, _watching)) return;
    if (flowing ?? false) {
      _stopTimer();
      return;
    }
    if (flowing == null) return;
    _withoutFrames += interval;
    if (_withoutFrames < timeout) return;
    _stopTimer();
    _room._emit(LocalScreenShareStalledEvent(_publication, _stalledError()));
  }

  /// Whether the capture of [track] produced frames: `true` or `false`
  /// from the stats, or `null` when they have nothing on it.
  Future<bool?> _framesFlowing(CapturedTrack track) async {
    final trackId = track.track.id;
    final mid = _publication.publication.mid;
    var seen = false;
    for (final report in await _room._session.getStats()) {
      final values = report.values;
      final String name;
      if (report.type == 'media-source' &&
          trackId != null &&
          values['trackIdentifier'] == trackId) {
        name = 'media-source';
      } else if (report.type == 'outbound-rtp' &&
          mid != null &&
          values['mid'] == mid) {
        name = 'outbound-rtp';
      } else {
        continue;
      }
      seen = true;
      final counters = name == 'media-source'
          ? const ['frames', 'framesPerSecond']
          : const ['framesEncoded', 'framesSent'];
      for (final counter in counters) {
        final value = values[counter];
        final number = value is num ? value : num.tryParse('$value');
        if (number != null && number > 0) return true;
      }
    }
    return seen ? false : null;
  }

  MediaException _stalledError() {
    final seconds = timeout.inSeconds;
    if (_room._mediaBackend.platform == MediaPlatform.macos) {
      return ScreenCapturePermissionException(
        'The screen share sent no frames for $seconds s. On macOS this '
        'usually means the Screen Recording permission is missing (or the '
        'shared window is minimized).',
      );
    }
    return MediaCaptureException(
      'The screen share sent no frames for $seconds s (a minimized window, '
      'or a capture the OS blocked).',
    );
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopTimer();
    unawaited(_tracks.cancel());
  }
}
