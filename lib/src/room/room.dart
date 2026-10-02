/// @docImport 'cloudflare_realtime.dart';
/// @docImport '../rendering/participant_video_view.dart';
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, immutable, kIsWeb, mapEquals;
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack, RTCPeerConnectionState;

import '../audio/audio_route.dart';
import '../audio/call_audio.dart';
import '../audio/call_interruption.dart';
import '../audio/remote_audio_sink.dart';
import '../background/call_background.dart';
import '../background/camera_pause.dart';
import '../broker/broker_client.dart';
import '../calls/system_calls.dart';
import '../data/data_channel_manager.dart';
import '../media/constraints.dart';
import '../media/device_media_source.dart';
import '../media/local_media_source.dart';
import '../media/media_backend.dart';
import '../media/media_device_list.dart';
import '../media/media_errors.dart';
import '../media/media_types.dart';
import '../media/screen_share_source.dart';
import '../quality/active_speaker_config.dart';
import '../quality/active_speaker_monitor.dart';
import '../quality/layer_pausing.dart';
import '../quality/layer_selection.dart';
import '../quality/layer_selection_controller.dart';
import '../quality/simulcast_ladder.dart';
import '../reconnect/app_lifecycle_source.dart';
import '../reconnect/backoff.dart';
import '../reconnect/network_change_source.dart';
import '../reconnect/reconnect_trigger.dart';
import '../rendering/renderable_track.dart';
import '../session/publish_options.dart';
import '../session/sfu_session.dart';
import '../session/sfu_session_events.dart';
import '../session/track_name.dart';
import '../signaling/participant_state.dart';
import '../signaling/signaling.dart';
import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'participant_diff.dart';
import 'room_audio_levels.dart';
import 'room_options.dart';
import 'screen_share_presets.dart';
import 'simulcast_hint.dart';

part 'local_participant.dart';
part 'room_audio.dart';
part 'room_publish_quality.dart';
part 'room_background.dart';
part 'remote_participant.dart';
part 'remote_track_layers.dart';
part 'room_data.dart';
part 'room_events.dart';
part 'room_reconnection.dart';
part 'room_speakers.dart';
part 'room_system_call.dart';
part 'screen_share_watchdog.dart';

/// Connects a new [SfuSession] through a broker: the room's session
/// factory, used when joining and on every re-session.
typedef _Connector = Future<SfuSession> Function(
  BrokerClient broker,
  SfuSessionOptions options,
);

/// A call: one SFU session tied to one room on the app's [Signaling].
///
/// Create one with [CloudflareRealtime.join]. The room:
///
/// - announces the local participant's state (`sessionId`, published
///   tracks, mute flags, metadata) through [signaling], and updates it as
///   [localParticipant] publishes, mutes and unpublishes;
/// - diffs the other participants' states into [participants] and
///   [events], and **pulls only what is subscribed**: audio by default,
///   video when the UI asks (see [RoomOptions.autoSubscribe],
///   [RemoteTrackPublication.subscribe] and [ParticipantVideoView]);
/// - follows remote participants to their new session when they reconnect,
///   and closes pulls of tracks that go away;
/// - reports [connectionState], driven by the SFU session;
/// - **replaces a broken session** (`docs/design.md` §8): when the session
///   fails, stays disconnected, or is reported gone, the room connects a
///   new one, moves its tracks and DataChannels onto it under the same
///   names (local capture keeps running), announces the new session ID and
///   pulls its subscriptions again. See [RoomOptions.reconnect],
///   [RoomReconnectingEvent] and [RoomReconnectedEvent];
/// - picks each pulled video's simulcast layer from the size of the views
///   that show it ([layerReporter]), and detects who is speaking
///   ([activeSpeakers]).
class Room {
  Room._({
    required this.roomId,
    required this.signaling,
    required this.options,
    required this._session,
    required this._broker,
    required this._connect,
    required this._mediaBackend,
    required this._wrapTrack,
    required this._networkChanges,
    required this._appLifecycle,
    required String participantId,
    Map<String, Object?>? metadata,
  }) {
    localParticipant = LocalParticipant._(this, participantId, metadata);
  }

  /// The room's ID, as passed to [CloudflareRealtime.join]. It is also sent
  /// to the broker in `X-Realtime-Room`.
  final String roomId;

