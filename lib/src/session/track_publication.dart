part of 'sfu_session.dart';

/// The lifecycle of a [LocalTrackPublication] or [RemoteTrackSubscription].
enum SfuTrackState {
  /// Being pushed or pulled.
  pending,

  /// Live on its session.
  active,

  /// Its session failed or closed. Move it to a new session with
  /// [SfuSession.republish] or [SfuSession.resubscribe].
  interrupted,

  /// The push or pull failed (see `error`). It can be retried with
  /// [SfuSession.republish] or [SfuSession.resubscribe].
  failed,

  /// Unpublished or unsubscribed. Terminal.
  closed,
}

/// A local track published to the SFU through an [SfuSession].
///
/// The publication outlives its session: if the session fails, the
/// publication becomes [SfuTrackState.interrupted], and
/// [SfuSession.republish] pushes it to a new session under the same
/// [trackName] with its current [track]. The media layer can swap the
/// capture device, or mute by sending nothing, at any time with
/// [replaceTrack]; [SfuSession.publishTrackStream] wires that to a stream
/// of tracks.
///
/// The publication never stops [track]: capture belongs to the caller.
class LocalTrackPublication {
  LocalTrackPublication._({
    required this.trackName,
    required this.kind,
    required MediaStreamTrack? track,
    required List<SendEncoding> sendEncodings,
    required this.codecPreferences,
  }) : _track = track,
       _sendEncodings = sendEncodings;

  /// The name other participants pull this track by, together with the
  /// publisher's [sessionId]. It stays the same across sessions.
  final String trackName;

  /// `audio` or `video`.
  final String kind;

  List<SendEncoding> _sendEncodings;

  /// The encodings the track is sent with (empty for audio, or for a single
  /// default encoding). [setEncodings] changes them.
  List<SendEncoding> get sendEncodings => _sendEncodings;

  /// The codec MIME types preferred for this track, in order. Empty leaves
  /// the platform's order.
  final List<String> codecPreferences;

  MediaStreamTrack? _track;
  final StateStream<SfuTrackState> _state = StateStream(
    SfuTrackState.pending,
    distinct: true,
  );
  Object? _error;
  SfuSession? _session;
  PeerTransceiver? _transceiver;
  String? _mid;
  Future<void> _replacing = Future.value();
  StreamSubscription<MediaStreamTrack?>? _source;

  /// The track being sent, or null while muted (nothing is sent; the
  /// transceiver and its [mid] stay).
  MediaStreamTrack? get track => _track;

  /// The current state.
  SfuTrackState get state => _state.value;

  /// The state, replaying the current value to each new listener.
  Stream<SfuTrackState> get states => _state.stream;

  /// Why the publication failed or was interrupted, if it did.
  Object? get error => _error;

  /// The session the track is published on (or being pushed to), or null
  /// when it isn't on any session.
  SfuSession? get session => _session;

  /// The publisher's session ID to share through signaling, or null when
  /// the track isn't on any session.
  String? get sessionId => _session?.sessionId;

  /// The transceiver's `mid` on the current session, once pushed. Local to
  /// this session: other participants can't use it.
  String? get mid => _mid;

  /// Replaces the sent track without renegotiation, for example to switch
  /// camera or microphone. [newTrack] must have the same [kind]. Null mutes:
  /// nothing is sent, and the transceiver and its [mid] stay, so unmuting
  /// is another [replaceTrack] with no SFU call.
  ///
  /// Calls are applied in order, and the sender always ends up with the
  /// latest track. Works in any state except closed; a later
  /// [SfuSession.republish] sends the latest track.
  Future<void> replaceTrack(MediaStreamTrack? newTrack) {
    if (newTrack != null && newTrack.kind != kind) {
      throw ArgumentError.value(
        newTrack.kind,
        'newTrack.kind',
        'must be $kind',
      );
    }
    if (state == SfuTrackState.closed) {
      throw StateError('The publication is closed.');
    }
    _track = newTrack;
    final applied = _replacing.then((_) async {
      // Apply whatever is latest by now: a burst of changes settles on the
      // last one.
      await _transceiver?.replaceTrack(_track);
    });
    _replacing = applied.catchError((Object _) {});
    return applied;
  }

