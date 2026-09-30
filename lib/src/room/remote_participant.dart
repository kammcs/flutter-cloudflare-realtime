part of 'room.dart';

/// Another participant in a [Room], as announced through signaling.
///
/// The same object represents the participant for as long as they are in
/// the room; its state changes in place. [changes] (and
/// [Room.participants]) emit when it does.
class RemoteParticipant {
  RemoteParticipant._(this._room, ParticipantState state)
    : participantId = state.participantId,
      _state = state;

  final Room _room;

  /// The participant's ID, unique in the room.
  final String participantId;

  ParticipantState _state;
  final Map<String, RemoteTrackPublication> _publications = {};
  final StreamController<RemoteParticipant> _changes =
      StreamController.broadcast();
  bool _present = true;

  /// The participant's current SFU session. It changes when they reconnect;
  /// the room then pulls their tracks from the new session.
  String get sessionId => _state.sessionId!;

  /// The app data the participant announced, such as a display name.
  Map<String, Object?>? get metadata => _state.metadata;

  /// The participant's last announced state, as received.
  ParticipantState get state => _state;

  /// Whether the participant is still in the room.
  bool get isPresent => _present;

  /// The tracks the participant publishes, in the order they appeared.
  List<RemoteTrackPublication> get trackPublications =>
      List.unmodifiable(_publications.values);

  /// The publication of the track named [trackName], if any.
  RemoteTrackPublication? trackPublication(String trackName) =>
      _publications[trackName];

  /// The participant's camera, if published.
  RemoteTrackPublication? get camera => _first(TrackSource.camera);

  /// The participant's microphone, if published.
  RemoteTrackPublication? get microphone => _first(TrackSource.microphone);

  /// The participant's screen share, if published.
  RemoteTrackPublication? get screen => _first(TrackSource.screen);

  /// The participant's screen-share audio, if published.
  RemoteTrackPublication? get screenAudio => _first(TrackSource.screenAudio);

  /// Emits this participant whenever its state changes: session, metadata,
  /// tracks added or removed, mute state. Completes when they leave.
  Stream<RemoteParticipant> get changes => _changes.stream;

  RemoteTrackPublication? _first(TrackSource source) {
    for (final publication in _publications.values) {
      if (publication.source == source) return publication;
    }
    return null;
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(this);
    _room._onRemoteChanged();
  }

  void _addTracks(Map<String, TrackInfo> tracks) {
    for (final MapEntry(key: name, value: info) in tracks.entries) {
      final publication = RemoteTrackPublication._(this, name, info);
      _publications[name] = publication;
      _room._emit(TrackPublishedEvent(publication));
      publication._start();
    }
  }

  void _apply(ParticipantChange change) {
    _state = change.current;
    for (final name in change.removedTracks.keys) {
      final publication = _publications.remove(name);
      if (publication == null) continue;
      publication._close();
      _room._emit(TrackUnpublishedEvent(publication));
    }
    for (final MapEntry(key: name, value: info)
        in change.changedTracks.entries) {
      _publications[name]?._updateInfo(info);
    }
    _addTracks(change.addedTracks);
    if (change.sessionChanged) {
      // They reconnected: pull what we subscribe to from the new session.
      for (final publication in _publications.values) {
        publication._kick();
      }
    }
    _room._emit(
      ParticipantUpdatedEvent(
        this,
        sessionChanged: change.sessionChanged,
        metadataChanged: change.metadataChanged,
        tracksChanged:
            change.addedTracks.isNotEmpty ||
            change.removedTracks.isNotEmpty ||
            change.changedTracks.isNotEmpty,
      ),
    );
    _notify();
  }

  /// Closes every publication and returns them.
  List<RemoteTrackPublication> _removeAll() {
    final all = _publications.values.toList();
    _publications.clear();
    for (final publication in all) {
      publication._close();
    }
    return all;
  }

  void _close() {
    _present = false;
    unawaited(_changes.close());
  }

  void _disposeForLeave() {
    _present = false;
    for (final publication in _publications.values) {
      publication._disposeForLeave();
    }
    unawaited(_changes.close());
  }

  @override
  String toString() =>
      'RemoteParticipant($participantId, session: ${_state.sessionId}, '
      'tracks: ${_publications.keys.toList()})';
}