  /// The signaling transport the room announces on.
  final Signaling signaling;

  /// The options the room was joined with.
  final RoomOptions options;

  /// The local participant: publish, mute and unpublish here.
  late final LocalParticipant localParticipant;

  /// DataChannels between participants: publish a channel, or subscribe to
  /// another participant's (`docs/design.md` §9).
  late final RoomData data = RoomData._(this);

  // The current session. It changes only in [_replaceSession].
  SfuSession _session;
  final BrokerClient _broker;
  final _Connector _connect;
  final MediaBackend _mediaBackend;
  final MediaStreamWrapper _wrapTrack;
  final NetworkChangeSource? _networkChanges;
  final AppLifecycleSource? _appLifecycle;

  final Map<String, RemoteParticipant> _remotes = {};
  List<ParticipantState> _signaled = const [];
  // Every SFU session a remote participant announced, to attribute
  // DataChannel messages. Null marks a session claimed by more than one
  // participant.
  final Map<String, String?> _sessionOwners = {};
  final StateStream<List<RemoteParticipant>> _participants = StateStream(
    const [],
  );
  final StateStream<RoomConnectionState> _state = StateStream(
    RoomConnectionState.connecting,
    distinct: true,
  );
  final StreamController<RoomEvent> _events = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  // Listeners on the current session only; replaced with it.
  final List<StreamSubscription<Object?>> _sessionListeners = [];
  late final _Reconnection _reconnection = _Reconnection(this);
  late final CoalescingRunner _announcer = CoalescingRunner(_announce);
  // Layer selection and active speaker (M4): remote_track_layers.dart and
  // room_speakers.dart.
  late final _RoomLayers _layers = _RoomLayers(this);
  late final _RoomSpeakers _speakers = _RoomSpeakers(this);
  // Pausing the local layers no one pulls (M12): room_publish_quality.dart.
  late final _RoomLayerPausing _pausing = _RoomLayerPausing(this);
  // Remote audio playback (the web's audio elements): room_audio.dart.
  late final _RoomAudio _audio = _RoomAudio();
  // Background service, interruptions, camera pauses: room_background.dart.
  late final _RoomBackground _background = _RoomBackground(this);
  // The attached system call (CallKit, Telecom): room_system_call.dart.
  late final _RoomSystemCall _systemCall = _RoomSystemCall(this);
  ParticipantState? _announced;
  // While set, [_announce] does nothing: a re-session announces the new
  // session itself, once its tracks are on it.
  bool _holdAnnouncements = false;
  MediaDeviceList? _deviceList;
  bool _left = false;
  Future<void>? _leaving;
  // The last session whose failure the room handled.
  SfuSession? _failureHandled;
  // Operations (publishes) waiting for a re-session to run on its new
  // session ([_onSessionWithRetry]). The re-session connects that session
  // for them before it ends, even with RoomOptions.connectEarly off: the SFU
  // sometimes never serves a track pushed onto a session that hasn't
  // connected yet (docs/design.md §8.1, Publishing late).
  int _waitingForNewSession = 0;

  /// The SFU session that carries this room's media now.
  ///
  /// It is **replaced** when the room reconnects ([RoomReconnectedEvent]),
  /// so read it when needed rather than keeping it. For advanced use
  /// (stats). Publish and subscribe through [localParticipant],
  /// [RemoteTrackPublication] and [data] instead of calling it directly:
  /// only what the room published or subscribed moves to a new session.
  SfuSession get session => _session;

  /// The other participants that have an SFU session, in the order they
  /// appeared. Replays the current list to each new listener, and emits a
  /// new list whenever anyone joins, leaves or changes (tracks, mute state,
  /// metadata, session). Completes after [leave].
  Stream<List<RemoteParticipant>> get participants => _participants.stream;

  /// The other participants, now.
  List<RemoteParticipant> get currentParticipants => _participants.value;

  /// The remote participant with [participantId], if present.
  RemoteParticipant? participant(String participantId) =>
      _remotes[participantId];

  /// What happens in the room, as it happens. A broadcast stream; it does
  /// not replay past events. Completes after [leave].
  Stream<RoomEvent> get events => _events.stream;

  /// The connection state, replaying the current value to each new
  /// listener. Completes after [leave].
  Stream<RoomConnectionState> get connectionState => _state.stream;

