/// A [Signaling] implementation over WebSocket, for the dev server in
/// `tools/dev-server/`.
///
/// This is example code, not part of the `cloudflare_realtime` package: the
/// core stays free of transport dependencies. Copy and adapt it if your own
/// backend speaks a similar protocol. The protocol is documented in
/// `tools/dev-server/README.md`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Opens a WebSocket to [url]. Replace it in tests.
typedef WebSocketConnector = WebSocketChannel Function(Uri url);

/// Where a [WsSignaling] connection stands.
enum WsSignalingStatus {
  /// Not in a room, no socket.
  idle,

  /// Opening the first socket for a room.
  connecting,

  /// The socket is open and the join has been sent.
  connected,

  /// The socket dropped; waiting to reconnect and rejoin.
  reconnecting,

  /// The server ended the connection for good (bad token, or another
  /// connection joined with the same `participantId`). Call
  /// [WsSignaling.join] to try again.
  closed,
}

/// An error reported by the signaling server.
class WsSignalingException implements Exception {
  /// Creates an exception with the server's error [code] and [message].
  const WsSignalingException(this.code, this.message);

  /// The server's error code, such as `unauthorized`, `replaced` or
  /// `bad_request`.
  final String code;

  /// A human-readable description.
  final String message;

  @override
  String toString() => 'WsSignalingException($code): $message';
}

/// [Signaling] over the dev server's `/signaling` WebSocket.
///
/// - [join] opens a socket, sends the join, and completes when the server
///   acknowledges it. It throws a [WsSignalingException] if the server
///   refuses (for example, a bad dev token), or a [TimeoutException] after
///   [joinTimeout].
/// - While in a room, a dropped socket is reopened with exponential backoff
///   ([initialBackoff] doubling up to [maxBackoff]) and the join is sent
///   again with the latest state passed to [update]. [participants] keeps
///   its last list while reconnecting, so a short blip doesn't tear down
///   subscriptions.
/// - A ping goes out every [heartbeatInterval]. If nothing arrives for
///   [heartbeatTimeout], the socket is treated as dead and replaced. This
///   catches network drops that never close the socket.
/// - Participants that can't be parsed are skipped.
class WsSignaling implements Signaling {
  /// Creates a signaling connection to [url], such as
  /// `ws://192.168.1.10:8787/signaling?token=<dev token>`.
  WsSignaling({
    required this.url,
    WebSocketConnector? connect,
    this.joinTimeout = const Duration(seconds: 15),
    this.heartbeatInterval = const Duration(seconds: 4),
    this.heartbeatTimeout = const Duration(seconds: 10),
    this.initialBackoff = const Duration(milliseconds: 500),
    this.maxBackoff = const Duration(seconds: 10),
    this.onError,
  }) : _connect = connect ?? WebSocketChannel.connect;

  /// Close code the server uses for a missing or wrong dev token.
  static const closeUnauthorized = 4401;

  /// Close code the server uses when another connection took over this
  /// `participantId`.
  static const closeReplaced = 4409;

  /// The signaling endpoint, including the `token` query parameter.
  final Uri url;

  /// How long [join] waits for the server's acknowledgement, across retries.
  final Duration joinTimeout;

  /// How often to ping the server.
  final Duration heartbeatInterval;

  /// How long without any message before the socket counts as dead.
  final Duration heartbeatTimeout;

  /// The first reconnection delay.
  final Duration initialBackoff;

  /// The longest reconnection delay.
  final Duration maxBackoff;

  /// Receives errors that no call is waiting for, such as a refused
  /// [update] or being replaced by another connection.
  final void Function(Object error)? onError;

  final WebSocketConnector _connect;

  // Room state: what the app asked for.
  String? _roomId;
  ParticipantState? _self;
  int _roomEpoch = 0;
  Completer<void>? _joinCompleter;
  int? _pendingJoinId;

  // Socket state. Callbacks from an older [_generation] are ignored.
  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _generation = 0;
  bool _connected = false;
  int _attempt = 0;
  int _nextId = 0;
  Timer? _reconnectTimer;
  Timer? _pingTimer;
  Timer? _watchdog;
  WsSignalingException? _terminalError;

  List<ParticipantState> _participants = const [];
  final StreamController<List<ParticipantState>> _participantChanges =
      StreamController.broadcast(sync: true);
  WsSignalingStatus _status = WsSignalingStatus.idle;
  final StreamController<WsSignalingStatus> _statusChanges =
      StreamController.broadcast(sync: true);
  bool _disposed = false;

  /// The room this connection is in (or joining), or `null`.
  String? get roomId => _roomId;

