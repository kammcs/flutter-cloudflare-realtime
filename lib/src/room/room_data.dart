part of 'room.dart';

/// DataChannels in a [Room] (`docs/design.md` §9): a thin layer over the
/// session's DataChannels that speaks in participants.
///
/// ```dart
/// final input = await room.data.publish('input', profile: DataChannelProfile.unreliable);
/// await input.whenOpen();
/// await input.send(bytes);
///
/// final sub = await room.data.subscribe(host, 'input', profile: DataChannelProfile.unreliable);
/// sub.messages.listen((m) => handle(m.participantId, m.binary));
/// ```
///
/// **Sender identity** ([RoomDataMessage.participantId]) comes from the
/// channel's session, mapped to a participant through the room's signaling
/// state, never from the payload.
class RoomData {
  RoomData._(this._room);

  final Room _room;
  final Set<RemoteDataSubscription> _subscriptions = {};
  // Published channels, moved to the new session when the room reconnects.
  final Set<LocalDataChannel> _published = {};

  /// Publishes the channel [name] from this participant. Everyone who
  /// subscribes to it receives what is sent on it. See
  /// [SfuSession.publishDataChannel].
  ///
  /// The returned channel belongs to the app: close it when done. When the
  /// room reconnects, the channel moves to the new session under the same
  /// name (it is `interrupted` meanwhile; [SfuDataChannel.messages] carries
  /// on). Leaving the room interrupts it.
  Future<LocalDataChannel> publish(
    String name, {
    DataChannelProfile profile = DataChannelProfile.reliable,
  }) async {
    _room._checkNotLeft();
    // Waits for a running re-session, and publishes again on the new
    // session if this one fails under it (as LocalParticipant does).
    final channel = await _room._onSessionWithRetry(
      (session) => session.publishDataChannel(name, profile: profile),
    );
    _published.add(channel);
    return channel;
  }

  /// Moves every published channel that isn't on a session to [next].
  List<Future<void>> _republishAll(SfuSession next) {
    _published.removeWhere((c) => c.state == SfuDataChannelState.closed);
    return [
      for (final channel in _published.toList())
        if (channel.session == null) _republish(next, channel),
    ];
  }

  Future<void> _republish(SfuSession next, LocalDataChannel channel) async {
    try {
      await next.republishDataChannel(channel);
    } on SfuDataChannelException catch (error) {
      // The SFU rejected this one channel: report it and carry on.
      _room._emit(RoomErrorEvent('data.republish ${channel.name}', error));
    }
  }

  /// Subscribes to the channel [name] that [participant] publishes.
  ///
  /// [profile] must match the publisher's. With [canReply], this
  /// participant may send back on the channel (only one subscriber per
  /// channel can). When [participant] moves to a new session (they
  /// reconnected), the subscription follows them and
  /// [RemoteDataSubscription.messages] carries on. See
  /// [SfuSession.subscribeDataChannel].
  ///
  /// Throws like [SfuSession.subscribeDataChannel].
  Future<RemoteDataSubscription> subscribe(
    RemoteParticipant participant,
    String name, {
    DataChannelProfile profile = DataChannelProfile.reliable,
    bool canReply = false,
  }) async {
    _room._checkNotLeft();
    if (!identical(participant._room, _room)) {
      throw ArgumentError.value(
        participant,
        'participant',
        'is not in this room',
      );
    }
    final channel = await _room._onSessionWithRetry(
      (session) => session.subscribeDataChannel(
        participant.sessionId,
        name,
        profile: profile,
        canReply: canReply,
      ),
    );
    if (_room._left) {
      await channel.close();
      throw StateError('The room "${_room.roomId}" was left.');
    }
    final subscription = RemoteDataSubscription._(this, participant, channel);
    _subscriptions.add(subscription);
    subscription._start();
    // The participant may have moved while the request was in flight.
    unawaited(subscription._runner.run());
    return subscription;
  }

  void _disposeForLeave() {
    for (final subscription in _subscriptions.toList()) {
      subscription._dispose();
    }
    _subscriptions.clear();
    _published.clear();
  }
}

/// A subscription to another participant's DataChannel, made with
/// [RoomData.subscribe].
///
/// It follows the publisher across sessions: when they reconnect, the
/// channel is subscribed again from their new session, and [messages]
/// carries on.
class RemoteDataSubscription {
  RemoteDataSubscription._(this._data, this.participant, this._channel)
    : name = _channel.name,
      profile = _channel.profile;

  final RoomData _data;

  /// The publisher.
  final RemoteParticipant participant;

  /// The channel's name.
  final String name;

  /// The channel's delivery policy.
  final DataChannelProfile profile;

