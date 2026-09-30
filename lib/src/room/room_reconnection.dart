part of 'room.dart';

/// Thrown inside a re-session attempt when the room was left: the attempt
/// stops without reporting an error.
class _Aborted implements Exception {
  const _Aborted();
}

/// Replaces a [Room]'s broken SFU session (`docs/design.md` §8).
///
/// [ReconnectTrigger] decides *when*, from the session's connection state
/// and failures, network changes and the app lifecycle. An **episode** then
/// runs attempts, spaced by [Backoff], until one succeeds or the backoff
/// gives up. Each attempt:
///
/// 1. connects a new session through the room's connector;
/// 2. makes it the room's session ([Room._replaceSession]) and closes the
///    old one quietly, so everything on it becomes interrupted and can move;
/// 3. republishes every local track (same `trackName`, same
///    `MediaStreamTrack`) and every published DataChannel;
/// 4. announces the new session ID through signaling, retrying with
///    backoff;
/// 5. pulls every wanted remote track, and every DataChannel subscription,
///    from the publishers' current sessions;
/// 6. waits for the new peer connection to connect, if anything was
///    negotiated on it (see [_whenConnected]).
///
/// Only one episode runs at a time. Triggers during an episode coalesce
/// into it: one about the attempt's own session makes that attempt count as
/// failed, and a network change or a return to the foreground cuts a
/// backoff wait short.
class _Reconnection {
  _Reconnection(this._room)
    : _options = _room.options.reconnect,
      _trigger = ReconnectTrigger(_room.options.reconnect.trigger) {
    _backoff = Backoff(_options.backoff, clock: () => _now);
  }

  final Room _room;
  final ReconnectOptions _options;
  final ReconnectTrigger _trigger;
  late final Backoff _backoff;
  // Monotonic time for the trigger and the backoff; `package:clock`, so
  // `fake_async` drives it in tests.
  final Stopwatch _clock = clock.stopwatch()..start();
  Timer? _checkTimer;
  Timer? _stableTimer;
  Future<bool>? _episode;
  bool _running = false;
  Completer<void>? _wake;
  bool _sleeping = false;
  bool _gaveUp = false;
  bool _disposed = false;
  // A trigger about the current attempt's session, fired while the attempt
  // ran: the attempt doesn't count as a success.
  ReconnectReason? _pending;

  Duration get _now => _clock.elapsed;

  /// Whether an episode is running.
  bool get isRunning => _running;

  /// The running episode, completing with whether it reconnected.
  Future<bool>? get episode => _running ? _episode : null;

  /// Whether the last episode gave up (until the next one starts).
  bool get gaveUp => _gaveUp;

  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------

  /// The current session's connection state changed.
  void sessionState(SfuConnectionState state) {
    final pcState = switch (state) {
      // Nothing negotiated: no connect timeout until something is.
      SfuConnectionState.initial => null,
      SfuConnectionState.connecting =>
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
      SfuConnectionState.connected =>
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      SfuConnectionState.disconnected =>
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
      // Reported by [sessionFailed], which knows the reason.
      SfuConnectionState.failed => null,
      SfuConnectionState.closed =>
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
    };
    if (pcState == null) return;
    _fire(_trigger.peerConnectionStateChanged(pcState, _now));
  }

  /// The current session failed.
  void sessionFailed(SfuSessionFailure failure) => _fire(switch (failure) {
    SfuSessionGone() => _trigger.sessionGone(_now),
    SfuPeerConnectionFailed() => _trigger.peerConnectionStateChanged(
      RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      _now,
    ),
  });

  /// The device's network changed.
  void networkChanged() {
    if (_disposed) return;
    if (_retryNow(ReconnectReason.networkChanged)) return;
    _fire(_trigger.networkChanged(_now));
  }

  /// The app's lifecycle state changed.
  void lifecycle(AppLifecycleState state) {
    if (_disposed) return;
    switch (state) {
      case AppLifecycleState.paused:
        _trigger.appPaused(_now);
      case AppLifecycleState.resumed:
        final reason = _trigger.appResumed(_now);
        if (_retryNow(ReconnectReason.resumedFromBackground)) return;
        _fire(reason);
      case _:
        break;
    }
  }

  /// A network change or a return to the foreground is a good moment to try
  /// again: cuts a backoff wait short, or restarts after giving up.
  /// Returns whether it did either.
  bool _retryNow(ReconnectReason reason) {
    if (_running) {
      if (!_sleeping) return false;
      _wakeUp();
      return true;
    }
    if (_gaveUp && _options.enabled && !_room._left) {
      _backoff.reset();
      _start(reason);
      return true;
    }
    return false;
  }

  /// [Room.reconnect].
  Future<bool> manual() {
    final running = episode;
    if (running != null) {
      if (_sleeping) _wakeUp();
      return running;
    }
    _backoff.reset();
    return _start(ReconnectReason.manual, immediate: true);
  }

