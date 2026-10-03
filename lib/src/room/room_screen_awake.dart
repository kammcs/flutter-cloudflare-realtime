part of 'room.dart';

/// Keeps the screen on during the call (`docs/design.md` §4.7, Keeping the
/// screen on): tells the app-wide [ScreenAwake] whether this room wants it,
/// from [RoomOptions.keepScreenAwake], the connection state and whether
/// video is live.
///
/// [update] runs whenever something it reads may have changed: every room
/// event (connection state, tracks published, muted, subscribed), the local
/// participant's changes (publish, mute) and every remote publication's
/// changes (subscribed, unsubscribed, muted). It is cheap and only tells
/// [ScreenAwake] when the answer changes.
class _RoomScreenAwake {
  _RoomScreenAwake(this._room);

  final Room _room;
  bool _joined = false;
  bool? _wanted;

  void start() {
    _joined = true;
    update();
  }

  void update() {
    if (!_joined || _room._left) return;
    final wanted = switch (_room.options.keepScreenAwake) {
      KeepScreenAwake.never => false,
      KeepScreenAwake.always => _active,
      KeepScreenAwake.whileVideo => _active && _videoLive,
    };
    if (wanted == _wanted) return;
    _wanted = wanted;
    ScreenAwake.instance.update(_room, wanted: wanted);
  }

  // Joined and not given up: connected, (re)connecting.
  bool get _active => _room._state.value != RoomConnectionState.disconnected;

  // A local camera or screen share that is sending, or a remote video that
  // is subscribed and not muted by its publisher.
  bool get _videoLive =>
      _room.localParticipant._publications.any(
        (p) => p.kind == TrackKind.video && !p._unpublished && !p.muted,
      ) ||
      _room._remotes.values.any(
        (r) => r.trackPublications.any(
          (p) => p.kind == TrackKind.video && p.isSubscribed && !p.muted,
        ),
      );

  Future<void> dispose() async {
    if (!_joined) return;
    _joined = false;
    await ScreenAwake.instance.leave(_room);
  }
}
