part of 'data_channel_manager.dart';

/// The lifecycle of an [SfuDataChannel].
enum SfuDataChannelState {
  /// Being published or subscribed (the SFU request is queued or in
  /// flight).
  pending,

  /// The SFU accepted the channel and the local end exists, but its SCTP
  /// stream isn't open yet.
  connecting,

  /// Messages can flow.
  open,

  /// Its session failed or closed, or the channel closed without
  /// [SfuDataChannel.close] (for example because the SFU dropped it). Move
  /// it to a session with
  /// `SfuSession.republishDataChannel` or `resubscribeDataChannel`.
  interrupted,

  /// Publishing or subscribing failed (see [SfuDataChannel.error]). It can
  /// be retried with `republishDataChannel` or `resubscribeDataChannel`.
  failed,

  /// Closed with [SfuDataChannel.close]. Terminal.
  closed,
}

/// A DataChannel forwarded by the SFU: a [LocalDataChannel] this session
/// publishes, or a [RemoteDataChannel] it subscribes to.
///
/// Like track publications, a channel outlives its session. When the
/// session fails or closes, the channel becomes
/// [SfuDataChannelState.interrupted]; moving it to a new session keeps its
/// [messages] and [stateChanges] streams, so listeners carry on.
sealed class SfuDataChannel {
  SfuDataChannel._(this.name, this.profile);

  /// The channel's name. Subscribers pull it by this name and the
  /// publisher's session ID.
  final String name;

  /// The delivery policy.
  final DataChannelProfile profile;

  final StateStream<SfuDataChannelState> _state = StateStream(
    SfuDataChannelState.pending,
    distinct: true,
  );
  final StreamController<DataChannelMessage> _messages =
      StreamController.broadcast();
  final StreamController<int> _low = StreamController.broadcast();
  final List<StreamSubscription<Object?>> _channelSubscriptions = [];
  Object? _error;
  DataChannelManager? _manager;
  PeerDataChannel? _channel;
  int? _id;
  int _lowThreshold = 0;

  /// The session the channel is on (or being set up on), or null.
  SfuSession? get session => _manager?.session;

  /// The negotiated channel ID on the current session, once set up. Local
  /// to this session: the other end's ID can differ.
  int? get id => _id;

  /// The channel's state.
  SfuDataChannelState get state => _state.value;

  /// [state], replaying the current value to each new listener, then each
  /// change.
  Stream<SfuDataChannelState> get stateChanges => _state.stream;

  /// Why the channel failed or was interrupted, if it did.
  Object? get error => _error;

  /// Whether messages can be sent and received now.
  bool get isOpen => state == SfuDataChannelState.open;

  /// Incoming messages, binary and text, across sessions. A broadcast
  /// stream: messages that arrive while nobody listens are dropped. Closes
  /// when the channel is closed.
  Stream<DataChannelMessage> get messages => _messages.stream;

  /// The sender of messages on the current underlying channel.
  String? get _fromSessionId;

  /// Completes when the channel is [SfuDataChannelState.open]. Throws an
  /// [SfuSessionException] if it becomes interrupted, failed or closed
  /// first.
  Future<void> whenOpen() async {
    await for (final state in stateChanges) {
      switch (state) {
        case SfuDataChannelState.open:
          return;
        case SfuDataChannelState.interrupted ||
            SfuDataChannelState.failed ||
            SfuDataChannelState.closed:
          throw SfuInterruptedException('the data channel is ${state.name}');
        case SfuDataChannelState.pending || SfuDataChannelState.connecting:
          break;
      }
    }
    throw const SfuInterruptedException('the data channel is closed');
  }

  /// Sends [data] as a binary message.
  ///
  /// Throws a [StateError] unless the channel is open (and, on a
  /// [RemoteDataChannel], subscribed with `canReply`). Check
  /// [bufferedAmount] to avoid queuing too much; see
  /// [bufferedAmountLowThreshold].
  Future<void> send(Uint8List data) =>
      _send(RTCDataChannelMessage.fromBinary(data));

  /// Sends [text] as a text message. See [send].
  Future<void> sendText(String text) => _send(RTCDataChannelMessage(text));

  Future<void> _send(RTCDataChannelMessage message) {
    _checkCanSend();
    final channel = _channel;
    if (channel == null || !isOpen) {
      throw StateError('The data channel "$name" is not open (${state.name}).');
    }
    return channel.send(message);
  }

  void _checkCanSend() {}

  /// Bytes queued for sending on the current channel. On native platforms
  /// it's the last amount the platform reported, so it lags slightly.
  int get bufferedAmount => _channel?.bufferedAmount ?? 0;

  /// The low-water mark for [bufferedAmountLow], in bytes (default 0).
  /// Kept across sessions.
  int get bufferedAmountLowThreshold => _lowThreshold;

  set bufferedAmountLowThreshold(int value) {
    if (value < 0) throw ArgumentError.value(value, 'value', 'is negative');
    _lowThreshold = value;
    _channel?.bufferedAmountLowThreshold = value;
  }

  /// Emits the buffered amount each time it falls to or below
  /// [bufferedAmountLowThreshold] from above it. For backpressure: stop
  /// sending when [bufferedAmount] is high, and resume on this event.
  Stream<int> get bufferedAmountLow => _low.stream;