  /// The current connection state.
  RoomConnectionState get currentConnectionState => _state.value;

  /// Why the current SFU session failed, or `null` if it hasn't. A new
  /// session after a reconnection starts without a failure.
  SfuSessionFailure? get failure => _session.failure;

  /// Whether [leave] has been called.
  bool get hasLeft => _left;

  /// Whether the room is replacing its session now (between a
  /// [RoomReconnectingEvent] and a [RoomReconnectedEvent] or
  /// [RoomReconnectFailedEvent]).
  bool get isReconnecting => _reconnection.isRunning;

  /// Replaces the SFU session now, and completes with whether the room is
  /// connected on a new session afterwards.
  ///
  /// For a "reconnect" button after the room gave up
  /// ([RoomReconnectFailedEvent]), or when the app knows better than the
  /// automatic triggers. It works with automatic reconnection off too. The
  /// attempt starts without a backoff delay and with a fresh
  /// [ReconnectOptions.backoff] budget. While a reconnection is already
  /// running, it skips that reconnection's current wait and returns its
  /// outcome.
  ///
  /// Throws a [StateError] after [leave].
  Future<bool> reconnect() {
    _checkNotLeft();
    return _reconnection.manual();
  }

  /// **Debug and demo only:** makes the current SFU session fail as in a
  /// network drop (its peer connection is closed; see
  /// [SfuSession.debugSimulateFailure]), so the room's recovery can be
  /// seen without pulling a cable. With automatic reconnection on, the room
  /// then replaces the session like after a real failure.
  ///
  /// It works in every build mode, so demos in profile or release builds
  /// can use it; keep it out of production UI. Throws a [StateError] after
  /// [leave].
  void debugSimulateConnectionFailure() {
    _checkNotLeft();
    _session.debugSimulateFailure();
  }

  /// Where video views report their on-screen size, so the room pulls the
  /// simulcast layer that fits (`docs/design.md` §6.1).
  ///
  /// [ParticipantVideoView.remote] reports here by default. Custom video
  /// widgets can wrap themselves in a `SimulcastLayerReporter` with this
  /// reporter and [RemoteTrackPublication.id]. The biggest visible view of
  /// a track wins; when all of its views are hidden, the track drops to its
  /// lowest layer and, after [RoomOptions.hiddenVideoLinger], its pull is
  /// released. [RemoteTrackPublication.setPreferredLayer] overrides the
  /// automatic choice.
  LayerDemandReporter get layerReporter => _layers;

  /// The participants speaking now, loudest first, by participant ID
  /// (`docs/design.md` §7). Includes the local participant while their
  /// microphone is unmuted and they speak. Replays the current list to each
  /// new listener and emits on every change. Empty when
  /// [RoomOptions.activeSpeaker] is `null`. Completes after [leave].
  Stream<List<String>> get activeSpeakers => _speakers.monitor.speakers;

  /// The current value of [activeSpeakers].
  List<String> get currentActiveSpeakers => _speakers.monitor.currentSpeakers;

  /// The participant to put on the stage: the loudest speaker, switching
  /// only after [ActiveSpeakerConfig.dominantSwitchTime], and kept while
  /// everyone is silent. The local participant only when
  /// [ActiveSpeakerConfig.localCanBeDominant]. `null` until someone spoke,
  /// and after the dominant speaker left. Replays the current value.
  Stream<String?> get dominantSpeaker => _speakers.monitor.dominantSpeaker;

  /// The current value of [dominantSpeaker].
  String? get currentDominantSpeaker =>
      _speakers.monitor.currentDominantSpeaker;

  /// Whether the browser is refusing to play remote audio until the user
  /// interacts with the page (its autoplay policy). Show a "click to enable
  /// audio" prompt that calls [startAudio] while it is `true`.
  ///
  /// Only the web can block: native platforms play pulled audio by
  /// themselves, so this is always `false` there.
  bool get audioPlaybackBlocked => _audio.blocked.value;

  /// [audioPlaybackBlocked], replaying the current value to each new
  /// listener and then emitting its changes. Completes after [leave].
  Stream<bool> get audioPlaybackBlockedChanges => _audio.blocked.stream;

