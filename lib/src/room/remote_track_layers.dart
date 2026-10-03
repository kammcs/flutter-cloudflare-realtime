part of 'room.dart';

/// The simulcast layer state of a [RemoteTrackPublication], for debug UIs
/// and tests (`docs/design.md` §6.1).
///
/// Read it with [RemoteTrackPublication.layerState], or follow it with
/// [RemoteTrackPublication.layerStateChanges].
@immutable
class RemoteTrackLayerState {
  /// Creates a layer state.
  const RemoteTrackLayerState({
    this.currentRid,
    this.targetRid,
    this.automaticRid,
    this.preferredLayer,
    this.hidden = false,
    this.released = false,
  });

  /// The RID the live pull asks the SFU for, or `null` while the track isn't
  /// pulled or is pulled without simulcast preferences.
  ///
  /// With `ridNotAvailable: asciibetical`, the SFU forwards another layer
  /// while this one isn't sent (for example when the publisher's encoder
  /// drops it); the received resolution is in the stats (`inbound-rtp`
  /// `frameWidth`/`frameHeight`).
  final String? currentRid;

  /// The RID the room wants: [preferredLayer] if set, else [automaticRid],
  /// the lowest layer while [hidden], or [RoomOptions.defaultVideoLayer]
  /// while no view has reported. It differs from [currentRid] while a
  /// `tracks/update` is on its way. `null` for tracks without simulcast.
  final String? targetRid;

  /// The layer picked from the size of the views that show the track, or
  /// `null` while no view reports (or all are [hidden]).
  final String? automaticRid;

  /// The layer set with [RemoteTrackPublication.setPreferredLayer], which
  /// overrides [automaticRid] until cleared.
  final SimulcastLayer? preferredLayer;

  /// Whether every view reporting the track is hidden (paused). The track
  /// is then kept at its lowest layer.
  final bool hidden;

  /// Whether the pull was released because the views stayed [hidden] for
  /// [RoomOptions.hiddenVideoLinger]. It is pulled again as soon as a view
  /// becomes visible.
  final bool released;

  @override
  bool operator ==(Object other) =>
      other is RemoteTrackLayerState &&
      other.currentRid == currentRid &&
      other.targetRid == targetRid &&
      other.automaticRid == automaticRid &&
      other.preferredLayer == preferredLayer &&
      other.hidden == hidden &&
      other.released == released;

  @override
  int get hashCode => Object.hash(
    currentRid,
    targetRid,
    automaticRid,
    preferredLayer,
    hidden,
    released,
  );

  @override
  String toString() =>
      'RemoteTrackLayerState(current: $currentRid, target: $targetRid, '
      'automatic: $automaticRid, preferred: ${preferredLayer?.name}'
      '${hidden ? ', hidden' : ''}${released ? ', released' : ''})';
}

/// The publisher ladder for a simulcast hint: from its size when given,
/// else assuming a 720p capture with the hint's RIDs.
SimulcastLadder? _ladderForHint(SimulcastInfo? hint) {
  if (hint == null) return null;
  return simulcastLadderFor(hint) ??
      simulcastLadderFor(
        SimulcastInfo(
          rids: hint.rids,
          width: 1280,
          height: 720,
          scaleDownBy: hint.scaleDownBy,
        ),
      );
}

/// The room's layer selection: a [LayerSelectionController] fed by the
/// views ([Room.layerReporter]), whose choices are applied to the remote
/// video publications.
class _RoomLayers implements LayerDemandReporter {
  _RoomLayers(this._room);

  final Room _room;
  late final LayerSelectionController _controller = LayerSelectionController(
    onChange: _onChange,
    config: _room.options.layerSelection,
  );
  // Video publications by `RemoteTrackPublication.id`.
  final Map<String, RemoteTrackPublication> _byId = {};
  bool _disposed = false;

  /// A remote video track appeared.
  void add(RemoteTrackPublication publication) {
    if (_disposed || publication.kind != TrackKind.video) return;
    _byId[publication.id] = publication;
    final ladder = publication._layers.ladder;
    if (ladder != null) _controller.setLadder(publication.id, ladder);
  }

  /// The publisher's simulcast hint changed.
  void updateLadder(RemoteTrackPublication publication) {
    if (_disposed || !identical(_byId[publication.id], publication)) return;
    final ladder = publication._layers.ladder;
    if (ladder != null) _controller.setLadder(publication.id, ladder);
  }

  /// The track was closed.
  void remove(RemoteTrackPublication publication) {
    if (_disposed || !identical(_byId[publication.id], publication)) return;
    _byId.remove(publication.id);
    _controller.removeSubscription(publication.id);
    demandMayHaveChanged();
  }

  Map<String, String> _lastDemand = const {};

  /// The layer this room pulls (or is about to pull) of each remote video:
  /// `trackName` to the target RID, for [ParticipantState.layerDemand]
  /// (`docs/design.md` §6.2). Lists only tracks that are subscribed and
  /// asked for with a RID.
  Map<String, String> demand() => {
    for (final publication in _byId.values)
      if (publication.isSubscribed)
        publication.trackName: ?publication._layers.targetRid(),
  };

  /// Re-announces the local state when [demand] changed. Called whenever a
  /// publication's layer state is published.
  void demandMayHaveChanged() {
    if (_disposed || !_room.options.layerPausing.reportDemand) return;
    final next = demand();
    if (mapEquals(next, _lastDemand)) return;
    _lastDemand = next;
    unawaited(_room._announcer.run());
  }

