part of 'room.dart';

/// This client's participant in a [Room]: publishes, mutes and unpublishes
/// local media.
///
/// Each publish captures from a new media source (which the room owns and
/// disposes), pushes it to the SFU, and announces it through signaling as
/// soon as the SFU accepts it. Other participants then see the track in
/// [ParticipantState.tracks], with a `muted` flag that follows
/// [LocalMediaPublication.mute] and [LocalMediaPublication.unmute].
class LocalParticipant implements Participant {
  LocalParticipant._(this._room, this.participantId, this._metadata);

  final Room _room;

  @override
  final String participantId;

  Map<String, Object?>? _metadata;
  final List<LocalMediaPublication> _publications = [];
  final StreamController<LocalParticipant> _changes =
      StreamController.broadcast();

  /// The room this participant is in.
  Room get room => _room;

  /// The SFU session other participants pull this participant's tracks
  /// from.
  String get sessionId => _room._session.sessionId;

  @override
  Map<String, Object?>? get metadata => _metadata;

  /// The published tracks, in publish order.
  List<LocalMediaPublication> get trackPublications =>
      List.unmodifiable(_publications);

  /// The published camera, if any.
  LocalMediaPublication? get camera => _first(TrackSource.camera);

  /// The published microphone, if any.
  LocalMediaPublication? get microphone => _first(TrackSource.microphone);

  /// The published screen share, if any.
  LocalMediaPublication? get screen => _first(TrackSource.screen);

  /// The published screen-share audio, if any.
  LocalMediaPublication? get screenAudio => _first(TrackSource.screenAudio);

  /// Emits this participant whenever a track is published, unpublished,
  /// muted or unmuted, or the metadata changes. Completes after
  /// [Room.leave].
  Stream<LocalParticipant> get changes => _changes.stream;

  /// Whether this participant is speaking now: their microphone is unmuted
  /// and they are in [Room.activeSpeakers].
  @override
  bool get isSpeaking =>
      _room._speakers.monitor.currentSpeakers.contains(participantId);

  /// [isSpeaking], replaying the current value to each new listener and
  /// then emitting its changes.
  @override
  Stream<bool> get speakingChanges => _room._speakers.monitor.speakers
      .map((speakers) => speakers.contains(participantId))
      .distinct();

  /// The smoothed level of this client's microphone as it is sent, `0..1`,
  /// for a level meter. 0 while the microphone is muted or not published
  /// (a muted sender has no level to read; see
  /// [canDetectSpeakingWhileMuted]). Updated every
  /// [ActiveSpeakerOptions.pollInterval].
  @override
  double get audioLevel =>
      _room._speakers.monitor.snapshot.levels[participantId] ?? 0;

  /// [audioLevel], replaying the current value to each new listener and
  /// then emitting its changes.
  @override
  Stream<double> get audioLevelChanges => _room._speakers.monitor.snapshots
      .map((snapshot) => snapshot.levels[participantId] ?? 0.0)
      .distinct();

  /// Whether the room can tell that this participant speaks while their
  /// microphone is muted ([isSpeakingWhileMuted]).
  ///
  /// Always `false` for now (`docs/design.md` §7): muting stops the sender
  /// with `replaceTrack(null)`, so `getStats()` has no `media-source` level
  /// for the microphone, and `flutter_webrtc` 1.6 has no other way to read
  /// the level of a local track that isn't attached to a sender.
  bool get canDetectSpeakingWhileMuted => false;

  /// Whether this participant speaks while their microphone is muted, for
  /// a "you are muted" hint. Stays `false` while
  /// [canDetectSpeakingWhileMuted] is `false`.
  bool get isSpeakingWhileMuted =>
      _room._speakers.monitor.snapshot.localSpeakingWhileMuted;

  /// [isSpeakingWhileMuted], replaying the current value to each new
  /// listener and then emitting its changes.
  Stream<bool> get speakingWhileMutedChanges =>
      _room._speakers.monitor.localSpeakingWhileMuted;

  /// How well this client's own connection to the SFU works
  /// (`docs/design.md` §7.1): the round-trip time, the loss and jitter the
  /// SFU reports for what is sent, and whether the bandwidth estimate
  /// limits the video. [ConnectionQuality.lost] while the room is
  /// reconnecting or disconnected.
  @override
  ConnectionQuality get connectionQuality => _room._stats.local.value;