  void _fire(ReconnectReason? reason) {
    _scheduleCheck();
    if (reason == null || _disposed || _room._left) return;
    if (_running) {
      // About the session the running attempt created (the trigger was
      // reset when it was bound): that attempt hasn't worked. Stop waiting
      // for it to connect, but never cut a backoff wait short for it.
      _pending ??= reason;
      if (!_sleeping) _wakeUp();
      return;
    }
    // After giving up, only the app, a network change or a return to the
    // foreground start again.
    if (!_options.enabled || _gaveUp) return;
    _start(reason);
  }

  /// Keeps a timer for the trigger's next deadline.
  void _scheduleCheck() {
    _checkTimer?.cancel();
    _checkTimer = null;
    final at = _trigger.nextCheckAt;
    if (at == null || _disposed) return;
    final delay = at - _now;
    _checkTimer = Timer(
      delay.isNegative ? Duration.zero : delay,
      () => _fire(_trigger.check(_now)),
    );
  }

  // ---------------------------------------------------------------------------
  // Episodes
  // ---------------------------------------------------------------------------

  Future<bool> _start(ReconnectReason reason, {bool immediate = false}) {
    _running = true;
    return _episode = _run(reason, immediate: immediate);
  }

  Future<bool> _run(ReconnectReason reason, {required bool immediate}) async {
    // [_running] is cleared synchronously when the episode ends, so session
    // events right after it drive the room's state again.
    try {
      return await _runEpisode(reason, immediate: immediate);
    } finally {
      _running = false;
    }
  }

  Future<bool> _runEpisode(
    ReconnectReason reason, {
    required bool immediate,
  }) async {
    final room = _room;
    final started = _now;
    _gaveUp = false;
    _stableTimer?.cancel();
    room._setState(RoomConnectionState.reconnecting);
    room._emit(RoomReconnectingEvent(reason));

    var attempts = 0;
    Object? lastError;
    while (true) {
      if (room._left) return false;
      final delay = _backoff.nextDelay();
      if (delay == null) {
        _giveUp(reason, attempts, lastError);
        return false;
      }
      if (!immediate || attempts > 0) {
        await _sleep(delay);
        if (room._left) return false;
      }
      attempts++;
      try {
        await _attempt();
      } on _Aborted {
        return false;
      } catch (error) {
        if (room._left) return false;
        lastError = error;
        room._emit(RoomErrorEvent('reconnect', error));
        // Deadlines about the failed session no longer matter.
        _trigger.reset();
        _scheduleCheck();
        continue;
      }
      if (room._left) return false;
      final pending = _pending;
      if (pending == null && room._session.isUsable) break;
      lastError = room._session.failure ?? pending;
    }

    room._holdAnnouncements = false;
    unawaited(room._announcer.run());
    room._setState(RoomConnectionState.connected);
    room._emit(
      RoomReconnectedEvent(
        reason: reason,
        duration: _now - started,
        attempts: attempts,
      ),
    );
    // Start the backoff over only once the new session has lasted.
    _stableTimer = Timer(_options.stablePeriod, _backoff.reset);
    // The trigger may have a deadline for the new session already.
    _scheduleCheck();
    return true;
  }

  void _giveUp(ReconnectReason reason, int attempts, Object? error) {
    final room = _room;
    _gaveUp = true;
    _backoff.reset();
    _trigger.reset();
    _scheduleCheck();
    room._holdAnnouncements = false;
    unawaited(room._announcer.run());
    room._setState(RoomConnectionState.disconnected);
    room._emit(
      RoomReconnectFailedEvent(
        reason: reason,
        attempts: attempts,
        error: error,
      ),
    );
  }

  /// One re-session. Throws if it failed; the episode then backs off and
  /// tries again.
  Future<void> _attempt() async {
    final room = _room;
    _pending = null;
    // Hold announcements until the new session carries our tracks, and let
    // one in flight finish so ours is the last word.
    room._holdAnnouncements = true;
    await room._announcer.run();

    // 1. A new session, while the old one (if it still works) carries on.
    final next = await room._connect(room._broker, room.options.sessionOptions);
    if (room._left) {
      await _closeQuietly(next);
      throw const _Aborted();
    }

    // 2. Switch. Closing the old session detaches everything on it, so it
    //    can move: a publication lives on one session at a time.
    _trigger.reset();
    _pending = null;
    final previous = room._replaceSession(next);
    await _closeQuietly(previous);
    _checkUsable(next);

    try {
      // 3. Local tracks and published DataChannels, under the same names
      //    and with the same tracks. Capture is untouched.
      await Future.wait([
        for (final publication in room.localParticipant._publications.toList())
          _republish(next, publication),
        ...room.data._republishAll(next),
      ]);
      _checkUsable(next);

      // 4. Tell the others where we are now.
      await _announceSession(next);
      room._holdAnnouncements = false;

      // 5. Remote tracks, from the publishers' current sessions, and
      //    DataChannel subscriptions. Their failures are retried by their
      //    own logic (RoomOptions.pullRetry) and reported as events.
      await Future.wait([
        for (final remote in room._remotes.values.toList())
          for (final publication in remote._publications.values.toList())
            publication._kick(),
        for (final subscription in room.data._subscriptions.toList())
          subscription._runner.run(),
      ]);
      _checkUsable(next);

      // 6. Media flows once ICE is up.
      await _whenConnected(next);
      _checkUsable(next);
    } catch (_) {
      if (identical(room._session, next)) room._stopListeningToSession();
      await _closeQuietly(next);
      rethrow;
    }
  }