/// Keeps a [RemoteTrackPublication] subscribed until [release] is called.
///
/// Obtained from [RemoteTrackPublication.retain]. Several leases (and an
/// explicit [RemoteTrackPublication.subscribe]) can hold the same track;
/// it is pulled while any of them does. [ParticipantVideoView] uses one
/// per view, so two views of the same track don't unsubscribe each other.
class RemoteTrackLease {
  RemoteTrackLease._(this.publication);

  /// The publication this lease keeps subscribed.
  final RemoteTrackPublication publication;

  bool _released = false;

  /// Whether [release] has been called.
  bool get isReleased => _released;

  /// Gives the lease up. The track is unsubscribed if nothing else holds
  /// it. Calling it again has no effect.
  void release() {
    if (_released) return;
    _released = true;
    publication._releaseLease();
  }
}

/// A track another participant publishes, and this client's subscription
/// to it.
///
/// The room pulls the track only while it is subscribed: automatically for
/// the kinds in [RoomOptions.autoSubscribe], after [subscribe], or while a
/// [RemoteTrackLease] (such as a [ParticipantVideoView]'s) holds it. The
/// pulled track arrives on [track], wrapped in a `MediaStream` for
/// rendering.
///
/// When the publisher moves to a new session (they reconnected), the room
/// pulls the track again from there and [track] emits the new one. When the
/// track is unpublished, the subscription is closed and [track] emits
/// `null`.
class RemoteTrackPublication {
  RemoteTrackPublication._(this.participant, this.trackName, TrackInfo info)
    : _info = info,
      _muted = StateStream(info.muted, distinct: true) {
    final auto = participant._room.options.autoSubscribe;
    _wanted = info.kind == TrackKind.audio ? auto.audio : auto.video;
    _backoff = Backoff(participant._room.options.pullRetry);
  }

  /// The participant who publishes the track.
  final RemoteParticipant participant;

  /// The track's SFU name.
  final String trackName;

  TrackInfo _info;
  final StateStream<bool> _muted;
  final StateStream<RenderableTrack?> _track = StateStream(
    null,
    distinct: true,
  );
  final StreamController<RemoteTrackPublication> _changes =
      StreamController.broadcast();
  late final CoalescingRunner _runner = CoalescingRunner(_reconcile);
  late final Backoff _backoff;
  late bool _wanted;
  int _leases = 0;
  bool _closed = false;
  RemoteTrackSubscription? _subscription;
  StreamSubscription<MediaStreamTrack>? _trackListener;
  int _wrapGeneration = 0;
  Timer? _retryTimer;
  Object? _error;
  SimulcastLayer? _layer;

  Room get _room => participant._room;

  /// A stable ID for this track in the room: `participantId/trackName`.
  ///
  /// It doesn't change when the publisher reconnects, so it can key UI
  /// state and layer selection (`SimulcastLayerReporter.subscriptionId`).
  String get id => '${participant.participantId}/$trackName';

  /// Audio or video.
  TrackKind get kind => _info.kind;

  /// What the track captures.
  TrackSource get source => _info.source;

  /// The publisher's latest announcement for this track.
  TrackInfo get info => _info;

  /// The simulcast layers the publisher sends, or `null` for a
  /// single-encoding track.
  SimulcastInfo? get simulcast => _info.simulcast;

  /// Whether the publisher has muted the track (they send no media).
  bool get muted => _info.muted;

  /// [muted], replaying the current value to each new listener.
  Stream<bool> get mutedChanges => _muted.stream;

  /// Whether the track should be pulled: auto-subscribed, [subscribe]d or
  /// held by a lease. The pull itself may still be in progress or failed;
  /// see [subscriptionState] and [error].
  bool get isSubscribed => !_closed && (_wanted || _leases > 0);

  /// The state of the pull, or `null` when there is none.
  SfuTrackState? get subscriptionState => _subscription?.state;

  /// The session-level subscription, while there is one. For advanced use
  /// (stats); subscribe through this publication instead of changing it.
  RemoteTrackSubscription? get subscription => _subscription;

  /// Why the last pull failed, or `null`.
  Object? get error => _error;

  /// Whether the publisher unpublished the track, or left.
  bool get isClosed => _closed;

  /// The layer asked for with [setPreferredLayer], if any.
  SimulcastLayer? get preferredLayer => _layer;

  /// The pulled track, ready to render, or `null` while not subscribed (or
  /// not pulled yet).
  RenderableTrack? get currentTrack => _track.value;