  @override
  Stream<ConnectionQuality> get connectionQualityChanges =>
      _room._stats.local.stream;

  /// The state announced through signaling: the session, every published
  /// track with its mute flag and simulcast layers, [metadata], and the
  /// layer this client pulls of each remote simulcast video
  /// ([ParticipantState.layerDemand], unless
  /// [LayerPausingOptions.reportDemand] is off).
  ///
  /// A track the SFU rejected when the room moved it to a new session
  /// (its [LocalMediaPublication.publication] is [SfuTrackState.failed]) is
  /// left out until a later re-session republishes it.
  ParticipantState get state => ParticipantState(
    participantId: participantId,
    sessionId: _room._session.sessionId,
    tracks: {
      for (final p in _publications)
        if (p.publication.state != SfuTrackState.failed) p.trackName: p.info,
    },
    metadata: _metadata,
    layerDemand: _room.options.layerPausing.reportDemand
        ? _room._layers.demand()
        : null,
  );

  LocalMediaPublication? _first(TrackSource source) {
    for (final publication in _publications) {
      if (publication.source == source) return publication;
    }
    return null;
  }

  /// Replaces the announced metadata and waits for the signaling update.
  Future<void> setMetadata(Map<String, Object?>? metadata) {
    _room._checkNotLeft();
    _metadata = metadata == null ? null : Map.unmodifiable(metadata);
    _changed();
    return _room._announcer.run();
  }

  /// Publishes a camera.
  ///
  /// Captures with [options] (from [device] if given, else the best
  /// available camera), and sends it with [encodings]: the session's
  /// default simulcast layers (`SimulcastPresets.h720`) when null, or for
  /// example `SimulcastPresets.h360`; `[]` sends one encoding without
  /// simulcast. The layers are announced in [TrackInfo.simulcast].
  ///
  /// With [muted], the track is published without capturing (the camera
  /// light stays off) until [LocalMediaPublication.unmute].
  ///
  /// The announced layer size is the size the camera captures (from the
  /// track, then from `getStats()`: portrait on a phone held upright), as
  /// the encoder gets it (smaller while libwebrtc's CPU adaptation scales
  /// it down), not the preset, and it is announced again when it changes
  /// (`docs/design.md` §6.3). [codec] overrides [RoomOptions.videoCodec].
  ///
  /// Throws the capture's [MediaException] if the camera can't start (the
  /// source is disposed then), or the session's exception if the SFU
  /// rejects the track.
  Future<LocalMediaPublication> publishCamera({
    CameraOptions options = const CameraOptions(),
    MediaDevice? device,
    List<SendEncoding>? encodings,
    bool muted = false,
    VideoCodec? codec,
  }) async {
    _room._checkNotLeft();
    final camera = CameraSource(
      backend: _room._mediaBackend,
      deviceList: _room._devices,
      options: options,
      preferredDevice: device,
    );
    if (!muted) await _startCapture(camera, camera.startBroadcasting);
    final effective =
        encodings ?? _room._session.options.defaults.videoEncodings;
    final captured = _settingsSize(camera.track?.track);
    return _publish(
      camera,
      source: TrackSource.camera,
      kind: TrackKind.video,
      ownsSource: true,
      encodings: encodings,
      codec: codec,
      simulcast: simulcastInfoFor(
        effective,
        width: captured?.$1 ?? options.preset.width,
        height: captured?.$2 ?? options.preset.height,
      ),
    );
  }

  /// Switches the published [camera] to another camera, with one call on
  /// every platform: front/back on phones, the next camera elsewhere
  /// ([CameraSource.switchCamera]). The track keeps its name and the
  /// publication keeps sending, so other participants see the new camera
  /// without pulling again.
  ///
  /// Completes with the camera now in use. Throws a [StateError] when no
  /// camera is published, or when it was published from an app-owned
  /// source that isn't a [CameraSource] (switch that source yourself).
  Future<MediaDevice?> switchCamera() {
    _room._checkNotLeft();
    final source = camera?.mediaSource;
    if (source == null) {
      throw StateError('No camera is published.');
    }
    if (source is! CameraSource) {
      throw StateError(
        'The camera was published from a ${source.runtimeType}, not a '
        'CameraSource.',
      );
    }
    return source.switchCamera();
  }

