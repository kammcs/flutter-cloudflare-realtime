part of 'data_channel_manager.dart';

/// A message received on an [SfuDataChannel].
class DataChannelMessage {
  /// Creates a message. The package creates these; the constructor is
  /// public so apps can build them in their own tests.
  const DataChannelMessage({
    required this.channel,
    required this.fromSessionId,
    this.binary,
    this.text,
  }) : assert((binary == null) != (text == null));

  /// The channel it arrived on.
  final SfuDataChannel channel;

  /// The session that sent it: the publisher's session ID for a message on
  /// a [RemoteDataChannel], taken from the channel at the time it arrived,
  /// **never from the payload**. Map it to a user through the app's
  /// (server-verified) signaling before acting on the message.
  ///
  /// Null on a [LocalDataChannel]: those messages are replies from the one
  /// subscriber that holds `canReply`, and the SFU doesn't say which
  /// session that is.
  final String? fromSessionId;

  /// The payload of a binary message.
  final Uint8List? binary;

  /// The payload of a text message.
  final String? text;

  /// Whether this is a binary message ([binary] is set) rather than text.
  bool get isBinary => binary != null;

  /// The channel's name.
  String get channelName => channel.name;

  @override
  String toString() =>
      'DataChannelMessage(${channel.name}, from: $fromSessionId, '
      '${isBinary ? '${binary!.length} bytes' : '${text!.length} chars'})';
}
