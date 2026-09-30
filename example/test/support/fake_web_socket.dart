import 'dart:async';
import 'dart:convert';

import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Records what the client sends.
class FakeWebSocketSink implements WebSocketSink {
  final List<Object?> sent = [];
  bool closed = false;
  int? closeCode;
  final Completer<void> _done = Completer();

  @override
  void add(Object? data) {
    if (closed) throw StateError('sink closed');
    sent.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<Object?> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close([int? closeCode, String? closeReason]) {
    closed = true;
    this.closeCode = closeCode;
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  Future<void> get done => _done.future;
}

/// A scripted WebSocket: the test opens it, feeds it server messages, and
/// drops it.
class FakeWebSocketChannel with StreamChannelMixin implements WebSocketChannel {
  FakeWebSocketChannel(this.url);

  final Uri url;
  final StreamController<Object?> _incoming = StreamController();
  final Completer<void> _ready = Completer();

  @override
  final FakeWebSocketSink sink = FakeWebSocketSink();

  @override
  int? closeCode;

  @override
  String? closeReason;

  @override
  String? get protocol => null;

  @override
  Stream<Object?> get stream => _incoming.stream;

  @override
  Future<void> get ready => _ready.future;

  /// The messages the client sent, decoded.
  List<Map<String, Object?>> get sent => [
    for (final data in sink.sent)
      (jsonDecode(data! as String) as Map).cast<String, Object?>(),
  ];

  /// Completes the handshake.
  void open() => _ready.complete();

  /// Fails the handshake, as for an unreachable server.
  void failToOpen() {
    _ready.completeError(WebSocketChannelException('unreachable'));
    _incoming.addError(WebSocketChannelException('unreachable'));
    _incoming.close();
  }

  /// Delivers a server message.
  void receive(Map<String, Object?> message) =>
      _incoming.add(jsonEncode(message));

  /// Delivers raw data.
  void receiveRaw(Object? data) => _incoming.add(data);

  /// Closes the socket from the server side (or the network).
  void drop([int? code]) {
    closeCode = code;
    _incoming.close();
  }
}