  /// Publishes a microphone, captured with [options] (from [device] if
  /// given).
  ///
  /// With [muted], the track is published but sends nothing until
  /// [LocalMediaPublication.unmute]; the microphone doesn't capture until
  /// then either.
  ///
  /// Throws like [publishCamera].
  Future<LocalMediaPublication> publishMicrophone({
    MicrophoneOptions options = const MicrophoneOptions(),
    MediaDevice? device,
    bool muted = false,
  }) async {
    _room._checkNotLeft();
    final microphone = MicrophoneSource(
      backend: _room._mediaBackend,
      deviceList: _room._devices,
      options: options,
      preferredDevice: device,
    );
    if (!muted) await _startCapture(microphone, microphone.startBroadcasting);
    return _publish(
      microphone,
      source: TrackSource.microphone,
      kind: TrackKind.audio,
      ownsSource: true,
    );
  }

  /// Publishes a screen share.
  ///
  /// On desktop, pass the [source] picked with a `ScreenSourcePicker`. On
  /// the web and phones, pass none: the browser shows its own picker,
  /// Android its screen-capture consent dialog (under this package's
  /// foreground service), and iOS its broadcast picker for the app's
  /// Broadcast Upload Extension (`docs/design.md` §10; on iOS this
  /// completes once the user has started the broadcast). With
  /// [ScreenShareOptions.captureAudio], where the platform captures audio
  /// (not phones), the audio is published too, as [screenAudio].
  ///
  /// The share is sent as one layer tuned for text by default
  /// ([ScreenSharePresets.detail]: up to 15 fps and 2.5 Mbps, captured at
  /// 15 fps by the default [options]; `docs/design.md` §12, question 2).
  /// Pass [ScreenSharePresets.motion] (with `frameRate: 30`) for video, or
  /// [ScreenSharePresets.simulcast] to add a thumbnail layer, whose layers
  /// are then announced in [TrackInfo.simulcast] with the captured size.
  /// The video is sent with [codec], else [RoomOptions.videoCodec], else
  /// the session default (VP8); never H.264 from Windows.
  ///
  /// When the share ends outside the app (the shared window closes, the
  /// browser's "Stop sharing" button, Android's stop control or
  /// notification, or iOS's broadcast stop), it is unpublished with its
  /// audio,
  /// and signaling is updated; the [LocalTrackUnpublishedEvent] carries the
  /// [LocalTrackUnpublishedEvent.endReason]. Muting it ends the capture but
  /// keeps it published; unmuting shares the same source again (on the
  /// web and phones, the browser or the system asks again).
  ///
  /// If the capture delivers no frames (on macOS: no Screen Recording
  /// permission), the room reports a [LocalTrackStalledEvent]; see
  /// [RoomOptions.screenShareStallTimeout].
  ///
  /// Throws an [ArgumentError] on desktop without a [source], and a
  /// [MediaException] if the share doesn't start: a cancelled browser
  /// picker or consent dialog, an iOS broadcast not started in time, or a
  /// [ScreenShareSetupException] when the iOS app isn't set up for it.
  Future<LocalMediaPublication> publishScreen({
    ScreenSource? source,
    ScreenShareOptions options = const ScreenShareOptions(),
    List<SendEncoding>? encodings,
    VideoCodec? codec,
  }) async {
    _room._checkNotLeft();
    final share = ScreenShareSource(
      backend: _room._mediaBackend,
      options: options,
    );
    await _startCapture(share, () async {
      if (source != null) await share.select(source);
      return share.startBroadcasting();
    });
    // A share that ends while it is being pushed is unpublished right after.
    ScreenShareEndReason? endedEarly;
    final earlyEnd = share.ended.listen((reason) => endedEarly = reason);
    final effective = encodings ?? ScreenSharePresets.detail;
    final LocalMediaPublication video;
    try {
      video = await _publish(
        share,
        source: TrackSource.screen,
        kind: TrackKind.video,
        ownsSource: true,
        encodings: effective,
        codec: codec,
        simulcast: simulcastInfoFor(effective),
      );
    } finally {
      unawaited(earlyEnd.cancel());
    }
    if (share.audioTrack != null) {
      try {
        video._companion = await _publish(
          share,
          source: TrackSource.screenAudio,
          kind: TrackKind.audio,
          ownsSource: false,
          tracks: share.broadcastAudioTrackChanges,
        );
      } catch (error) {
        _room._emit(RoomErrorEvent('publish screen audio', error));
      }
    }
    void onEnded(ScreenShareEndReason reason) {
      // `stopped` is the app's own doing (mute or unpublish).
      if (reason == ScreenShareEndReason.stopped) return;
      unawaited(_unpublish(video, endReason: reason));
    }

    video._endedListener = share.ended.listen(onEnded);
    if (endedEarly case final reason?) onEnded(reason);
    if (_room.options.screenShareStallTimeout case final timeout?
        when video.isPublished) {
      video._watchdog = _ScreenShareWatchdog(
        _room,
        video,
        share,
        timeout: timeout,
      );
    }
    return video;
  }