  /// Starts remote audio that the browser refused to autoplay
  /// ([audioPlaybackBlocked]). Completes with whether audio plays now.
  ///
  /// **Call it directly from a user gesture** (a button's `onPressed`), with
  /// nothing awaited before it: browsers only allow playback in response
  /// to one. On native platforms it does nothing and completes with `true`.
  Future<bool> startAudio() => _audio.start();

  /// Whether [setAudioOutputDevice] works here: on native platforms, and in
  /// browsers that support `HTMLMediaElement.setSinkId` (not all do).
  bool get canSelectAudioOutput => _audio.canSelectOutput;

  /// Plays remote audio through the output device [deviceId], a
  /// [MediaDeviceKind.audioOutput] device's [MediaDevice.deviceId].
  ///
  /// On the web it applies to this room's audio elements (now and later),
  /// through `setSinkId`. On native platforms it calls `flutter_webrtc`'s
  /// `Helper.selectAudioOutput`, which switches the whole app's output.
  /// Throws an [UnsupportedError] where [canSelectAudioOutput] is `false`.
  Future<void> setAudioOutputDevice(String deviceId) {
    _checkNotLeft();
    return _audio.setOutput(deviceId);
  }

  /// Whether this platform routes call audio ([audioRoutes],
  /// [selectAudioRoute], [setSpeakerphone]): on phones (Android and iOS).
  /// Desktops and browsers choose a device with [setAudioOutputDevice].
  bool get canSelectAudioRoute => CallAudio.instance.supported;

  /// The places the phone can play call audio now: its speaker, its
  /// earpiece, connected headsets. Only routes the platform will honour are
  /// listed: no earpiece while a Bluetooth headset is connected. On iOS,
  /// stereo-only Bluetooth and AirPlay appear only while they are the route
  /// (Apple's route picker chooses them).
  ///
  /// App-wide, like the route itself; empty where [canSelectAudioRoute] is
  /// `false`. Replays the current list.
  Stream<List<AudioRoute>> get audioRoutes => CallAudio.instance.routes.stream;

  /// The current [audioRoutes].
  List<AudioRoute> get currentAudioRoutes => CallAudio.instance.routes.value;

  /// The route call audio plays on now, as the platform reports it.
  AudioRoute? get currentAudioRoute => CallAudio.instance.current.value;

  /// [currentAudioRoute], replaying the current value, then its changes.
  Stream<AudioRoute?> get audioRouteChanges =>
      CallAudio.instance.current.stream;

  /// Plays call audio on [route], one of [audioRoutes]. The choice sticks
  /// until a new headset connects or the route goes away; then the route is
  /// chosen automatically again ([RoomOptions.speakerphone]).
  ///
  /// It is a request: [audioRouteChanges] reports when it takes effect.
  /// Throws an [AudioRouteUnavailableException] if the platform refuses
  /// it, and an [UnsupportedError] where [canSelectAudioRoute] is `false`.
  Future<void> selectAudioRoute(AudioRoute route) {
    _checkNotLeft();
    return CallAudio.instance.select(route);
  }

  /// Whether [setSpeakerphone] works here; the same as
  /// [canSelectAudioRoute].
  bool get canSetSpeakerphone => canSelectAudioRoute;

  /// Whether call audio plays on the speaker now.
  bool get speakerphone => currentAudioRoute?.kind == AudioRouteKind.speaker;

  /// [speakerphone], replaying the current value, then its changes.
  Stream<bool> get speakerphoneChanges => audioRouteChanges
      .map((route) => route?.kind == AudioRouteKind.speaker)
      .distinct();

  /// Plays call audio on the speaker ([on]) or the earpiece, the same way
  /// on Android and iOS. A connected headset comes first either way, and a
  /// route picked with [selectAudioRoute] is dropped. App-wide, like the
  /// platforms' own switches.
  ///
  /// Throws an [UnsupportedError] where [canSetSpeakerphone] is `false`.
  Future<void> setSpeakerphone(bool on) {
    _checkNotLeft();
    return CallAudio.instance.setSpeakerphone(on);
  }

  /// Whether this platform reports call interruptions ([audioInterruption]):
  /// on phones. Elsewhere [audioInterruption] stays `null`.
  bool get canDetectAudioInterruptions => CallAudio.instance.supported;

  /// What has taken the call's audio away (a phone call, Siri, another
  /// app), or `null` while the call has it (`docs/design.md` §4.7). See
  /// [CallInterruptedEvent]. App-wide, like the audio session.
  CallInterruptionReason? get audioInterruption =>
      CallAudio.instance.interruption.value;