  /// The latest state passed to [join] or [update], or `null`.
  ParticipantState? get self => _self;

  /// The current connection status.
  WsSignalingStatus get status => _status;

  /// Status changes. Replays the current status to each new listener.
  Stream<WsSignalingStatus> get statusChanges =>
      _replay(() => _status, _statusChanges);

  @override
  Stream<List<ParticipantState>> get participants =>
      _replay(() => _participants, _participantChanges);

  @override
  Future<void> join(String roomId, ParticipantState self) async {
    _checkNotDisposed();
    if (_roomId != null) {
      throw StateError('Already in room "$_roomId". Call leave() first.');
    }
    final epoch = ++_roomEpoch;
    _roomId = roomId;
    _self = self;
    _attempt = 0;
    _terminalError = null;
    final completer = _joinCompleter = Completer<void>();
    _open();
    try {
      await completer.future.timeout(joinTimeout);
    } catch (_) {
      // Unless leave() or a newer join took over, give up on this room.
      if (epoch == _roomEpoch && _roomId != null) _resetRoom();
      rethrow;
    } finally {
      if (identical(_joinCompleter, completer)) _joinCompleter = null;
    }
  }

  @override
  Future<void> update(ParticipantState self) async {
    _checkNotDisposed();
    final current = _self;
    if (_roomId == null || current == null) {
      throw StateError('Not in a room. Call join() first.');
    }
    if (self.participantId != current.participantId) {
      throw ArgumentError.value(
        self.participantId,
        'self.participantId',
        'must stay "${current.participantId}"',
      );
    }
    _self = self;
    // While disconnected, the rejoin carries the latest state.
    if (_connected) {
      _send({'type': 'update', 'id': ++_nextId, 'participant': self.toJson()});
    }
  }

  @override
  Future<void> leave() async {
    if (_roomId == null) return;
    if (_connected) _send({'type': 'leave', 'id': ++_nextId});
    _resetRoom();
  }