  /// Publishes an app-owned [mediaSource] as a [source] track.
  ///
  /// The room sends whatever the source broadcasts (nothing while it isn't
  /// broadcasting, which is announced as muted) and never disposes it; the
  /// app starts and stops it. [encodings], [simulcast] and [codec] are as
  /// for [publishCamera]; pass [simulcast] to announce the layers of a
  /// simulcast video (its size is then corrected to the captured size).
  Future<LocalMediaPublication> publishMediaSource(
    LocalMediaSource mediaSource, {
    TrackSource? source,
    List<SendEncoding>? encodings,
    SimulcastInfo? simulcast,
    VideoCodec? codec,
  }) {
    _room._checkNotLeft();
    return _publish(
      mediaSource,
      source: source ?? mediaSource.source,
      kind: mediaSource.kind,
      ownsSource: false,
      encodings: encodings,
      simulcast: simulcast,
      codec: codec,
    );
  }

  /// Unpublishes [publication]: announces its removal, closes it on the
  /// SFU, and disposes its media source if the room created it.
  /// Unpublishing a screen share also unpublishes its audio.
  ///
  /// Does nothing if it is already unpublished.
  Future<void> unpublish(LocalMediaPublication publication) =>
      _unpublish(publication);

  Future<void> _unpublish(
    LocalMediaPublication publication, {
    ScreenShareEndReason? endReason,
  }) async {
    if (publication._unpublished || !_publications.contains(publication)) {
      return;
    }
    final closing = [
      publication,
      if (publication._companion case final companion?
          when !companion._unpublished)
        companion,
    ];
    for (final p in closing) {
      p._unpublished = true;
      _publications.remove(p);
      await p._stopListening();
    }
    _changed();
    await _room._announcer.run();
    await Future.wait([for (final p in closing) _closeQuietly(p.publication)]);
    for (final p in closing) {
      if (p.ownsMediaSource) await _disposeQuietly(p.mediaSource);
      _room._emit(LocalTrackUnpublishedEvent(p, endReason: endReason));
    }
  }

  /// Starts [start] on [source], and throws what went wrong if the source
  /// isn't broadcasting afterwards (disposing the source).
  Future<void> _startCapture(
    LocalMediaSource source,
    Future<bool> Function() start,
  ) async {
    MediaException? failure;
    final errors = source.errors.listen((error) => failure = error);
    bool started;
    try {
      started = await start();
      // Let an error reported during the start arrive.
      await Future<void>.value();
    } catch (_) {
      unawaited(errors.cancel());
      await _disposeQuietly(source);
      rethrow;
    }
    unawaited(errors.cancel());
    if (started && source.isBroadcasting) return;
    await _disposeQuietly(source);
    throw failure ??
        MediaCaptureException(
          'The ${source.source.name} capture did not start '
          '(or the picker was cancelled).',
        );
  }