  /// The pulled track, replaying the current one to each new listener. It
  /// emits a new one when the track is pulled again (for example from the
  /// publisher's new session), and `null` when unsubscribed. The room
  /// disposes each stream it replaces.
  Stream<RenderableTrack?> get track => _track.stream;

  /// Emits this publication whenever [muted], [isSubscribed],
  /// [currentTrack], [subscriptionState] or [error] changes. Completes when
  /// the track is closed.
  Stream<RemoteTrackPublication> get changes => _changes.stream;

  /// Subscribes (pulls the track) and completes once the pull has been
  /// attempted. The track then arrives on [track]. A failed pull is retried
  /// (see [RoomOptions.pullRetry]); check [error] or listen for
  /// [TrackSubscriptionFailedEvent].
  Future<void> subscribe() {
    if (_closed) return Future.value();
    _wanted = true;
    _notify();
    return _kick();
  }

  /// Withdraws [subscribe] (and auto-subscription). The track is
  /// unsubscribed unless a [RemoteTrackLease] still holds it.
  Future<void> unsubscribe() {
    if (_closed) return Future.value();
    _wanted = false;
    _notify();
    return _runner.run();
  }

  /// Keeps the track subscribed until the returned lease is released, even
  /// if [unsubscribe] is called meanwhile. For widgets that show the track.
  RemoteTrackLease retain() {
    final lease = RemoteTrackLease._(this);
    _leases++;
    if (_leases == 1 && !_closed) {
      _notify();
      unawaited(_kick());
    }
    return lease;
  }

  void _releaseLease() {
    _leases--;
    if (_leases == 0 && !_closed) {
      _notify();
      unawaited(_runner.run());
    }
  }

  /// Asks for simulcast [layer]: `a`, `b` or `c` for [SimulcastLayer.high],
  /// [SimulcastLayer.medium] and [SimulcastLayer.low] (or the publisher's
  /// advertised layers by rank). Sent with `tracks/update` when pulled, and
  /// used for the next pull otherwise.
  Future<void> setPreferredLayer(SimulcastLayer layer) async {
    if (_closed) return;
    _layer = layer;
    final subscription = _subscription;
    if (subscription == null || subscription.state == SfuTrackState.closed) {
      return;
    }
    await subscription.setPreferredRid(_ridFor(layer));
  }

  String _ridFor(SimulcastLayer layer) =>
      layer.ridIn(_info.simulcast?.rids ?? const []);

  /// The `preferredRid` for a new pull: only for simulcast video (or when
  /// the app picked a layer).
  String? _initialRid() {
    if (_info.kind != TrackKind.video) return null;
    final layer = _layer;
    if (layer != null) return _ridFor(layer);
    if (_info.simulcast == null) return null;
    return _ridFor(_room.options.defaultVideoLayer);
  }

  void _notify() {
    if (!_changes.isClosed) _changes.add(this);
  }

  void _start() {
    if (isSubscribed) unawaited(_runner.run());
  }

  /// Reconciles now, without waiting for a pending retry.
  Future<void> _kick() {
    _retryTimer?.cancel();
    _retryTimer = null;
    _backoff.reset();
    return _runner.run();
  }

  void _updateInfo(TrackInfo info) {
    final wasMuted = _info.muted;
    _info = info;
    if (!_muted.isClosed) _muted.set(info.muted);
    if (wasMuted != info.muted) {
      _room._emit(TrackMutedEvent(this, muted: info.muted));
      // A pull that failed while nothing was sent may work now.
      if (_error != null) unawaited(_kick());
    }
    _notify();
  }

