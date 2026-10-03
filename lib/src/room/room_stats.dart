part of 'room.dart';

/// The room's typed stats and connection quality (`docs/design.md` §7.1).
///
/// One `getStats()` call on the current session every
/// [RoomStatsOptions.interval] feeds both:
///
/// - **Polling** runs while the room is joined and either someone listens
///   to [Room.statsChanges] (or a publication's `statsChanges`), or
///   connection quality is on ([RoomStatsOptions.connectionQuality], the
///   default). With quality off and no listener, nothing is polled. [Room.getStats] takes one
///   snapshot whenever asked. Polls never overlap, and a failed poll is
///   skipped (`getStats` can fail briefly during renegotiation).
/// - **Mapping** (see [CallStatsReader]): local tracks by their `mid` on
///   the current session (else the sent track's `media-source`); remote
///   tracks by the pull's `mid` (else the received track's ID), counting
///   only pulls on the current session.
/// - **Session replacement** (§8): [rebind] drops every counter, so no
///   rate mixes two peer connections.
/// - **Quality:** see [_rate].
class _RoomStats {
  _RoomStats(this._room) {
    // `clock` so tests can drive the intervals with fake time.
    final stopwatch = clock.stopwatch()..start();
    _elapsed = () => stopwatch.elapsed;
    _reader = CallStatsReader(elapsed: _elapsed, now: clock.now);
  }

  final Room _room;
  late final Duration Function() _elapsed;
  late final CallStatsReader _reader;

  final StateStream<RoomStats?> _latest = StateStream(null);

  /// The local participant's quality.
  final StateStream<ConnectionQuality> local = StateStream(
    ConnectionQuality.unknown,
    distinct: true,
  );
  QualityTracker? _localTracker;
  final Map<String, QualityTracker> _remoteTrackers = {};
  // When each remote participant's media last flowed (or became
  // measurable), on the stopwatch.
  final Map<String, Duration> _remoteLastFlow = {};
  Map<String, RemoteTrackStats> _previousRemote = const {};

  SfuSession? _bound;
  // Bumped by [rebind]: a poll that straddles it is not counted.
  int _generation = 0;
  int _listeners = 0;
  bool _started = false;
  bool _disposed = false;
  Timer? _timer;
  Future<RoomStats>? _inFlight;
  StreamSubscription<RoomConnectionState>? _stateListener;

  RoomStatsOptions get _options => _room.options.stats;
  ConnectionQualityOptions? get _quality => _options.connectionQuality;

  /// Whether the poll timer runs.
  bool get isPolling => _timer != null;

  /// The latest snapshot, if any.
  RoomStats? get latest => _latest.value;

  /// Every snapshot, replaying the latest; listening starts the polls.
  Stream<RoomStats> get stream => Stream<RoomStats>.multi((controller) {
    _listeners++;
    _update();
    final subscription = _latest.stream.listen((stats) {
      if (stats != null) controller.add(stats);
    }, onDone: controller.close);
    controller.onCancel = () {
      _listeners--;
      _update();
      return subscription.cancel();
    };
  }, isBroadcast: true);

  void start() {
    if (_room._left) return;
    _started = true;
    _stateListener = _room._state.stream.listen(_onRoomState);
    _update();
  }

  /// The room's session was replaced: start the counters afresh.
  void rebind() {
    _generation++;
    _bound = null;
    _reader.reset();
    _previousRemote = const {};
    _remoteLastFlow.clear();
  }

  /// Stops polling (at the start of [Room.leave]).
  void stop() {
    _started = false;
    _update();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    stop();
    final listener = _stateListener;
    _stateListener = null;
    unawaited(listener?.cancel());
    await _latest.close();
    await local.close();
  }

  /// One snapshot now (or the one being taken).
  Future<RoomStats> take() =>
      _inFlight ??= _take().whenComplete(() => _inFlight = null);

  void _update() {
    final run =
        _started &&
        !_room._left &&
        !_disposed &&
        (_listeners > 0 || _quality != null);
    if (run && _timer == null) {
      _timer = Timer.periodic(_options.interval, (_) => _tick());
      unawaited(_tick());
    } else if (!run && _timer != null) {
      _timer!.cancel();
      _timer = null;
    }
  }

  Future<void> _tick() async {
    if (_inFlight != null) return; // Polls never overlap.
    try {
      await take();
    } catch (_) {
      // Skip this one; see the class docs.
    }
  }

  Future<RoomStats> _take() async {
    final session = _room._session;
    if (!identical(session, _bound)) {
      rebind();
      _bound = session;
    }
    final generation = _generation;
    final local = _localRefs(session);
    final remote = _remoteRefs(session);
    final reports = await session.getStats();
    if (generation != _generation || _room._left || _disposed) {
      // The session changed meanwhile: don't let these counters be the
      // baseline of the new one.
      return CallStatsReader(
        elapsed: _elapsed,
        now: clock.now,
      ).read(reports, local: local, remote: remote);
    }
    final stats = _reader.read(reports, local: local, remote: remote);
    _latest.set(stats);
    _rate(stats);
    return stats;
  }