  RemoteDataChannel _channel;
  final StreamController<RoomDataMessage> _messages =
      StreamController.broadcast();
  final List<StreamSubscription<Object?>> _listeners = [];
  StreamSubscription<DataChannelMessage>? _channelListener;
  late final CoalescingRunner _runner = CoalescingRunner(_follow);
  bool _closed = false;

  Room get _room => _data._room;

  /// The session-level channel currently carrying the subscription. It is
  /// replaced when the publisher moves to a new session.
  RemoteDataChannel get channel => _channel;

  /// Whether messages can be received (and, with [canReply], sent) now.
  bool get isOpen => _channel.isOpen;

  /// Whether this subscriber may send back to the publisher.
  bool get canReply => _channel.canReply;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Messages from the publisher, with their sender's participant ID.
  /// A broadcast stream; it carries on across the publisher's sessions and
  /// closes with [close] or [Room.leave].
  Stream<RoomDataMessage> get messages => _messages.stream;

  /// Completes when the current channel is open. See
  /// [SfuDataChannel.whenOpen].
  Future<void> whenOpen() => _channel.whenOpen();

  /// Sends [data] back to the publisher. Needs [canReply].
  Future<void> send(Uint8List data) => _channel.send(data);

  /// Sends [text] back to the publisher. Needs [canReply].
  Future<void> sendText(String text) => _channel.sendText(text);

  /// Grants or revokes [canReply]. See [RemoteDataChannel.setCanReply].
  Future<void> setCanReply(bool canReply) => _channel.setCanReply(canReply);

  /// Closes the subscription and its [messages] stream.
  Future<void> close() async {
    if (_closed) return;
    _dispose();
    try {
      await _channel.close();
    } catch (_) {
      // Closed locally either way.
    }
  }

  void _start() {
    _attach(_channel);
    _listeners.add(participant.changes.listen((_) => _runner.run()));
  }

  void _attach(RemoteDataChannel channel) {
    _channel = channel;
    unawaited(_channelListener?.cancel());
    _channelListener = channel.messages.listen((message) {
      if (_messages.isClosed) return;
      _messages.add(
        RoomDataMessage._(
          message,
          _room._participantIdForSession(message.fromSessionId),
        ),
      );
    });
  }

  /// Moves the subscription to the publisher's current session, on the
  /// room's current session: after the publisher reconnected, and after
  /// the room did (the channel is then off any session).
  Future<void> _follow() async {
    if (_closed || _room._left || !participant.isPresent) return;
    final remoteSessionId = participant.sessionId;
    final current = _channel;
    final session = _room._session;
    if (current.remoteSessionId == remoteSessionId &&
        (current.session != null ||
            current.state == SfuDataChannelState.closed)) {
      return; // Up to date (or on its way), or closed by the app.
    }
    if (!session.isUsable) return;
    try {
      if (current.session == null &&
          current.state != SfuDataChannelState.closed) {
        await session.resubscribeDataChannel(
          current,
          remoteSessionId: remoteSessionId,
        );
      } else {
        // Still on the publisher's old session: close it and subscribe
        // afresh (a live channel can't be moved).
        final canReply = current.canReply;
        await current.close();
        final next = await session.subscribeDataChannel(
          remoteSessionId,
          name,
          profile: profile,
          canReply: canReply,
        );
        if (_closed) {
          await next.close();
          return;
        }
        _attach(next);
      }
    } catch (error) {
      if (!_closed) _room._emit(RoomErrorEvent('data.subscribe', error));
    }
  }

  void _dispose() {
    _closed = true;
    _data._subscriptions.remove(this);
    for (final listener in _listeners) {
      unawaited(listener.cancel());
    }
    _listeners.clear();
    unawaited(_channelListener?.cancel());
    _channelListener = null;
    unawaited(_messages.close());
  }

  @override
  String toString() =>
      'RemoteDataSubscription(${participant.participantId}/$name, '
      '${_channel.state.name})';
}

/// A message received on a [RemoteDataSubscription].
final class RoomDataMessage {
  RoomDataMessage._(this.message, this.participantId);

  /// The session-level message, with [DataChannelMessage.fromSessionId].
  final DataChannelMessage message;

  /// The sender's participant ID: the owner of the channel's session in the
  /// room's signaling state, never taken from the payload. Null if no
  /// participant announced that session, or more than one did.
  final String? participantId;

  /// The session that sent the message.
  String? get fromSessionId => message.fromSessionId;

  /// Whether this is a binary message.
  bool get isBinary => message.isBinary;

  /// The payload of a binary message.
  Uint8List? get binary => message.binary;

  /// The payload of a text message.
  String? get text => message.text;

  @override
  String toString() =>
      'RoomDataMessage(${message.channelName}, from: $participantId, '
      '${isBinary ? '${binary!.length} bytes' : '${text!.length} chars'})';
}