  Future<LocalMediaPublication> _publish(
    LocalMediaSource mediaSource, {
    required TrackSource source,
    required TrackKind kind,
    required bool ownsSource,
    List<SendEncoding>? encodings,
    SimulcastInfo? simulcast,
    Stream<CapturedTrack?>? tracks,
    VideoCodec? codec,
  }) async {
    // Readable and unique; kept for the publication's lifetime, so a
    // republish on a new session (docs/design.md §8) keeps the name.
    final trackName = '${source.name}-${generateTrackName()}';
    final videoCodec = kind == TrackKind.video
        ? _effectiveVideoCodec(_room, codec)
        : null;
    final LocalTrackPublication publication;
    try {
      // While the room replaces its session, push to the new one. A push
      // whose session fails under it (the SFU expired a session that never
      // connected: 410) is pushed again once the room has a new session.
      publication = await _room._onSessionWithRetry(
        (session) => session.publishTrackStream(
          (tracks ?? mediaSource.broadcastTrackChanges).map((t) => t?.track),
          kind: kind.name,
          options: PublishOptions(
            trackName: trackName,
            sendEncodings: encodings,
            codecPreferences: videoCodec?.codecPreferences,
          ),
        ),
      );
    } catch (_) {
      if (ownsSource) await _disposeQuietly(mediaSource);
      rethrow;
    }
    if (_room._left) {
      await _closeQuietly(publication);
      if (ownsSource) await _disposeQuietly(mediaSource);
      throw StateError('The room "${_room.roomId}" was left while publishing.');
    }
    final local = LocalMediaPublication._(
      participant: this,
      mediaSource: mediaSource,
      source: source,
      kind: kind,
      publication: publication,
      ownsMediaSource: ownsSource,
      simulcast: kind == TrackKind.video ? simulcast : null,
      videoCodec: videoCodec,
    );
    _publications.add(local);
    // Mute changes are announced; the stream replays the current value,
    // which is already part of this announcement.
    local._broadcastingListener = mediaSource.broadcastingChanges.listen(
      (_) => _changed(),
    );
    _room._pausing.add(local);
    if (local._simulcast != null) {
      local._sizeWatcher = _SentSizeWatcher(_room, local)
        ..start(tracks ?? mediaSource.broadcastTrackChanges);
    }
    _changed();
    await _room._announcer.run();
    _room._emit(LocalTrackPublishedEvent(local));
    return local;
  }

  void _changed() {
    if (_room._left) return;
    _room._noteVideo();
    _room._screenAwake.update();
    if (!_changes.isClosed) _changes.add(this);
    unawaited(_room._announcer.run());
  }

  Future<void> _unpublishAllForLeave() async {
    final all = _publications.toList();
    _publications.clear();
    for (final p in all) {
      p._unpublished = true;
      await p._stopListening();
    }
    // Same event-loop turn: one `tracks/close` for all of them.
    await Future.wait([for (final p in all) _closeQuietly(p.publication)]);
    for (final p in all) {
      if (p.ownsMediaSource) await _disposeQuietly(p.mediaSource);
    }
  }

  static Future<void> _closeQuietly(LocalTrackPublication publication) async {
    try {
      await publication.unpublish();
    } catch (_) {
      // Closed locally either way.
    }
  }

  static Future<void> _disposeQuietly(LocalMediaSource source) async {
    try {
      await source.dispose();
    } catch (_) {
      // Best effort.
    }
  }

  @override
  String toString() =>
      'LocalParticipant($participantId, tracks: '
      '${[for (final p in _publications) p.trackName]})';
}

/// A local track published in a [Room], with its media source.
///
/// Mute with [mute] and [unmute]: they drive the source's broadcasting
/// switch, so nothing is sent while muted and, for the camera and screen,
/// the capture is released (`MutePolicy`). The track stays published and
/// other participants see [isMuted] in its [TrackInfo].
class LocalMediaPublication {
  LocalMediaPublication._({
    required this.participant,
    required this.mediaSource,
    required this.source,
    required this.kind,
    required this.publication,
    required this.ownsMediaSource,
    SimulcastInfo? simulcast,
    this.videoCodec,
  }) : _simulcast = simulcast;

  /// The participant that published it.
  final LocalParticipant participant;

  /// The capture behind the track. Use it for device selection
  /// ([CameraSource.setPreferredDevice]), options and the local preview
  /// ([LocalMediaSource.track]).
  final LocalMediaSource mediaSource;

  /// What the track captures.
  final TrackSource source;

  /// Audio or video.
  final TrackKind kind;

  /// The session-level publication, for advanced use (stats, encodings).
  final LocalTrackPublication publication;

