part of 'room.dart';

/// This client's participant in a [Room]: publishes, mutes and unpublishes
/// local media.
///
/// Each publish captures from a new media source (which the room owns and
/// disposes), pushes it to the SFU, and announces it through signaling as
/// soon as the SFU accepts it. Other participants then see the track in
/// [ParticipantState.tracks], with a `muted` flag that follows
/// [LocalMediaPublication.mute] and [LocalMediaPublication.unmute].
class LocalParticipant {
  LocalParticipant._(this._room, this.participantId, this._metadata);

  final Room _room;

  /// This participant's ID in the room.
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

  /// The app data announced with this participant, such as a display name.
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
  bool get isSpeaking =>
      _room._speakers.monitor.currentSpeakers.contains(participantId);

  /// [isSpeaking], replaying the current value to each new listener and
  /// then emitting its changes.
  Stream<bool> get speakingChanges => _room._speakers.monitor.speakers
      .map((speakers) => speakers.contains(participantId))
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

  /// The state announced through signaling: the session, every published
  /// track with its mute flag and simulcast layers, and [metadata].
  ParticipantState get state => ParticipantState(
    participantId: participantId,
    sessionId: _room._session.sessionId,
    tracks: {for (final p in _publications) p.trackName: p.info},
    metadata: _metadata,
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
  /// Throws the capture's [MediaException] if the camera can't start (the
  /// source is disposed then), or the session's exception if the SFU
  /// rejects the track.
  Future<LocalMediaPublication> publishCamera({
    CameraOptions options = const CameraOptions(),
    MediaDevice? device,
    List<SendEncoding>? encodings,
    bool muted = false,
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
    return _publish(
      camera,
      source: TrackSource.camera,
      kind: TrackKind.video,
      ownsSource: true,
      encodings: encodings,
      simulcast: simulcastInfoFor(
        effective,
        width: options.preset.width,
        height: options.preset.height,
      ),
    );
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
  /// the web, pass none: the browser shows its own picker. With
  /// [ScreenShareOptions.captureAudio], where the platform captures audio,
  /// the audio is published too, as [screenAudio].
  ///
  /// The share is sent as one encoding by default (sharp text; roadmap
  /// open question 2 in `docs/design.md`); pass simulcast [encodings] to
  /// change that.
  ///
  /// When the share ends outside the app (the shared window closes, or the
  /// browser's "Stop sharing" button), it is unpublished. Muting it ends
  /// the capture but keeps it published; unmuting shares the same source
  /// again (on the web, the browser asks again).
  ///
  /// Throws [UnsupportedError] on Android and iOS (roadmap M6), an
  /// [ArgumentError] on desktop without a [source], and a [MediaException]
  /// if the share doesn't start (including a cancelled browser picker).
  Future<LocalMediaPublication> publishScreen({
    ScreenSource? source,
    ScreenShareOptions options = const ScreenShareOptions(),
    List<SendEncoding>? encodings,
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
    final effective = encodings ?? const <SendEncoding>[];
    final video = await _publish(
      share,
      source: TrackSource.screen,
      kind: TrackKind.video,
      ownsSource: true,
      encodings: effective,
      simulcast: simulcastInfoFor(effective),
    );
    if (share.currentAudioTrack != null) {
      try {
        video._companion = await _publish(
          share,
          source: TrackSource.screenAudio,
          kind: TrackKind.audio,
          ownsSource: false,
          tracks: share.broadcastAudioTrack,
        );
      } catch (error) {
        _room._emit(RoomErrorEvent('publish screen audio', error));
      }
    }
    video._endedListener = share.ended.listen((reason) {
      // `stopped` is the app's own doing (mute or unpublish).
      if (reason != ScreenShareEndReason.stopped) unawaited(unpublish(video));
    });
    return video;
  }

  /// Publishes an app-owned [mediaSource] as a [source] track.
  ///
  /// The room sends whatever the source broadcasts (nothing while it isn't
  /// broadcasting, which is announced as muted) and never disposes it; the
  /// app starts and stops it. [encodings] and [simulcast] are as for
  /// [publishCamera]; pass [simulcast] to announce the layers of a
  /// simulcast video.
  Future<LocalMediaPublication> publishMediaSource(
    LocalMediaSource mediaSource, {
    TrackSource? source,
    List<SendEncoding>? encodings,
    SimulcastInfo? simulcast,
  }) {
    _room._checkNotLeft();
    return _publish(
      mediaSource,
      source: source ?? mediaSource.source,
      kind: mediaSource.kind,
      ownsSource: false,
      encodings: encodings,
      simulcast: simulcast,
    );
  }

  /// Unpublishes [publication]: announces its removal, closes it on the
  /// SFU, and disposes its media source if the room created it.
  /// Unpublishing a screen share also unpublishes its audio.
  ///
  /// Does nothing if it is already unpublished.
  Future<void> unpublish(LocalMediaPublication publication) async {
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
      _room._emit(LocalTrackUnpublishedEvent(p));
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
      await errors.cancel();
      await _disposeQuietly(source);
      rethrow;
    }
    await errors.cancel();
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
  }) async {
    final LocalTrackPublication publication;
    try {
      publication = await _room._session.publishTrackStream(
        (tracks ?? mediaSource.broadcastTrack).map((t) => t?.track),
        kind: kind.name,
        options: PublishOptions(
          // Readable and unique; kept for the publication's lifetime, so a
          // republish on a new session (roadmap M5) keeps the same name.
          trackName: '${source.name}-${generateTrackName()}',
          sendEncodings: encodings,
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
    );
    _publications.add(local);
    // Mute changes are announced; the stream replays the current value,
    // which is already part of this announcement.
    local._broadcastingListener = mediaSource.broadcasting.listen(
      (_) => _changed(),
    );
    _changed();
    await _room._announcer.run();
    _room._emit(LocalTrackPublishedEvent(local));
    return local;
  }

  void _changed() {
    if (_room._left) return;
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
/// other participants see [muted] in its [TrackInfo].
class LocalMediaPublication {
  LocalMediaPublication._({
    required this.participant,
    required this.mediaSource,
    required this.source,
    required this.kind,
    required this.publication,
    required this.ownsMediaSource,
    this.simulcast,
  });

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

  /// The simulcast layers announced for the track, or `null`.
  final SimulcastInfo? simulcast;

  bool _unpublished = false;
  LocalMediaPublication? _companion;
  StreamSubscription<bool>? _broadcastingListener;
  StreamSubscription<ScreenShareEndReason>? _endedListener;

  /// The track's SFU name. Stable for the publication's lifetime.
  String get trackName => publication.trackName;

  /// Whether nothing is being sent: the source isn't broadcasting.
  bool get muted => !mediaSource.isBroadcasting;

  /// [muted], replaying the current value to each new listener.
  Stream<bool> get mutedChanges =>
      mediaSource.broadcasting.map((broadcasting) => !broadcasting);

  /// Whether the track is still published.
  bool get isPublished => !_unpublished;

  /// What is announced for this track.
  TrackInfo get info =>
      TrackInfo(kind: kind, source: source, muted: muted, simulcast: simulcast);

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
    await _broadcastingListener?.cancel();
    await _endedListener?.cancel();
    _broadcastingListener = null;
    _endedListener = null;
  }

  @override
  String toString() =>
      'LocalMediaPublication($trackName, ${kind.name}, ${source.name}'
      '${muted ? ', muted' : ''}${_unpublished ? ', unpublished' : ''})';
}
