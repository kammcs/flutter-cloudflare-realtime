part of 'room.dart';

// Publisher-side call quality (M12, docs/design.md §6.2 and §6.3): pausing
// the simulcast layers no one pulls, announcing the size the camera really
// captures, and the video codec.

/// How often a published simulcast video's captured size is checked, to
/// announce it again when it changes (a camera switch, a phone turned, a
/// window resized).
const Duration _captureSizeInterval = Duration(seconds: 3);

/// The codec a video publish with [codec] (or the room's
/// [RoomOptions.videoCodec]) is sent with, or `null` for the session
/// default. On Windows, H.264 is replaced by VP8 and reported
/// (flutter-webrtc #982).
VideoCodec? _effectiveVideoCodec(Room room, VideoCodec? codec) {
  final chosen = codec ?? room.options.videoCodec;
  if (chosen == VideoCodec.h264 &&
      room._mediaBackend.platform == MediaPlatform.windows) {
    room._emit(
      RoomErrorEvent(
        'videoCodec',
        UnsupportedError(
          'H.264 is not sent from Windows (flutter-webrtc #982); '
          'sending VP8 instead.',
        ),
      ),
    );
    return VideoCodec.vp8;
  }
  return chosen;
}

/// Pauses the simulcast layers of the local video that no one in the room
/// pulls, from the other participants' [ParticipantState.layerDemand]
/// (docs/design.md §6.2).
class _RoomLayerPausing {
  _RoomLayerPausing(this._room);

  final Room _room;
  List<ParticipantState> _others = const [];
  final Map<LocalMediaPublication, _Paused> _pausers = {};
  bool _disposed = false;
  bool _unsupportedReported = false;

  LayerPausingOptions get _options => _room.options.layerPausing;

  /// A local publication appeared.
  void add(LocalMediaPublication publication) {
    if (_disposed ||
        !_options.enabled ||
        publication.kind != TrackKind.video ||
        _pausers.containsKey(publication)) {
      return;
    }
    // flutter_webrtc's Windows and Linux plugin (its common C++) ignores
    // encoding changes in setParameters (it edits copies and reports
    // success), so a paused layer would keep sending while pausedLayers
    // said otherwise.
    final platform = _room._mediaBackend.platform;
    if (platform == MediaPlatform.windows || platform == MediaPlatform.linux) {
      if (!_unsupportedReported) {
        _unsupportedReported = true;
        _room._emit(
          RoomErrorEvent(
            'layerPausing',
            UnsupportedError(
              'Layer pausing does not work on Windows or Linux '
              '(flutter_webrtc ignores encoding changes there); every layer '
              'stays on.',
            ),
          ),
        );
      }
      return;
    }
    // The encodings as published: pausing only ever turns layers off that
    // these send.
    final base = publication.publication.sendEncodings;
    final pauser = LayerPauser(
      pauseDelay: _options.pauseDelay,
      apply: (paused) => _apply(publication, base, paused),
    );
    pauser.onChanged = () {
      if (!publication._pausedLayers.isClosed) {
        publication._pausedLayers.set(pauser.paused);
      }
    };
    _pausers[publication] = _Paused(pauser, base);
    evaluate(publication);
  }

  /// The publication was unpublished.
  void remove(LocalMediaPublication publication) {
    _pausers.remove(publication)?.pauser.dispose();
  }

  /// Signaling delivered the other participants' states.
  void onParticipants(List<ParticipantState> others) {
    if (_disposed) return;
    _others = others;
    for (final publication in _pausers.keys) {
      evaluate(publication);
    }
  }

  /// Recomputes which layers of [publication] to send.
  void evaluate(LocalMediaPublication publication) {
    final entry = _pausers[publication];
    if (entry == null || _disposed) return;
    final info = publication.simulcast;
    if (info == null || info.rids.length < 2) {
      entry.pauser.resumeAll();
      return;
    }
    // The layers the encoder sends: libwebrtc drops the lowest ones for a
    // small capture, and subscribers' ladders do the same (§6.1).
    final ladder =
        simulcastLadderFor(info)?.layers.map((l) => l.rid).toList() ??
        info.rids;
    final sent = {
      for (final e in entry.base)
        if (e.rid != null && e.active) e.rid!,
    };
    final pausable = [
      for (final rid in ladder)
        if (sent.contains(rid)) rid,
    ];
    final wishes = <String?>[];
    for (final other in _others) {
      if (other.sessionId == null) continue;
      final demand = other.layerDemand;
      if (demand == null) {
        wishes.add(null); // Doesn't report: wants every layer.
      } else if (demand[publication.trackName] case final rid?) {
        wishes.add(info.rids.contains(rid) ? rid : null);
      }
    }
    entry.pauser.update(
      layers: pausable.toSet(),
      send: layersToSend(
        ladder: pausable,
        wishes: wishes,
        allRids: info.rids,
        minActiveLayers: _options.minActiveLayers,
      ),
    );
  }

  Future<void> _apply(
    LocalMediaPublication publication,
    List<SendEncoding> base,
    Set<String> paused,
  ) async {
    if (publication._unpublished || _room._left) return;
    try {
      await publication.publication.setEncodings([
        for (final e in base)
          paused.contains(e.rid) ? e.copyWith(active: false) : e,
      ]);
    } catch (error) {
      if (!_room._left && !publication._unpublished) {
        _room._emit(RoomErrorEvent('layerPausing', error));
      }
      rethrow;
    }
  }