  /// [audioInterruption], replaying the current value, then its changes.
  Stream<CallInterruptionReason?> get audioInterruptionChanges =>
      CallAudio.instance.interruption.stream;

  /// Takes the call's audio back after an interruption the platform didn't
  /// end, for example after another app kept the audio focus on Android.
  /// The call also does this by itself when the app returns to the
  /// foreground. Completes with whether the call has its audio: `false`
  /// while something with priority (a phone call) still holds it; `true`
  /// when it wasn't interrupted, and on desktops and in browsers.
  Future<bool> resumeAudio() {
    _checkNotLeft();
    return CallAudio.instance.resume();
  }

  /// Whether the proximity sensor is on now: the screen turns off near the
  /// ear. Only while call audio plays on the earpiece and no room has video
  /// ([RoomOptions.proximitySensor]); `false` on desktops, in browsers and
  /// on devices without the sensor.
  bool get proximitySensorActive => CallAudio.instance.proximity.value;

  /// [proximitySensorActive], replaying the current value, then its
  /// changes.
  Stream<bool> get proximitySensorChanges =>
      CallAudio.instance.proximity.stream;

  /// Whether this platform reports a camera paused by the system
  /// ([cameraPause]): iOS. Android keeps the camera running in the
  /// background under the foreground service
  /// ([RoomOptions.foregroundService]).
  bool get canDetectCameraPause => CallBackground.instance.reportsCameraPause;

  /// Why the system paused the device's camera (most often: the app is in
  /// the background on iOS), or `null` while it runs (`docs/design.md`
  /// §4.7). See [LocalCameraPausedEvent].
  CameraPauseReason? get cameraPause =>
      CallBackground.instance.cameraPause.value;

  /// [cameraPause], replaying the current value, then its changes.
  Stream<CameraPauseReason?> get cameraPauseChanges =>
      CallBackground.instance.cameraPause.stream;

  /// The system call (CallKit, Telecom; `docs/design.md` §4.8) this room
  /// follows, from [attachSystemCall], or `null`.
  SystemCall? get systemCall => _systemCall.call;

  /// Ties this room to [call], a call in the phone's own call UI
  /// ([SystemCalls], `docs/design.md` §4.8):
  ///
  /// - the system's mute button and the room's microphone publication stay
  ///   in step, both ways (when they disagree at attach time, or a
  ///   microphone is published later, both end up muted);
  /// - with [leaveWhenEnded] (default `true`), the room leaves when the
  ///   call ends, for example from the lock screen or a headset button;
  /// - with [endWhenLeft] (default `true`), [leave] ends the call.
  ///
  /// While the call is on hold, the room's audio is interrupted
  /// ([CallInterruptionReason.held]). Attaching another call replaces this
  /// one. Throws a [StateError] after [leave].
  void attachSystemCall(
    SystemCall call, {
    bool leaveWhenEnded = true,
    bool endWhenLeft = true,
  }) {
    _checkNotLeft();
    if (call.isEnded) throw StateError('The call ${call.id} has ended.');
    _systemCall.attach(
      call,
      leaveWhenEnded: leaveWhenEnded,
      endWhenLeft: endWhenLeft,
    );
  }

  /// Stops following the system call: it no longer ends with the room, nor
  /// the room with it.
  void detachSystemCall() => _systemCall.detach();

  /// Leaves the room and releases everything it holds.
  ///
  /// In order: ends an attached system call ([attachSystemCall]'s
  /// `endWhenLeft`), stops listening to signaling and leaves it (so others stop
  /// pulling), unpublishes the local tracks, closes the SFU session,
  /// disposes the media sources the room created (camera, microphone and
  /// screen share; sources passed to [LocalParticipant.publishMediaSource]
  /// are the app's), releases remote tracks, and disposes the broker
  /// client. Failures along the way are ignored, so the room always ends
  /// [RoomConnectionState.disconnected]. Safe to call more than once.
  Future<void> leave() => _leaving ??= _leave();

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  MediaDeviceList get _devices =>
      _deviceList ??= MediaDeviceList(backend: _mediaBackend);

  void _checkNotLeft() {
    if (_left) throw StateError('The room "$roomId" was left.');
  }