  @override
  void reportDemand(String subscriptionId, Object viewKey, TileDemand demand) {
    // Reports for tracks the room doesn't show (closed, or not video) would
    // only leave state behind.
    if (_disposed || !_byId.containsKey(subscriptionId)) return;
    _controller.reportDemand(subscriptionId, viewKey, demand);
  }

  @override
  void removeView(String subscriptionId, Object viewKey) {
    if (_disposed) return;
    _controller.removeView(subscriptionId, viewKey);
  }

  void _onChange(String subscriptionId, LayerPreference preference) {
    _byId[subscriptionId]?._layers.onAutomatic(preference);
  }

  void dispose() {
    _disposed = true;
    _controller.dispose();
    _byId.clear();
  }
}

/// A remote video publication's layer state: the automatic choice, the
/// manual override, and the release of hidden pulls.
class _TrackLayers {
  _TrackLayers(this._publication)
    : ladder = _ladderForHint(_publication._info.simulcast);

  final RemoteTrackPublication _publication;

  /// The publisher's ladder, from its simulcast hint; `null` without one.
  SimulcastLadder? ladder;

  /// The manual override ([RemoteTrackPublication.setPreferredLayer]).
  SimulcastLayer? manual;

  /// The last choice of layer selection, or `null` before any view
  /// reported.
  LayerPreference? automatic;

  /// Whether the pull was released after the views stayed hidden: leases
  /// then don't keep the track pulled.
  bool released = false;

  Timer? _linger;
  String? _updating;
  final StateStream<RemoteTrackLayerState> state = StateStream(
    const RemoteTrackLayerState(),
    distinct: true,
  );

  Room get _room => _publication._room;

  bool get hidden => automatic?.isPaused ?? false;

  /// The RID to pull, or to switch the live pull to. See
  /// [RemoteTrackLayerState.targetRid].
  String? targetRid() {
    final publication = _publication;
    if (publication.kind != TrackKind.video) return null;
    final layer = manual;
    if (layer != null) return publication._ridFor(layer);
    final ladder = this.ladder;
    if (ladder == null) return null; // Not simulcast.
    final choice = automatic;
    if (choice != null) {
      final rid = choice.rid;
      return rid ?? ladder.lowest.rid;
    }
    return publication._ridFor(_room.options.defaultVideoLayer);
  }

  /// The publisher's hint changed.
  void updateHint() {
    final next = _ladderForHint(_publication._info.simulcast);
    if (next == ladder) return;
    ladder = next;
    _room._layers.updateLadder(_publication);
    publish();
    unawaited(apply());
  }

  /// Layer selection picked [preference] from the views' sizes.
  void onAutomatic(LayerPreference preference) {
    automatic = preference;
    if (preference.isPaused) {
      _startLinger();
    } else {
      _linger?.cancel();
      _linger = null;
      if (released) {
        // Pull again, at the new layer.
        released = false;
        publish();
        _publication._notify();
        unawaited(_publication._kick());
        return;
      }
    }
    publish();
    unawaited(apply());
  }

  /// A lease was taken while none was held: a view (re)appeared. A pull
  /// released for being hidden may be wanted again; if the views are
  /// still hidden, the linger starts over.
  void onRetained() {
    if (!released) return;
    released = false;
    if (hidden) _startLinger();
    publish();
  }

  void _startLinger() {
    final linger = _room.options.hiddenVideoLinger;
    if (linger == null || released || (_linger?.isActive ?? false)) return;
    _linger = Timer(linger, () {
      _linger = null;
      if (!hidden || _publication._closed) return;
      released = true;
      publish();
      _publication._notify();
      unawaited(_publication._runner.run());
    });
  }

  /// Sets the manual override and applies it.
  Future<void> setManual(SimulcastLayer? layer) async {
    manual = layer;
    publish();
    final subscription = _publication._subscription;
    final rid = targetRid();
    if (subscription == null ||
        rid == null ||
        subscription.state == SfuTrackState.closed ||
        subscription.preferredRid == rid) {
      return;
    }
    await subscription.setPreferredRid(rid);
    publish();
  }

  /// Switches the live pull to [targetRid] (`tracks/update`), or makes a
  /// pull that is off its session remember it for its next pull. Failures
  /// are reported as [RoomErrorEvent]s; the next change tries again.
  Future<void> apply() async {
    final subscription = _publication._subscription;
    final rid = targetRid();
    if (subscription == null ||
        rid == null ||
        _room._left ||
        subscription.state == SfuTrackState.closed ||
        subscription.preferredRid == rid ||
        _updating == rid) {
      return;
    }
    final session = subscription.session;
    if (session != null) {
      if (!session.isUsable) return;
      // A pull on its way: applied once it lands (see `_onPulled`).
      if (subscription.state == SfuTrackState.pending) return;
    }
    _updating = rid;
    try {
      await subscription.setPreferredRid(rid);
    } catch (error) {
      if (!_room._left) _room._emit(RoomErrorEvent('tracks/update', error));
    } finally {
      if (_updating == rid) _updating = null;
    }
    publish();
  }

  /// Publishes the current [RemoteTrackLayerState].
  void publish() {
    if (state.isClosed) return;
    final subscription = _publication._subscription;
    final choice = automatic;
    state.set(
      RemoteTrackLayerState(
        currentRid: subscription == null
            ? null
            : subscription.state == SfuTrackState.closed
            ? null
            : subscription.preferredRid,
        targetRid: targetRid(),
        automaticRid: choice?.rid,
        preferredLayer: manual,
        hidden: hidden,
        released: released,
      ),
    );
    _room._layers.demandMayHaveChanged();
  }

  void cancelTimers() {
    _linger?.cancel();
    _linger = null;
  }

  Future<void> close() {
    cancelTimers();
    return state.close();
  }
}