  /// Closes the channel (`datachannels/close`) and stops its streams. The
  /// channel is [SfuDataChannelState.closed] at once, even if the request
  /// fails. On a failed or closed session, only local state changes.
  Future<void> close() {
    final manager = _manager;
    if (manager != null) return manager.close(this);
    _closeLocally();
    return Future.value();
  }

  void _bind(DataChannelManager manager) {
    _manager = manager;
    _id = null;
    _error = null;
    _setState(SfuDataChannelState.pending);
  }

  void _activate(DataChannelManager manager, PeerDataChannel channel, int id) {
    _channel = channel;
    _id = id;
    channel.bufferedAmountLowThreshold = _lowThreshold;
    // Attribute messages to the session this channel was opened from, even
    // if a later resubscribe changes it.
    final from = _fromSessionId;
    _channelSubscriptions.addAll([
      channel.onMessage.listen((message) {
        if (!identical(_channel, channel) || _messages.isClosed) return;
        _messages.add(
          message.isBinary
              ? DataChannelMessage(
                  channel: this,
                  fromSessionId: from,
                  binary: message.binary,
                )
              : DataChannelMessage(
                  channel: this,
                  fromSessionId: from,
                  text: message.text,
                ),
        );
      }),
      channel.onStateChange.listen((state) {
        if (!identical(_channel, channel)) return;
        switch (state) {
          case RTCDataChannelState.RTCDataChannelOpen:
            _setState(SfuDataChannelState.open);
          case RTCDataChannelState.RTCDataChannelConnecting:
            _setState(SfuDataChannelState.connecting);
          case RTCDataChannelState.RTCDataChannelClosing ||
              RTCDataChannelState.RTCDataChannelClosed:
            manager._lost(this);
        }
      }),
      channel.onBufferedAmountLow.listen((amount) {
        if (identical(_channel, channel) && !_low.isClosed) _low.add(amount);
      }),
    ]);
    _setState(
      channel.state == RTCDataChannelState.RTCDataChannelOpen
          ? SfuDataChannelState.open
          : SfuDataChannelState.connecting,
    );
  }

  /// Leaves the session in [next] state, closing the underlying channel.
  void _detach(SfuDataChannelState next, [Object? error]) {
    for (final s in _channelSubscriptions) {
      unawaited(s.cancel());
    }
    _channelSubscriptions.clear();
    final channel = _channel;
    _channel = null;
    _manager = null;
    _id = null;
    if (channel != null) {
      unawaited(channel.close().catchError((Object _) {}));
    }
    if (error != null) _error = error;
    _setState(next);
  }

  void _closeLocally() {
    _detach(SfuDataChannelState.closed);
    unawaited(_messages.close());
    unawaited(_low.close());
  }

  void _setState(SfuDataChannelState next) {
    if (_state.isClosed) return;
    _state.set(next);
    if (next == SfuDataChannelState.closed) unawaited(_state.close());
  }
}

/// A DataChannel this session publishes. The SFU forwards what it sends to
/// every subscriber.
///
/// Messages received on it are replies from the one subscriber holding
/// `canReply`; their [DataChannelMessage.fromSessionId] is null.
final class LocalDataChannel extends SfuDataChannel {
  LocalDataChannel._(super.name, super.profile) : super._();

  /// The publisher's (this session's) ID to share through signaling, or
  /// null when the channel isn't on a session.
  String? get sessionId => session?.sessionId;

  @override
  String? get _fromSessionId => null;

  @override
  String toString() =>
      'LocalDataChannel($name, ${profile.name}, ${state.name}, id: $_id)';
}

/// A DataChannel published by another session, subscribed to through this
/// one.
///
/// Every message carries [DataChannelMessage.fromSessionId] =
/// [remoteSessionId] from the channel, never from the payload.
final class RemoteDataChannel extends SfuDataChannel {
  RemoteDataChannel._({
    required String remoteSessionId,
    required String name,
    required DataChannelProfile profile,
    required bool canReply,
  }) : _remoteSessionId = remoteSessionId,
       _canReply = canReply,
       super._(name, profile);

  String _remoteSessionId;
  bool _canReply;

  /// The publisher's session ID.
  String get remoteSessionId => _remoteSessionId;

  /// Whether this subscriber may send back to the publisher. Only one
  /// subscriber per published channel can.
  bool get canReply => _canReply;

  /// Grants or revokes [canReply] (`datachannels/update`). Granting it
  /// replaces whichever subscriber held it before. On a channel that isn't
  /// on a session, the value is kept for the next subscribe.
  Future<void> setCanReply(bool canReply) {
    final manager = _manager;
    if (manager == null) {
      if (state == SfuDataChannelState.closed) {
        throw StateError('The data channel is closed.');
      }
      _canReply = canReply;
      return Future.value();
    }
    return manager.setCanReply(this, canReply);
  }

  @override
  String? get _fromSessionId => _remoteSessionId;

  @override
  void _checkCanSend() {
    if (!_canReply) {
      throw StateError(
        'Subscribed to "$name" without canReply: only the publisher sends '
        'on it. For two-way traffic, publish a channel on each side.',
      );
    }
  }

  @override
  String toString() =>
      'RemoteDataChannel($_remoteSessionId/$name, ${profile.name}, '
      '${state.name}, id: $_id${_canReply ? ', canReply' : ''})';
}