  void _emit(RoomEvent event) {
    if (!_events.isClosed) _events.add(event);
    _noteVideo();
  }

  // Tells call audio routing once this room has video, sent or received:
  // a voice call moves from the earpiece to the speaker then (§4.6).
  bool _hasVideo = false;
  void _noteVideo() {
    if (_hasVideo || _left) return;
    final video =
        localParticipant.trackPublications.any(
          (p) => p.kind == TrackKind.video,
        ) ||
        _remotes.values.any(
          (r) => r.trackPublications.any(
            (p) => p.kind == TrackKind.video && p.isSubscribed,
          ),
        );
    if (!video) return;
    _hasVideo = true;
    CallAudio.instance.videoStarted(this);
  }

  Future<void> _join() async {
    // Phones: route call audio the same way on Android and iOS (§4.6).
    // Best effort: a failure here must not fail the join.
    try {
      await CallAudio.instance.join(
        this,
        speakerphone: options.speakerphone,
        proximitySensor: options.proximitySensor,
      );
    } catch (error) {
      _emit(RoomErrorEvent('audioRouting', error));
    }
    // Connect the peer connection while signaling joins, so the SFU keeps
    // the session even if the first publish waits on a prompt (§8.1).
    final early = options.connectEarly ? _connectEarly(_session) : null;
    final self = localParticipant.state;
    await signaling.join(roomId, self);
    _announced = self;
    await early;
    // Take the session's state now, so the room is returned connected (or
    // connecting, after an early connect). The failures stream replays a
    // failure that already happened, such as a 410 on the early connect.
    _onSessionState(_session, _session.currentConnectionState);
    _listenToSession(_session);
    _subscriptions.add(
      signaling.participants.listen(
        _onParticipants,
        onError: (Object error) =>
            _emit(RoomErrorEvent('signaling.participants', error)),
      ),
    );
    if (_networkChanges case final source?) {
      _subscriptions.add(
        source.changes.listen(
          (_) => _reconnection.networkChanged(),
          onError: (Object _) {},
        ),
      );
    }
    if (_appLifecycle case final source?) {
      _subscriptions.add(
        source.states.listen(_reconnection.lifecycle, onError: (Object _) {}),
      );
    }
    _speakers.start();
    _background.start();
  }

  // ---------------------------------------------------------------------------
  // The session lifecycle
  // ---------------------------------------------------------------------------

  /// Makes [next] the room's session: stops following the old one, follows
  /// [next], and tells the room's session-bound components to re-bind. The
  /// only place [session] changes. Returns the previous session, which the
  /// caller closes.
  ///
  /// It runs when a re-session has created the new session, **before**
  /// tracks and DataChannels are moved onto it; [RoomReconnectedEvent]
  /// marks the end of a successful re-session. A failed attempt can be
  /// followed by another replacement.
  ///
  /// Components bound to the session re-bind synchronously here: active
  /// speaker (`_onSessionReplaced`, room_speakers.dart). Add a call here
  /// for any new one.
  SfuSession _replaceSession(SfuSession next) {
    final previous = _session;
    _stopListeningToSession();
    _session = next;
    _listenToSession(next);
    _onSessionReplaced();
    return previous;
  }

  void _listenToSession(SfuSession session) {
    _sessionListeners
      ..add(session.connectionState.listen((s) => _onSessionState(session, s)))
      ..add(session.failures.listen((f) => _onSessionFailure(session, f)));
  }

  void _stopListeningToSession() {
    for (final listener in _sessionListeners) {
      unawaited(listener.cancel());
    }
    _sessionListeners.clear();
  }

  /// Connects [session]'s peer connection before anything is published
  /// ([RoomOptions.connectEarly], [SfuSession.establishConnection]). Never
  /// throws: a gone session fails and the re-session replaces it; after any
  /// other error the session stays usable, and the first publish or pull
  /// negotiates as it would have anyway.
  Future<void> _connectEarly(SfuSession session) async {
    try {
      await session.establishConnection();
    } catch (error) {
      if (!_left && session.isUsable) {
        _emit(RoomErrorEvent('connectEarly', error));
      }
    }
  }

  void _setState(RoomConnectionState state) {
    if (_state.isClosed || _state.value == state) return;
    _state.set(state);
    _emit(RoomConnectionStateChangedEvent(state));
  }