  /// Whether the room created [mediaSource] and disposes it on unpublish.
  final bool ownsMediaSource;

  SimulcastInfo? _simulcast;

  /// The simulcast layers announced for the track, or `null`. Their size is
  /// the size the encoder gets from the source (the captured size, smaller
  /// while the CPU adaptation scales it down), updated when it changes
  /// (`docs/design.md` §6.3).
  SimulcastInfo? get simulcast => _simulcast;

  /// The codec the video is sent with, as requested (the platform falls
  /// back to VP8 when it can't encode it), or `null` for the session's
  /// codec preferences (VP8 by default) and for audio.
  final VideoCodec? videoCodec;

  final StateStream<Set<String>> _pausedLayers = StateStream(
    const {},
    distinct: true,
  );

  /// The simulcast layers (RIDs) not sent now because no one in the room
  /// pulls them ([RoomOptions.layerPausing], `docs/design.md` §6.2). Empty
  /// when every layer is sent.
  Set<String> get pausedLayers => _pausedLayers.value;

  /// [pausedLayers], replaying the current value to each new listener, then
  /// its changes. Completes when the track is unpublished.
  Stream<Set<String>> get pausedLayersChanges => _pausedLayers.stream;

  _SentSizeWatcher? _sizeWatcher;
  bool _unpublished = false;
  LocalMediaPublication? _companion;
  StreamSubscription<bool>? _broadcastingListener;
  StreamSubscription<ScreenShareEndReason>? _endedListener;
  _ScreenShareWatchdog? _watchdog;

  /// The track's SFU name. Stable for the publication's lifetime.
  String get trackName => publication.trackName;

  /// Whether nothing is being sent: the source isn't broadcasting.
  bool get isMuted => !mediaSource.isBroadcasting;

  /// [isMuted], replaying the current value to each new listener.
  Stream<bool> get mutedChanges =>
      mediaSource.broadcastingChanges.map((broadcasting) => !broadcasting);

  /// Whether the track is still published.
  bool get isPublished => !_unpublished;

  /// This track's typed stats (`docs/design.md` §7.1), its sent layers, in
  /// the latest [Room.stats] snapshot; `null` until it has reports. See
  /// [statsChanges].
  LocalTrackStats? get stats =>
      participant._room._stats.latest?.local[trackName];

  /// [stats] for each snapshot, replaying the latest. Listening makes the
  /// room poll.
  Stream<LocalTrackStats?> get statsChanges =>
      participant._room._stats.stream.map((stats) => stats.local[trackName]);

  /// What is announced for this track.
  TrackInfo get info => TrackInfo(
    kind: kind,
    source: source,
    muted: isMuted,
    simulcast: simulcast,
  );

  /// Stops sending. The track stays published and is announced as muted.
  Future<void> mute() {
    _checkPublished();
    return mediaSource.stopBroadcasting();
  }

  /// Starts sending again, capturing if needed. Returns whether the source
  /// is broadcasting afterwards; capture failures go to the source's
  /// `errors`.
  Future<bool> unmute() {
    _checkPublished();
    return mediaSource.setBroadcasting(true);
  }

  /// Calls [mute] or [unmute]. Returns whether the track is muted
  /// afterwards.
  Future<bool> setMuted(bool muted) async {
    if (muted) {
      await mute();
      return true;
    }
    return !await unmute();
  }

  /// Unpublishes the track. See [LocalParticipant.unpublish].
  Future<void> unpublish() => participant.unpublish(this);

  void _checkPublished() {
    if (_unpublished) throw StateError('The track $trackName is unpublished.');
  }

  Future<void> _stopListening() async {
    unawaited(_broadcastingListener?.cancel());
    unawaited(_endedListener?.cancel());
    _watchdog?.dispose();
    _sizeWatcher?.stop();
    participant._room._pausing.remove(this);
    _broadcastingListener = null;
    _endedListener = null;
    _watchdog = null;
    _sizeWatcher = null;
    unawaited(_pausedLayers.close());
  }

  @override
  String toString() =>
      'LocalMediaPublication($trackName, ${kind.name}, ${source.name}'
      '${isMuted ? ', muted' : ''}${_unpublished ? ', unpublished' : ''})';
}
