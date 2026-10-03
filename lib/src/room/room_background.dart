part of 'room.dart';

/// The call outside the app's foreground, and interruptions
/// (`docs/design.md` §4.7):
///
/// - tells [CallBackground] what the room publishes, so Android's
///   foreground service runs while a microphone or a capturing camera is
///   published ([RoomOptions.foregroundService]);
/// - turns [CallAudio]'s interruptions into [RoomAudioInterruptedEvent] and
///   [RoomAudioResumedEvent], and keeps the call silent meanwhile (remote audio
///   and the microphone; nothing is announced);
/// - turns [CallBackground]'s camera pauses into [RoomCameraPausedEvent]
///   and [RoomCameraResumedEvent] while the room publishes a camera.
class _RoomBackground {
  _RoomBackground(this._room);

  final Room _room;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  CallInterruptionReason? _interruption;
  bool _cameraPauseReported = false;
  bool _joined = false;

  void start() {
    final background = CallBackground.instance;
    background.join(_room, foregroundService: _room.options.foregroundService);
    _joined = true;
    _subscriptions
      ..add(_room.localParticipant.changes.listen((_) => _publishingChanged()))
      ..add(
        background.errors.listen(
          (error) => _room._emit(RoomErrorEvent('foregroundService', error)),
        ),
      )
      ..add(CallAudio.instance.interruption.stream.listen(_onInterruption))
      ..add(background.cameraPause.stream.listen(_onCameraPause));
    _publishingChanged();
  }

  void _publishingChanged() {
    if (_room._left) return;
    final local = _room.localParticipant;
    final camera = local.camera;
    CallBackground.instance.publishing(
      _room,
      microphone: local.microphone != null,
      camera: camera != null && !camera.isMuted,
    );
  }

  void _onInterruption(CallInterruptionReason? reason) {
    if (_room._left || reason == _interruption) return;
    final previous = _interruption;
    _interruption = reason;
    _setSilenced(reason != null);
    if (reason != null) {
      _room._emit(RoomAudioInterruptedEvent(reason));
    } else if (previous != null) {
      _room._emit(RoomAudioResumedEvent(previous));
    }
  }

  void _setSilenced(bool silenced) {
    _room._audio.setSilenced(silenced);
    final microphone =
        _room.localParticipant.microphone?.mediaSource.broadcastTrack;
    if (microphone == null) return;
    try {
      microphone.track.enabled = !silenced;
    } catch (_) {
      // A track that has gone away sends nothing anyway.
    }
  }

  void _onCameraPause(CameraPauseReason? reason) {
    if (_room._left) return;
    if (reason != null && _room.localParticipant.camera != null) {
      _cameraPauseReported = true;
      _room._emit(RoomCameraPausedEvent(reason));
    } else if (reason == null && _cameraPauseReported) {
      _cameraPauseReported = false;
      _room._emit(const RoomCameraResumedEvent());
    }
  }

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    // An app-owned microphone outlives the room: don't leave it silent.
    if (_interruption != null) {
      _interruption = null;
      _setSilenced(false);
    }
    if (!_joined) return;
    _joined = false;
    await CallBackground.instance.leave(_room);
  }
}