  void _onSessionState(SfuSession session, SfuConnectionState state) {
    if (_left || !identical(session, _session)) return;
    _reconnection.sessionState(state);
    // While re-sessioning (or after giving up), the reconnection owns the
    // room's state; a failure is handled in [_onSessionFailure].
    if (_reconnection.isRunning || _reconnection.gaveUp) return;
    if (session.failure != null) return;
    _setState(switch (state) {
      // Nothing negotiated yet: the session is usable. Once something is
      // (an early connect at join), the connection is on its way.
      SfuConnectionState.initial =>
        session.hasNegotiated
            ? RoomConnectionState.connecting
            : RoomConnectionState.connected,
      SfuConnectionState.connecting => RoomConnectionState.connecting,
      SfuConnectionState.connected => RoomConnectionState.connected,
      SfuConnectionState.disconnected => RoomConnectionState.reconnecting,
      SfuConnectionState.failed ||
      SfuConnectionState.closed => RoomConnectionState.disconnected,
    });
  }

  void _onSessionFailure(SfuSession session, SfuSessionFailure failure) {
    if (_left || !identical(session, _session)) return;
    // Reported once per session: by its failures stream, or earlier by an
    // operation that saw it fail ([_onSessionWithRetry]).
    if (identical(_failureHandled, session)) return;
    _failureHandled = session;
    _emit(RoomSessionFailedEvent(failure));
    _reconnection.sessionFailed(failure);
    if (!_reconnection.isRunning) _setState(RoomConnectionState.disconnected);
  }

  /// Runs [operation] (a publish) on the room's session, waiting for a
  /// running re-session first. If it fails because that session failed
  /// under it (most often the SFU expiring a session whose peer connection
  /// never connected: `SessionGoneException`, HTTP 410), it waits for the
  /// room's re-session and runs [operation] once more, on the new session.
  /// A second failure, a re-session that gives up, or automatic
  /// reconnection being off surfaces the error. The SFU's rejection of the
  /// track itself ([SfuTrackException], [SfuDataChannelException]) and
  /// errors on a session that is still usable are thrown at once.
  Future<T> _onSessionWithRetry<T>(
    Future<T> Function(SfuSession session) operation,
  ) async {
    if (isReconnecting) {
      await _waitForNewSession();
      _checkNotLeft();
    }
    final session = _session;
    try {
      return await operation(session);
    } catch (error) {
      if (_left ||
          error is SfuTrackException ||
          error is SfuDataChannelException) {
        rethrow;
      }
      final failure = session.failure;
      final replaced = !identical(_session, session) || isReconnecting;
      if (failure == null && !(session.isClosed && replaced)) rethrow;
      // The session's failure reaches the room through a stream, which may
      // not have delivered it yet: start the re-session now.
      if (failure != null) _onSessionFailure(session, failure);
      await _waitForNewSession();
      if (_left || identical(_session, session) || !_session.isUsable) {
        rethrow;
      }
    }
    return operation(_session);
  }

  /// [_whenNotReconnecting], for an operation that runs on the new session
  /// next: the re-session connects that session before it ends.
  Future<void> _waitForNewSession() async {
    _waitingForNewSession++;
    try {
      await _whenNotReconnecting();
    } finally {
      _waitingForNewSession--;
    }
  }

  /// Completes once no reconnection is running, so an operation that needs
  /// a usable session (publishing, subscribing to data) runs on the new
  /// one rather than failing on the old.
  Future<void> _whenNotReconnecting() async {
    for (
      var episode = _reconnection.episode;
      episode != null;
      episode = _reconnection.episode
    ) {
      await episode;
    }
  }

  /// Announces the local participant's current state, if it changed.
  /// Runs through [_announcer], so updates never overlap and a burst of
  /// changes becomes at most one more update.
  Future<void> _announce() async {
    if (_left || _holdAnnouncements) return;
    final state = localParticipant.state;
    if (state == _announced) return;
    try {
      await signaling.update(state);
      _announced = state;
    } catch (error) {
      if (!_left) _emit(RoomErrorEvent('signaling.update', error));
    }
  }

