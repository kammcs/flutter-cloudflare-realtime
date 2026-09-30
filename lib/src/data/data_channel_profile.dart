part of 'data_channel_manager.dart';

/// A DataChannel's delivery policy (`docs/design.md` §9).
///
/// The publisher picks it, and every subscriber must use the same one: the
/// SFU requires each endpoint to mirror the publisher's policy, both in its
/// request and in its own negotiated channel. Use separate channel names for
/// different policies.
enum DataChannelProfile {
  /// Ordered and retransmitted until delivered (no `maxRetransmits` or
  /// `maxPacketLifeTime`). For keys, clicks, chat and control messages.
  reliable(ordered: true, maxRetransmits: null),

  /// Unordered, never retransmitted (`ordered: false`, `maxRetransmits: 0`).
  /// For high-rate state where only the latest value matters, such as
  /// pointer moves.
  ///
  /// On the web, `flutter_webrtc` 1.6.2 drops `maxRetransmits: 0`, so a
  /// browser endpoint sends unordered but retransmitted.
  unreliable(ordered: false, maxRetransmits: 0);

  const DataChannelProfile({
    required this.ordered,
    required this.maxRetransmits,
  });

  /// Whether messages are delivered in send order.
  final bool ordered;

  /// Retransmissions after the first send, or null for no limit (reliable).
  final int? maxRetransmits;
}