  /// Leaves the room, if any, and completes the streams. The instance can't
  /// be used afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    await leave();
    _disposed = true;
    await _participantChanges.close();
    await _statusChanges.close();
  }

  // --- Connection lifecycle -------------------------------------------------

  void _open() {
    _closeSocket();
    final generation = _generation;
    _setStatus(
      _attempt == 0
          ? WsSignalingStatus.connecting
          : WsSignalingStatus.reconnecting,
    );
    final WebSocketChannel channel;
    try {
      channel = _connect(url);
    } catch (_) {
      _onSocketClosed(generation, null);
      return;
    }
    _channel = channel;
    _subscription = channel.stream.listen(
      (data) {
        if (generation == _generation) _onData(data);
      },
      onError: (Object _) {},
      onDone: () => _onSocketClosed(generation, channel.closeCode),
    );
    channel.ready.then((_) {
      if (generation == _generation) _onReady();
    }, onError: (Object _) => _onSocketClosed(generation, null));
  }

  void _onReady() {
    _connected = true;
    _setStatus(WsSignalingStatus.connected);
    _resetWatchdog();
    _pingTimer = Timer.periodic(heartbeatInterval, (_) {
      _send({'type': 'ping'});
    });
    final id = _pendingJoinId = ++_nextId;
    _send({
      'type': 'join',
      'id': id,
      'roomId': _roomId,
      'participant': _self!.toJson(),
    });
  }

  /// Handles the end of socket [generation], once.
  void _onSocketClosed(int generation, int? closeCode) {
    if (generation != _generation) return;
    _closeSocket();
    if (_roomId == null) return;

    final terminal =
        _terminalError ??
        switch (closeCode) {
          closeUnauthorized => const WsSignalingException(
            'unauthorized',
            'missing or invalid dev token',
          ),
          closeReplaced => const WsSignalingException(
            'replaced',
            'another connection joined with this participantId',
          ),
          _ => null,
        };
    if (terminal != null) {
      final waiting = _joinCompleter;
      _resetRoom(status: WsSignalingStatus.closed, error: terminal);
      if (waiting == null) onError?.call(terminal);
      return;
    }

    _setStatus(WsSignalingStatus.reconnecting);
    final delay = _backoff(_attempt++);
    _reconnectTimer = Timer(delay, () {
      if (_roomId != null) _open();
    });
  }

  Duration _backoff(int attempt) {
    final factor = math.pow(2, math.min(attempt, 20)).toInt();
    final delay = initialBackoff * factor;
    return delay > maxBackoff ? maxBackoff : delay;
  }

  void _resetWatchdog() {
    _watchdog?.cancel();
    final generation = _generation;
    _watchdog = Timer(heartbeatTimeout, () {
      // A dead network may never close the socket; don't wait for it.
      _onSocketClosed(generation, null);
    });
  }

  /// Drops the current socket, if any, and invalidates its callbacks.
  void _closeSocket() {
    _generation++;
    _connected = false;
    _pendingJoinId = null;
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _watchdog?.cancel();
    _reconnectTimer = _pingTimer = _watchdog = null;
    unawaited(_subscription?.cancel());
    _subscription = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) {
      try {
        channel.sink.close(1000).then((_) {}, onError: (Object _) {});
      } catch (_) {
        // Already closed.
      }
    }
  }

  /// Leaves the room locally: closes the socket and clears the list.
  void _resetRoom({
    WsSignalingStatus status = WsSignalingStatus.idle,
    Object? error,
  }) {
    _roomEpoch++;
    _closeSocket();
    _roomId = null;
    _self = null;
    _terminalError = null;
    final waiting = _joinCompleter;
    _joinCompleter = null;
    if (waiting != null && !waiting.isCompleted) {
      waiting.completeError(
        error ?? StateError('Left the room before the join completed.'),
      );
    }
    _setStatus(status);
    _publish(const []);
  }

  // --- Messages ---------------------------------------------------------------

  void _onData(Object? data) {
    _resetWatchdog();
    if (data is! String) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      return;
    }
    if (decoded is! Map) return;
    final id = decoded['id'];
    switch (decoded['type']) {
      case 'ack':
        if (id != null && id == _pendingJoinId) {
          _pendingJoinId = null;
          _attempt = 0;
          final waiting = _joinCompleter;
          if (waiting != null && !waiting.isCompleted) waiting.complete();
        }
      case 'error':
        _onServerError(id, decoded);
      case 'participants':
        if (decoded['roomId'] == _roomId) _onParticipants(decoded);
    }
  }

  void _onServerError(Object? id, Map<dynamic, dynamic> message) {
    final code = message['code'];
    final error = WsSignalingException(
      code is String ? code : 'unknown',
      message['message'] is String ? message['message'] as String : '',
    );
    if (error.code == 'unauthorized' || error.code == 'replaced') {
      // The server closes the socket next; stop there.
      _terminalError = error;
      return;
    }
    if (id != null && id == _pendingJoinId) {
      final waiting = _joinCompleter;
      if (waiting != null) {
        _resetRoom(error: error);
        return;
      }
    }
    onError?.call(error);
  }

  void _onParticipants(Map<dynamic, dynamic> message) {
    final list = message['participants'];
    if (list is! List) return;
    final selfId = _self?.participantId;
    final others = <ParticipantState>[];
    for (final entry in list) {
      if (entry is! Map) continue;
      final ParticipantState state;
      try {
        state = ParticipantState.fromJson(Map<String, Object?>.from(entry));
      } catch (_) {
        continue; // Skip what we can't parse; newer peers may send more.
      }
      if (state.participantId == selfId) continue;
      if (others.any((p) => p.participantId == state.participantId)) continue;
      others.add(state);
    }
    _publish(others);
  }

  void _send(Map<String, Object?> message) {
    try {
      _channel?.sink.add(jsonEncode(message));
    } catch (_) {
      // The socket is closing; its close handler takes it from here.
    }
  }

  // --- Streams ----------------------------------------------------------------

  void _publish(List<ParticipantState> next) {
    if (listEquals(next, _participants)) return;
    _participants = List.unmodifiable(next);
    if (!_participantChanges.isClosed) _participantChanges.add(_participants);
  }

  void _setStatus(WsSignalingStatus next) {
    if (next == _status) return;
    _status = next;
    if (!_statusChanges.isClosed) _statusChanges.add(next);
  }

  /// A stream that replays [current] to each listener, then forwards
  /// [changes]. Events are delivered asynchronously, in order.
  static Stream<T> _replay<T>(
    T Function() current,
    StreamController<T> changes,
  ) => Stream.multi((listener) {
    listener.add(current());
    if (changes.isClosed) {
      listener.close();
      return;
    }
    final subscription = changes.stream.listen(
      listener.add,
      onDone: listener.close,
    );
    // A paused listener's controller buffers events itself. Cancelling a
    // subscription to a sync broadcast controller completes immediately, so
    // there is nothing to wait for (and not returning its root-zone future
    // keeps `first` and friends working under fake_async).
    listener.onCancel = () => unawaited(subscription.cancel());
  });

  void _checkNotDisposed() {
    if (_disposed) throw StateError('This WsSignaling was disposed.');
  }
}