  /// Follows [tracks]: each value is applied with [replaceTrack] (null
  /// mutes). Values of another kind, and errors, are ignored. Stops when the
  /// publication closes.
  void _follow(Stream<MediaStreamTrack?> tracks) {
    _source = tracks.listen((track) {
      if (state == SfuTrackState.closed) return;
      if (track != null && track.kind != kind) return;
      unawaited(replaceTrack(track).catchError((Object _) {}));
    }, onError: (Object _) {});
  }

  /// Changes the send encodings without renegotiation, matching layers by
  /// `rid`. Use it to change bitrates or to pause a layer (`active: false`).
  ///
  /// The number of layers and their `rid`s can't change on a live
  /// transceiver; a later [SfuSession.republish] uses [encodings] as given.
  ///
  /// On Windows, flutter_webrtc (1.6) ignores the change: its plugin edits
  /// copies of the encodings and reports success, so the sender keeps the
  /// encodings it was published with until the next republish.
  Future<void> setEncodings(List<SendEncoding> encodings) async {
    if (state == SfuTrackState.closed) {
      throw StateError('The publication is closed.');
    }
    _sendEncodings = List.unmodifiable(encodings);
    await _transceiver?.setEncodings(encodings);
  }

  /// Completes once the SFU is receiving media for this track: the sender
  /// has sent RTP (`outbound-rtp` `bytesSent > 0`).
  ///
  /// Advertise the track to other participants only after this, so their
  /// pulls don't race the first packets (partytracks does the same). Waits
  /// while the publication is [SfuTrackState.pending], and while it is muted
  /// (no RTP flows without a track). Throws an
  /// [SfuSessionException] if it becomes failed, interrupted or closed
  /// first.
  Future<void> whenSending() async {
    var delayMs = 1.0;
    while (true) {
      final transceiver = _transceiver;
      switch (state) {
        case SfuTrackState.failed ||
            SfuTrackState.interrupted ||
            SfuTrackState.closed:
          throw SfuSessionException('the publication is ${state.name}');
        case SfuTrackState.active when transceiver != null:
          try {
            if (await transceiver.hasSentMedia()) {
              if (identical(transceiver, _transceiver)) return;
              continue;
            }
          } catch (_) {
            // Stats may not be available yet.
          }
        case _:
          break;
      }
      delayMs = math.min(delayMs * 1.1, 100);
      await Future<void>.delayed(
        Duration(microseconds: (delayMs * 1000).round()),
      );
    }
  }

  /// Unpublishes the track from its session. See [SfuSession.unpublish].
  Future<void> unpublish() async {
    final session = _session;
    if (session != null) return session.unpublish(this);
    _close();
  }

  void _bind(SfuSession session) {
    _session = session;
    _transceiver = null;
    _mid = null;
    _error = null;
    _setState(SfuTrackState.pending);
  }

  void _activate(SfuSession session, PeerTransceiver transceiver, String mid) {
    if (!identical(_session, session)) return;
    _transceiver = transceiver;
    _mid = mid;
    _setState(SfuTrackState.active);
  }

  /// Leaves [session] in [next] state, if still bound to it.
  void _detach(SfuSession session, SfuTrackState next, [Object? error]) {
    if (!identical(_session, session)) return;
    _session = null;
    _transceiver = null;
    _mid = null;
    if (error != null) _error = error;
    _setState(next);
  }

  void _close() {
    _session = null;
    _transceiver = null;
    _mid = null;
    unawaited(_source?.cancel());
    _source = null;
    _setState(SfuTrackState.closed);
  }

  void _setState(SfuTrackState next) {
    if (!_state.isClosed) _state.set(next);
    if (next == SfuTrackState.closed) unawaited(_state.close());
  }

  @override
  String toString() =>
      'LocalTrackPublication($trackName, $kind, ${state.name}, mid: $_mid'
      '${_track == null ? ', muted' : ''})';
}

/// A remote track pulled from another session through an [SfuSession].
///
/// Like [LocalTrackPublication], it outlives its session: after a failure it
/// is [SfuTrackState.interrupted], and [SfuSession.resubscribe] pulls it
/// again on a new session. [trackStream] then emits the new
/// [MediaStreamTrack].
class RemoteTrackSubscription {
  RemoteTrackSubscription._({
    required String remoteSessionId,
    required this.trackName,
    required SimulcastConfig? simulcast,
  }) : _remoteSessionId = remoteSessionId,
       _simulcast = simulcast;

