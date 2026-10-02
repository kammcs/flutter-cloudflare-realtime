part of 'room.dart';

/// A room's system call (`docs/design.md` §4.8), from
/// [Room.attachSystemCall]:
///
/// - **Mute in step.** The system's mute button (the lock screen, a
///   headset, a car) mutes and unmutes the room's microphone publication,
///   and muting the publication in the app updates the system's button.
///   When they disagree at attach time, or when a microphone is published
///   later, muting wins: both end up muted.
/// - **Ending.** When the system call ends (from the system's UI, or the
///   app), the room leaves (`leaveWhenEnded`); when the room leaves, the
///   call ends (`endWhenLeft`).
///
/// Holding needs nothing here: a held system call interrupts the call's
/// audio through `CallAudio` (§4.7, [CallInterruptionReason.held]).
class _RoomSystemCall {
  _RoomSystemCall(this._room);

  final Room _room;
  SystemCall? _call;
  bool _leaveWhenEnded = true;
  bool _endWhenLeft = true;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  // Mute values the room asked the system for, whose events are still to
  // come: they confirm the request rather than change the microphone.
  final List<bool> _requested = [];
  // The microphone's mute as last seen; null while none is published.
  bool? _micMuted;

  SystemCall? get call => _call;

  void attach(
    SystemCall call, {
    required bool leaveWhenEnded,
    required bool endWhenLeft,
  }) {
    if (identical(call, _call)) {
      _leaveWhenEnded = leaveWhenEnded;
      _endWhenLeft = endWhenLeft;
      return;
    }
    detach();
    _call = call;
    _leaveWhenEnded = leaveWhenEnded;
    _endWhenLeft = endWhenLeft;
    _micMuted = null;
    _localChanged();
    _subscriptions
      // Skip the replayed value: the state at attach is handled above.
      ..add(call.mutedChanges.skip(1).listen(_systemMuted))
      ..add(_room.localParticipant.changes.listen((_) => _localChanged()));
    unawaited(call.whenEnded.then((_) => _callEnded(call)));
  }

  void detach() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _requested.clear();
    _call = null;
  }

  // The system's mute changed (or replays its value at attach).
  void _systemMuted(bool muted) {
    if (_requested.isNotEmpty) {
      final expected = _requested.removeAt(0);
      if (expected == muted) return;
      _requested.clear();
    }
    final microphone = _room.localParticipant.microphone;
    if (microphone == null || !microphone.isPublished) return;
    if (microphone.muted == muted) return;
    // Unmuting from the system only follows an earlier mute; at attach,
    // muting wins (see [_localChanged]).
    unawaited(_setMicrophone(microphone, muted));
  }

  // The local participant changed: a microphone published, muted or gone.
  void _localChanged() {
    final call = _call;
    final microphone = _room.localParticipant.microphone;
    final now = microphone?.muted;
    final before = _micMuted;
    _micMuted = now;
    if (call == null || call.isEnded || microphone == null || now == null) {
      return;
    }
    if (before == null) {
      // Newly published (or just attached): muting wins.
      if (call.muted && !now) {
        unawaited(_setMicrophone(microphone, true));
      } else if (now && !call.muted) {
        _request(call, true);
      }
      return;
    }
    if (now != before && now != call.muted) _request(call, now);
  }

  void _request(SystemCall call, bool muted) {
    _requested.add(muted);
    unawaited(
      call.setMuted(muted).catchError((Object error) {
        _requested.remove(muted);
        if (!_room._left) _room._emit(RoomErrorEvent('systemCall', error));
      }),
    );
  }

  Future<void> _setMicrophone(
    LocalMediaPublication microphone,
    bool muted,
  ) async {
    try {
      await microphone.setMuted(muted);
    } catch (error) {
      if (!_room._left) _room._emit(RoomErrorEvent('systemCall', error));
    }
  }

  void _callEnded(SystemCall call) {
    if (!identical(call, _call)) return;
    detach();
    if (_leaveWhenEnded && !_room._left) unawaited(_room.leave());
  }

  /// The room leaves: ends the call ([Room.attachSystemCall]'s
  /// `endWhenLeft`) and stops following it.
  void dispose() {
    final call = _call;
    final end = _endWhenLeft;
    detach();
    if (call != null && end && !call.isEnded) {
      unawaited(
        call.end().catchError((Object error) {
          debugPrint('cloudflare_realtime: ending the system call: $error');
        }),
      );
    }
  }
}