  Future<void> _republish(SfuSession next, LocalMediaPublication local) async {
    final publication = local.publication;
    if (publication.state == SfuTrackState.closed ||
        publication.session != null) {
      return;
    }
    try {
      await next.republish(publication);
    } on SfuTrackException catch (error) {
      // The SFU rejected this one track: report it and carry on. It isn't
      // announced while failed, and the next re-session tries it again.
      _room._emit(RoomErrorEvent('republish ${local.trackName}', error));
    }
  }

  /// Announces the local state with [next]'s session ID. A failing
  /// signaling update is retried with [ReconnectOptions.backoff]; if that
  /// gives up, the attempt fails.
  Future<void> _announceSession(SfuSession next) async {
    final room = _room;
    final retry = Backoff(_options.backoff, clock: () => _now);
    while (true) {
      _checkUsable(next);
      final state = room.localParticipant.state;
      try {
        await room.signaling.update(state);
        room._announced = state;
        return;
      } catch (error) {
        if (room._left) throw const _Aborted();
        room._emit(RoomErrorEvent('signaling.update', error));
        final delay = retry.nextDelay();
        if (delay == null) rethrow;
        await _sleep(delay);
      }
    }
  }

  /// Waits while [next] is connecting (or briefly disconnected), until it
  /// connects, fails, or a trigger (such as the connect timeout) fires.
  ///
  /// A session that carries media or DataChannels must connect before the
  /// room says `connected`, even if its peer connection is still `new`
  /// (connection states arrive asynchronously, so right after the
  /// negotiation it often is). Otherwise the room would show `connected`,
  /// then `connecting`, then `connected` again. With nothing negotiated,
  /// `new` is final: there is nothing to connect.
  Future<void> _whenConnected(SfuSession next) async {
    bool negotiated() =>
        next.publications.isNotEmpty ||
        next.subscriptions.isNotEmpty ||
        next.dataChannels.isNotEmpty;
    bool waiting(SfuConnectionState state) =>
        state == SfuConnectionState.connecting ||
        state == SfuConnectionState.disconnected ||
        (state == SfuConnectionState.initial && negotiated());
    if (!waiting(next.currentConnectionState)) return;
    if (next.currentConnectionState == SfuConnectionState.initial) {
      // The room leaves `initial` out of the trigger (an idle session must
      // not time out), so arm the connect timeout for this wait here.
      _fire(
        _trigger.peerConnectionStateChanged(
          RTCPeerConnectionState.RTCPeerConnectionStateNew,
          _now,
        ),
      );
    }
    final done = Completer<void>();
    _wake = done;
    final listener = next.connectionState.listen((state) {
      if (!waiting(state) && !done.isCompleted) done.complete();
    }, onDone: () => done.isCompleted ? null : done.complete());
    try {
      await done.future;
    } finally {
      unawaited(listener.cancel());
      if (identical(_wake, done)) _wake = null;
    }
    _checkUsable(next);
    if (next.currentConnectionState != SfuConnectionState.connected &&
        next.currentConnectionState != SfuConnectionState.initial) {
      throw SfuSessionException(
        'the new session did not connect '
        '(${next.currentConnectionState.name})',
      );
    }
  }

  /// Throws unless the room is still joined, [next] is still its session and
  /// usable, and nothing triggered about it.
  void _checkUsable(SfuSession next) {
    final room = _room;
    if (room._left) throw const _Aborted();
    if (!identical(room._session, next)) {
      throw const SfuSessionException('the session was replaced');
    }
    if (next.isClosed) throw const SfuSessionClosedException();
    final failure = next.failure;
    if (failure != null) throw SfuSessionFailedException(failure);
    final pending = _pending;
    if (pending != null) {
      throw SfuSessionException('the new session broke (${pending.name})');
    }
  }

  /// Waits [delay], or less if woken ([networkChanged], [manual], leave).
  Future<void> _sleep(Duration delay) async {
    final wake = Completer<void>();
    _wake = wake;
    _sleeping = true;
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    try {
      await wake.future;
    } finally {
      timer.cancel();
      _sleeping = false;
      if (identical(_wake, wake)) _wake = null;
    }
  }

  void _wakeUp() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  static Future<void> _closeQuietly(SfuSession session) async {
    try {
      await session.close();
    } catch (_) {
      // Closed locally either way.
    }
  }

  /// The room is leaving: stop timers and wake any wait, so a running
  /// episode notices and stops.
  void dispose() {
    _disposed = true;
    _checkTimer?.cancel();
    _stableTimer?.cancel();
    _wakeUp();
  }
}