  /// The pulled track's name.
  final String trackName;

  String _remoteSessionId;
  SimulcastConfig? _simulcast;
  final StateStream<SfuTrackState> _state = StateStream(
    SfuTrackState.pending,
    distinct: true,
  );
  final StateStream<MediaStreamTrack?> _track = StateStream(null);
  Object? _error;
  SfuSession? _session;
  PeerTransceiver? _transceiver;
  String? _mid;

  /// Counts [SfuSession.setPreferredRid] calls, so a retry can tell it was
  /// superseded.
  int _layerRequests = 0;

  /// The publisher's session ID.
  String get remoteSessionId => _remoteSessionId;

  /// The simulcast preferences sent with the pull and its updates, or null
  /// for a track pulled without them.
  SimulcastConfig? get simulcast => _simulcast;

  /// The simulcast layer this subscription asks for, if any.
  String? get preferredRid => _simulcast?.preferredRid;

  /// The current state.
  SfuTrackState get state => _state.value;

  /// The state, replaying the current value to each new listener.
  Stream<SfuTrackState> get states => _state.stream;

  /// Why the subscription failed or was interrupted, if it did.
  Object? get error => _error;

  /// The session the track is pulled on, or null.
  SfuSession? get session => _session;

  /// The transceiver's `mid` on [session], once pulled.
  String? get mid => _mid;

  /// The received track, once pulled. It stays set while the subscription is
  /// interrupted (showing the last frame), and is null after it closes.
  MediaStreamTrack? get track => _track.value;

  /// The received track: replays the current one to each new listener, then
  /// emits each new one (for example after [SfuSession.resubscribe]).
  Stream<MediaStreamTrack> get trackStream =>
      _track.stream.where((t) => t != null).cast<MediaStreamTrack>();

  /// Asks the SFU for another simulcast layer through `tracks/update`. See
  /// [SfuSession.setPreferredRid].
  Future<void> setPreferredRid(String rid) {
    final session = _session;
    if (session == null) {
      if (state == SfuTrackState.closed) {
        throw StateError('The subscription is closed.');
      }
      _simulcast = _withRid(rid);
      return Future.value();
    }
    return session.setPreferredRid(this, rid);
  }

  /// Unsubscribes. See [SfuSession.unsubscribe].
  Future<void> unsubscribe() async {
    final session = _session;
    if (session != null) return session.unsubscribe(this);
    _close();
  }

  SimulcastConfig _withRid(String rid) => SimulcastConfig(
    preferredRid: rid,
    priorityOrdering: _simulcast?.priorityOrdering,
    ridNotAvailable:
        _simulcast?.ridNotAvailable ?? SimulcastOrdering.asciibetical,
  );

  void _bind(SfuSession session) {
    _session = session;
    _transceiver = null;
    _mid = null;
    _error = null;
    _setState(SfuTrackState.pending);
  }

  void _activate(SfuSession session, PeerTransceiver transceiver, String mid) {
    if (!identical(_session, session)) return;
    _transceiver = transceiver;
    _mid = mid;
    final track = transceiver.receiverTrack;
    if (!_track.isClosed && track != null) _track.set(track);
    _setState(SfuTrackState.active);
  }

  void _detach(SfuSession session, SfuTrackState next, [Object? error]) {
    if (!identical(_session, session)) return;
    _session = null;
    _transceiver = null;
    _mid = null;
    if (error != null) _error = error;
    _setState(next);
  }

  void _close() {
    _session = null;
    _transceiver = null;
    _mid = null;
    if (!_track.isClosed) {
      _track.set(null);
      unawaited(_track.close());
    }
    _setState(SfuTrackState.closed);
  }

  void _setState(SfuTrackState next) {
    if (!_state.isClosed) _state.set(next);
    if (next == SfuTrackState.closed) unawaited(_state.close());
  }

  @override
  String toString() =>
      'RemoteTrackSubscription($_remoteSessionId/$trackName, ${state.name}, '
      'mid: $_mid)';
}
