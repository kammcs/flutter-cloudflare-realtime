/// @docImport 'cloudflare_realtime.dart';
/// @docImport '../rendering/participant_video_view.dart';
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack;

import '../broker/broker_client.dart';
import '../media/constraints.dart';
import '../media/device_media_source.dart';
import '../media/local_media_source.dart';
import '../media/media_backend.dart';
import '../media/media_device_list.dart';
import '../media/media_errors.dart';
import '../media/media_types.dart';
import '../media/screen_share_source.dart';
import '../reconnect/backoff.dart';
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
import 'room_options.dart';
import 'simulcast_hint.dart';

part 'local_participant.dart';
part 'remote_participant.dart';
part 'room_events.dart';

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
/// - reports [connectionState], driven by the SFU session.
///
/// Automatic reconnection is roadmap M5. Until then, a failed session makes
/// the room [RoomConnectionState.disconnected] with a [failure], and the app
/// should [leave] and join again.
class Room {
  Room._({
    required this.roomId,
    required this.signaling,
    required this.options,
    required this._session,
    required this._broker,
    required this._mediaBackend,
    required this._wrapTrack,
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

  final SfuSession _session;
  final BrokerClient _broker;
  final MediaBackend _mediaBackend;
  final MediaStreamWrapper _wrapTrack;

  final Map<String, RemoteParticipant> _remotes = {};
  List<ParticipantState> _signaled = const [];
  final StateStream<List<RemoteParticipant>> _participants = StateStream(
    const [],
  );
  final StateStream<RoomConnectionState> _state = StateStream(
    RoomConnectionState.connecting,
    distinct: true,
  );
  final StreamController<RoomEvent> _events = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions = [];
  late final CoalescingRunner _announcer = CoalescingRunner(_announce);
  ParticipantState? _announced;
  MediaDeviceList? _deviceList;
  bool _left = false;
  Future<void>? _leaving;

  /// The SFU session that carries this room's media.
  ///
  /// For advanced use (stats, DataChannels). Publish and subscribe through
  /// [localParticipant] and [RemoteTrackPublication] instead of calling it
  /// directly, so the room's state stays consistent.
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

  /// Why the SFU session failed, or `null` if it hasn't.
  SfuSessionFailure? get failure => _session.failure;

  /// Whether [leave] has been called.
  bool get hasLeft => _left;

  /// Leaves the room and releases everything it holds.
  ///
  /// In order: stops listening to signaling and leaves it (so others stop
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
  }

  Future<void> _join() async {
    final self = localParticipant.state;
    await signaling.join(roomId, self);
    _announced = self;
    _subscriptions
      ..add(_session.connectionState.listen(_onSessionState))
      ..add(_session.failures.listen(_onSessionFailure))
      ..add(
        signaling.participants.listen(
          _onParticipants,
          onError: (Object error) =>
              _emit(RoomErrorEvent('signaling.participants', error)),
        ),
      );
  }

  void _setState(RoomConnectionState state) {
    if (_state.isClosed || _state.value == state) return;
    _state.set(state);
    _emit(RoomConnectionStateChangedEvent(state));
  }

  void _onSessionState(SfuConnectionState state) {
    if (_left || _session.failure != null) return;
    _setState(switch (state) {
      // Nothing negotiated yet: the session is usable.
      SfuConnectionState.initial => RoomConnectionState.connected,
      SfuConnectionState.connecting => RoomConnectionState.connecting,
      SfuConnectionState.connected => RoomConnectionState.connected,
      SfuConnectionState.disconnected => RoomConnectionState.reconnecting,
      SfuConnectionState.failed ||
      SfuConnectionState.closed => RoomConnectionState.disconnected,
    });
  }

  void _onSessionFailure(SfuSessionFailure failure) {
    if (_left) return;
    _setState(RoomConnectionState.disconnected);
    _emit(RoomSessionFailedEvent(failure));
  }

  /// Announces the local participant's current state, if it changed.
  /// Runs through [_announcer], so updates never overlap and a burst of
  /// changes becomes at most one more update.
  Future<void> _announce() async {
    if (_left) return;
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
    if (diff.isEmpty) return;

    for (final state in diff.left) {
      final remote = _remotes.remove(state.participantId);
      if (remote == null) continue;
      for (final publication in remote._removeAll()) {
        _emit(TrackUnpublishedEvent(publication));
      }
      remote._close();
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

  void _onRemoteChanged() {
    if (_left || _participants.isClosed) return;
    _participants.set(List.unmodifiable(_remotes.values));
  }

  Future<void> _leave() async {
    _left = true;
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();

    // Remote tracks: closing the session releases the pulls, so only the
    // local state is torn down here.
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
  required MediaBackend mediaBackend,
  required MediaStreamWrapper wrapTrack,
  required String participantId,
  Map<String, Object?>? metadata,
}) async {
  final room = Room._(
    roomId: roomId,
    signaling: signaling,
    options: options,
    session: session,
    broker: broker,
    mediaBackend: mediaBackend,
    wrapTrack: wrapTrack,
    participantId: participantId,
    metadata: metadata,
  );
  await room._join();
  return room;
}