  void _onParticipants(List<ParticipantState> list) {
    if (_left) return;
    final self = localParticipant.participantId;
    final others = [
      for (final p in list)
        if (p.participantId != self && p.sessionId != _session.sessionId) p,
    ];
    final diff = diffParticipants(_signaled, others);
    _signaled = others;
    // Layer demand changes aren't part of the diff.
    _pausing.onParticipants(others);
    if (diff.isEmpty) return;
    for (final state in [
      ...diff.joined,
      for (final change in diff.updated) change.current,
    ]) {
      final sessionId = state.sessionId!;
      final owner = _sessionOwners[sessionId];
      _sessionOwners[sessionId] =
          !_sessionOwners.containsKey(sessionId) || owner == state.participantId
          ? state.participantId
          : null;
    }

    for (final state in diff.left) {
      final remote = _remotes.remove(state.participantId);
      if (remote == null) continue;
      for (final publication in remote._removeAll()) {
        _emit(TrackUnpublishedEvent(publication));
      }
      remote._close();
      _speakers.removeParticipant(remote.participantId);
      _emit(ParticipantLeftEvent(remote));
    }
    for (final state in diff.joined) {
      final remote = RemoteParticipant._(this, state);
      _remotes[state.participantId] = remote;
      _emit(ParticipantJoinedEvent(remote));
      remote._addTracks(state.tracks);
    }
    for (final change in diff.updated) {
      _remotes[change.participantId]?._apply(change);
    }
    _participants.set(List.unmodifiable(_remotes.values));
  }

  /// The participant that announced [sessionId], or `null` if none did (or
  /// several did). Sessions a participant used before reconnecting still
  /// map to them, so late messages keep their sender.
  String? _participantIdForSession(String? sessionId) =>
      sessionId == null ? null : _sessionOwners[sessionId];

  Future<void> _leave() async {
    _left = true;
    // The system's call UI goes away first (attachSystemCall's endWhenLeft).
    _systemCall.dispose();
    // Stop the stats polls and the layer timers before anything else.
    _speakers.stop();
    _layers.dispose();
    _pausing.dispose();
    // A reconnection in progress notices [_left] and stops; a session it
    // was connecting is closed by it.
    _reconnection.dispose();
    _stopListeningToSession();
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    await _speakers.dispose();
    // Stop remote audio first: nothing should play once leave() starts.
    await _audio.dispose();
    try {
      await CallAudio.instance.leave(this);
    } catch (_) {
      // Best effort.
    }
    await _background.dispose();

    // Remote tracks and DataChannel subscriptions: closing the session
    // releases them, so only the local state is torn down here.
    data._disposeForLeave();
    final remotes = _remotes.values.toList();
    _remotes.clear();
    for (final remote in remotes) {
      remote._disposeForLeave();
    }
    if (!_participants.isClosed) _participants.set(const []);

    try {
      await signaling.leave();
    } catch (_) {
      // Best effort: the room is going away either way.
    }

    await localParticipant._unpublishAllForLeave();
    await _session.close();
    try {
      await _deviceList?.dispose();
    } catch (_) {
      // Best effort.
    }
    _broker.dispose();

    _setState(RoomConnectionState.disconnected);
    await localParticipant._changes.close();
    await _participants.close();
    await _state.close();
    await _events.close();
  }

  @override
  String toString() =>
      'Room($roomId, ${_state.value.name}, '
      '${localParticipant.participantId}, ${_remotes.length} remote)';
}

/// Joins a room: signaling with the session's ID, then starts following
/// it. [Room] is created only here and in [CloudflareRealtime.join].
///
/// Internal: not exported from the package barrel.
Future<Room> joinRoom({
  required String roomId,
  required Signaling signaling,
  required RoomOptions options,
  required SfuSession session,
  required BrokerClient broker,
  required Future<SfuSession> Function(
    BrokerClient broker,
    SfuSessionOptions options,
  )
  connect,
  required MediaBackend mediaBackend,
  required MediaStreamWrapper wrapTrack,
  NetworkChangeSource? networkChanges,
  AppLifecycleSource? appLifecycle,
  required String participantId,
  Map<String, Object?>? metadata,
}) async {
  final room = Room._(
    roomId: roomId,
    signaling: signaling,
    options: options,
    session: session,
    broker: broker,
    connect: connect,
    mediaBackend: mediaBackend,
    wrapTrack: wrapTrack,
    networkChanges: networkChanges,
    appLifecycle: appLifecycle,
    participantId: participantId,
    metadata: metadata,
  );
  await room._join();
  return room;
}