  /// Makes the pull match what's wanted. Runs through [_runner], so passes
  /// never overlap.
  Future<void> _reconcile() async {
    final room = _room;
    final session = room._session;
    final wanted = isSubscribed && !room._left;
    final current = _subscription;

    if (!wanted) {
      _cancelRetry();
      if (current != null) {
        _subscription = null;
        _detachTrack();
        _notify();
        if (!room._left) {
          try {
            await current.unsubscribe();
          } catch (_) {
            // Closed locally either way.
          }
        }
      }
      return;
    }
    // A dead session can't pull. Keep what we have for roadmap M5, which
    // moves subscriptions to a new session.
    if (!session.isUsable) return;
    final remoteSessionId = participant.sessionId;

    if (current != null) {
      final onThisSession = identical(current.session, session);
      switch (current.state) {
        case SfuTrackState.pending || SfuTrackState.active
            when onThisSession && current.remoteSessionId == remoteSessionId:
          return; // Up to date.
        case SfuTrackState.failed || SfuTrackState.interrupted
            when current.session == null:
          // Pull the same subscription again, from the publisher's current
          // session.
          if (_retryTimer?.isActive ?? false) return;
          try {
            await session.resubscribe(
              current,
              remoteSessionId: remoteSessionId,
            );
            await _onPulled(current);
          } catch (error) {
            _onPullFailed(error);
          }
          return;
        case _:
          // Pulled from the publisher's old session (or closed): close that
          // pull, then pull afresh below.
          _subscription = null;
          _detachTrack();
          if (current.state != SfuTrackState.closed) {
            try {
              await current.unsubscribe();
            } catch (_) {
              // Closed locally either way.
            }
          }
      }
    }
    if (_retryTimer?.isActive ?? false) return;
    if (!isSubscribed || room._left) return;

    try {
      final subscription = await session.subscribe(
        remoteSessionId: remoteSessionId,
        trackName: trackName,
        preferredRid: _initialRid(),
      );
      _subscription = subscription;
      await _onPulled(subscription);
    } catch (error) {
      _onPullFailed(error);
    }
    // If the wish changed meanwhile, the runner runs another pass.
  }

  Future<void> _onPulled(RemoteTrackSubscription subscription) async {
    _error = null;
    _backoff.reset();
    _notify();
    await _trackListener?.cancel();
    final first = subscription.track;
    if (first != null) await _wrap(subscription, first);
    if (!identical(_subscription, subscription) || _track.isClosed) return;
    _trackListener = subscription.trackStream.listen((track) {
      if (identical(_track.value?.track, track)) return;
      unawaited(_wrap(subscription, track));
    });
  }

  Future<void> _wrap(
    RemoteTrackSubscription subscription,
    MediaStreamTrack track,
  ) async {
    final generation = ++_wrapGeneration;
    final MediaStream stream;
    try {
      stream = await _room._wrapTrack(track);
    } catch (error) {
      _room._emit(RoomErrorEvent('wrap remote track', error));
      return;
    }
    if (generation != _wrapGeneration ||
        !identical(_subscription, subscription) ||
        _track.isClosed) {
      await _disposeStream(stream);
      return;
    }
    final previous = _track.value;
    final renderable = RenderableTrack(track: track, stream: stream);
    _track.set(renderable);
    if (previous != null) unawaited(_disposeStream(previous.stream));
    _room._emit(TrackSubscribedEvent(this, renderable));
    _notify();
  }

  void _onPullFailed(Object error) {
    _error = error;
    final retry =
        isSubscribed &&
        !_room._left &&
        _room._session.isUsable &&
        error is! SfuSessionClosedException &&
        error is! SfuSessionFailedException;
    final delay = retry ? _backoff.nextDelay() : null;
    _room._emit(
      TrackSubscriptionFailedEvent(this, error, willRetry: delay != null),
    );
    if (delay != null) {
      _retryTimer = Timer(delay, () {
        _retryTimer = null;
        unawaited(_runner.run());
      });
    }
    _notify();
  }

  void _cancelRetry() {
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  void _detachTrack() {
    final listener = _trackListener;
    _trackListener = null;
    unawaited(listener?.cancel());
    _wrapGeneration++;
    final previous = _track.value;
    if (!_track.isClosed) _track.set(null);
    if (previous != null) unawaited(_disposeStream(previous.stream));
  }

  static Future<void> _disposeStream(MediaStream stream) async {
    try {
      await stream.dispose();
    } catch (_) {
      // Already disposed.
    }
  }

  /// The track was unpublished or its publisher left: close the pull.
  void _close() {
    if (_closed) return;
    _closed = true;
    _cancelRetry();
    unawaited(_runner.run().whenComplete(_closeStreams));
  }

  /// The room is leaving: release local state; the session's close
  /// releases the pull.
  void _disposeForLeave() {
    if (_closed) return;
    _closed = true;
    _cancelRetry();
    _subscription = null;
    _detachTrack();
    unawaited(_closeStreams());
  }

  Future<void> _closeStreams() async {
    _detachTrack();
    await _track.close();
    await _muted.close();
    await _changes.close();
  }

  @override
  String toString() =>
      'RemoteTrackPublication($id, ${kind.name}, ${source.name}'
      '${muted ? ', muted' : ''}${isSubscribed ? ', subscribed' : ''})';
}