  void dispose() {
    _disposed = true;
    for (final entry in _pausers.values) {
      entry.pauser.dispose();
    }
    _pausers.clear();
  }
}

class _Paused {
  _Paused(this.pauser, this.base);

  final LayerPauser pauser;
  final List<SendEncoding> base;
}

/// Announces the size a published simulcast video really captures
/// (docs/design.md §6.3): the `media-source` report of its track in
/// `getStats()`, which follows rotation (a phone held upright captures
/// portrait), camera switches and constraint changes. Subscribers' layer
/// selection builds its ladder from that size (§6.1).
class _CaptureSizeWatcher {
  _CaptureSizeWatcher(this._room, this._publication);

  final Room _room;
  final LocalMediaPublication _publication;
  Timer? _timer;
  Timer? _soon;
  StreamSubscription<CapturedTrack?>? _tracks;
  bool _checking = false;
  bool _stopped = false;

  /// Checks now, every [_captureSizeInterval], and shortly after each new
  /// track from [tracks] (a camera switch, unmute).
  void start(Stream<CapturedTrack?> tracks) {
    unawaited(check());
    _timer = Timer.periodic(_captureSizeInterval, (_) => unawaited(check()));
    _tracks = tracks.listen((track) {
      if (track == null) return;
      _soon?.cancel();
      // Once the new track's frames reach the sender.
      _soon = Timer(const Duration(milliseconds: 700), () {
        _soon = null;
        unawaited(check());
      });
    }, onError: (Object _) {});
  }

  /// Reads the captured size now, and announces it if it changed.
  Future<void> check() async {
    if (_checking || _stopped || _room._left) return;
    final track = _publication.publication.track;
    final info = _publication._simulcast;
    if (track == null || info == null) return; // Muted: keep the last size.
    _checking = true;
    try {
      final size = await _capturedSize(track);
      if (size == null || _stopped || _room._left) return;
      final (width, height) = size;
      final current = _publication._simulcast;
      if (current == null ||
          (current.width == width && current.height == height)) {
        return;
      }
      _publication._simulcast = SimulcastInfo(
        rids: current.rids,
        width: width,
        height: height,
        scaleDownBy: current.scaleDownBy,
      );
      _room._pausing.evaluate(_publication);
      _publication.participant._changed();
    } finally {
      _checking = false;
    }
  }

  Future<(int, int)?> _capturedSize(MediaStreamTrack track) async {
    try {
      final reports = await _room._session.getStats();
      for (final report in reports) {
        if (report.type != 'media-source') continue;
        final values = report.values;
        if (values['kind'] != 'video' ||
            '${values['trackIdentifier']}' != track.id) {
          continue;
        }
        final size =
            _size(values['width'], values['height']) ??
            _fromLayers(reports, report.id);
        if (size != null) return size;
      }
    } catch (_) {
      // No stats now (a session being replaced): try again later.
    }
    // Browsers report the live capture in the track's settings; native
    // platforms report what was asked for, so only the web trusts them.
    if (kIsWeb) {
      final settings = track.getSettings();
      return _size(settings['width'], settings['height']);
    }
    return null;
  }

  /// The captured size from the encoded layers of the media source
  /// [sourceId], for a `media-source` report without a size (Windows:
  /// flutter_webrtc's capturer reports none, and its track settings are the
  /// requested size). The sending layer with the smallest scale, scaled
  /// back up; `null` while none sends a size, or when the CPU adaptation
  /// shrinks the encoder's input.
  (int, int)? _fromLayers(List<StatsReport> reports, String sourceId) {
    final info = _publication._simulcast;
    final scales = info?.scaleDownBy;
    if (info == null || scales == null) return null;
    (int, int)? best;
    var bestScale = double.infinity;
    for (final report in reports) {
      final values = report.values;
      if (report.type != 'outbound-rtp' ||
          values['mediaSourceId'] != sourceId ||
          values['active'] == false ||
          values['qualityLimitationReason'] == 'cpu') {
        continue;
      }
      final index = info.rids.indexOf('${values['rid']}');
      if (index < 0) continue;
      final scale = scales[index];
      final size = _size(values['frameWidth'], values['frameHeight']);
      if (size == null || scale >= bestScale) continue;
      bestScale = scale;
      best = ((size.$1 * scale).round(), (size.$2 * scale).round());
    }
    return best;
  }

  static (int, int)? _size(Object? width, Object? height) {
    int? read(Object? v) {
      final n = v is num ? v : num.tryParse('${v ?? ''}');
      return n == null || !n.isFinite || n <= 0 ? null : n.round();
    }

    final w = read(width);
    final h = read(height);
    return w == null || h == null ? null : (w, h);
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _soon?.cancel();
    _soon = null;
    unawaited(_tracks?.cancel());
    _tracks = null;
  }
}

/// The size [track] says it captures, from its settings, or `null`. Native
/// platforms report the requested size here (Android: landscape even when
/// it sends portrait); [_CaptureSizeWatcher] corrects it from the stats.
(int, int)? _settingsSize(MediaStreamTrack? track) {
  if (track == null) return null;
  try {
    final settings = track.getSettings();
    return _CaptureSizeWatcher._size(settings['width'], settings['height']);
  } catch (_) {
    return null;
  }
}