  List<LocalTrackRef> _localRefs(SfuSession session) => [
    for (final p in _room.localParticipant._publications)
      if (identical(p.publication.session, session))
        (
          trackName: p.trackName,
          kind: p.kind,
          source: p.source,
          mid: p.publication.mid,
          trackId: p.publication.track?.id,
        ),
  ];

  List<RemoteTrackRef> _remoteRefs(SfuSession session) => [
    for (final remote in _room._remotes.values)
      for (final publication in remote._publications.values)
        if (publication._subscription case final subscription?
            when identical(subscription.session, session))
          (
            id: publication.id,
            participantId: remote.participantId,
            trackName: publication.trackName,
            kind: publication.kind,
            source: publication.source,
            mid: subscription.mid,
            trackId: subscription.track?.id,
            rid: publication.currentRid,
          ),
  ];

  // ---------------------------------------------------------------------------
  // Connection quality
  // ---------------------------------------------------------------------------

  /// Rates every participant from [stats] (`docs/design.md` §7.1):
  ///
  /// - **Local:** the selected pair's RTT, the loss and audio jitter in the
  ///   SFU's receiver reports, and the sender's bandwidth
  ///   ([localQualitySample]). `lost` while the room is reconnecting or
  ///   disconnected ([_onRoomState]).
  /// - **Remote:** what we receive from them: loss, audio jitter, video
  ///   freezes ([remoteQualitySample]), over their pulled, unmuted tracks.
  ///   `lost` when none of those received anything for
  ///   [ConnectionQualityOptions.lostAfter] while they are in signaling.
  ///   With nothing pulled or everything muted, the level stays.
  /// - Each goes through a [QualityTracker] (hysteresis).
  void _rate(RoomStats stats) {
    final config = _quality;
    if (config == null) return;
    final state = _room.connectionState;
    if (state == RoomConnectionState.reconnecting ||
        state == RoomConnectionState.disconnected) {
      return; // [_onRoomState] has set lost/unknown.
    }
    final interval = stats.interval;
    if (interval != null) {
      final tracker = _localTracker ??= QualityTracker(config);
      _setLocal(
        tracker.add(
          rateQuality(localQualitySample(stats, config), config),
          interval,
        ),
      );
    }

    final now = _elapsed();
    for (final remote in _room._remotes.values) {
      final id = remote.participantId;
      final tracks = [
        for (final t in stats.remoteOf(id))
          if (!(remote._publications[t.trackName]?.isMuted ?? true)) t,
      ];
      if (tracks.isEmpty) {
        _remoteLastFlow.remove(id);
        continue;
      }
      final tracker = _remoteTrackers[id] ??= QualityTracker(config);
      final flowing = tracks.any((t) => (t.bitrate ?? 0) > 0);
      if (flowing) {
        _remoteLastFlow[id] = now;
      } else {
        final since = _remoteLastFlow.putIfAbsent(id, () => now);
        if (now - since >= config.lostAfter) {
          _setRemote(
            remote,
            tracker.add(ConnectionQuality.lost, interval ?? Duration.zero),
          );
          continue;
        }
      }
      if (interval == null) continue;
      _setRemote(
        remote,
        tracker.add(
          rateQuality(
            remoteQualitySample(tracks, _previousRemote, interval),
            config,
          ),
          interval,
        ),
      );
    }
    _previousRemote = stats.remote;
    _remoteTrackers.removeWhere((id, _) => !_room._remotes.containsKey(id));
    _remoteLastFlow.removeWhere((id, _) => !_room._remotes.containsKey(id));
  }

  /// While the room is reconnecting or disconnected, the local participant
  /// is `lost` and nobody else can be measured (`unknown`).
  void _onRoomState(RoomConnectionState state) {
    if (_quality == null || _room._left) return;
    if (state != RoomConnectionState.reconnecting &&
        state != RoomConnectionState.disconnected) {
      return;
    }
    _setLocal(
      (_localTracker ??= QualityTracker(_quality!)).set(ConnectionQuality.lost),
    );
    for (final remote in _room._remotes.values) {
      _remoteTrackers[remote.participantId]?.set(ConnectionQuality.unknown);
      _setRemote(remote, ConnectionQuality.unknown);
    }
    _remoteLastFlow.clear();
  }

  void _setLocal(ConnectionQuality quality) {
    if (local.isClosed || local.value == quality) return;
    local.set(quality);
    _room._emit(
      ParticipantConnectionQualityChangedEvent(_room.localParticipant, quality),
    );
  }

  void _setRemote(RemoteParticipant remote, ConnectionQuality quality) {
    final state = remote._quality;
    if (state.isClosed || state.value == quality) return;
    state.set(quality);
    _room._emit(ParticipantConnectionQualityChangedEvent(remote, quality));
  }
}
