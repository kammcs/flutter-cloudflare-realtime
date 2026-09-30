/// @docImport 'room.dart';
library;

import 'package:flutter/foundation.dart';

import '../reconnect/backoff.dart';
import '../session/sfu_session.dart';

/// Which remote tracks a [Room] pulls without being asked.
///
/// Pulling costs SFU egress, so by default the room pulls audio (everyone
/// wants to hear everyone) and leaves video until the UI asks for it with
/// [RemoteTrackPublication.subscribe] or a `ParticipantVideoView`
/// (`docs/design.md` §4.3). A large gallery then pulls only the cameras on
/// screen.
@immutable
class AutoSubscribe {
  /// Creates an auto-subscribe policy.
  const AutoSubscribe({this.audio = true, this.video = false});

  /// Pull nothing until asked.
  static const none = AutoSubscribe(audio: false);

  /// Pull every track as soon as it is published.
  static const all = AutoSubscribe(video: true);

  /// Whether to pull audio tracks (microphones and screen-share audio).
  /// Default `true`.
  final bool audio;

  /// Whether to pull video tracks (cameras and screen shares). Default
  /// `false`.
  final bool video;

  @override
  bool operator ==(Object other) =>
      other is AutoSubscribe && other.audio == audio && other.video == video;

  @override
  int get hashCode => Object.hash(audio, video);

  @override
  String toString() => 'AutoSubscribe(audio: $audio, video: $video)';
}

/// A simulcast layer of a remote video track (`docs/design.md` §6).
///
/// Publishers send up to three encodings named so that `a` is the highest:
/// [high] is `a`, [medium] is `b` and [low] is `c`. When the publisher
/// advertises its layers ([TrackInfo.simulcast]), the layer is picked by
/// rank from them instead, so [low] is always the lowest layer it sends.
enum SimulcastLayer {
  /// The full-resolution layer (`a`): a stage or full-screen view.
  high('a'),

  /// The half-resolution layer (`b`): a gallery tile.
  medium('b'),

  /// The quarter-resolution layer (`c`): a thumbnail.
  low('c');

  const SimulcastLayer(this.rid);

  /// The layer's RID under the package's default naming.
  final String rid;

  /// The RID for this layer among [rids] (highest first): the first, the
  /// middle or the last one. Falls back to [rid] when [rids] is empty.
  String ridIn(List<String> rids) {
    if (rids.isEmpty) return rid;
    return switch (this) {
      high => rids.first,
      medium => rids[rids.length ~/ 2],
      low => rids.last,
    };
  }
}

/// The state of a [Room]'s connection.
enum RoomConnectionState {
  /// Joining, or the SFU connection is being set up.
  connecting,

  /// Joined, and the SFU session is usable.
  connected,

  /// The SFU connection dropped and may come back on its own (ICE
  /// `disconnected`). Roadmap M5 also uses this state while it replaces a
  /// failed session.
  reconnecting,

  /// Left, or the SFU session failed. Until roadmap M5 adds automatic
  /// reconnection, a failed session ends here: see [Room.failure].
  disconnected,
}

/// Options for [CloudflareRealtime.join].
@immutable
class RoomOptions {
  /// Creates room options.
  const RoomOptions({
    this.autoSubscribe = const AutoSubscribe(),
    this.defaultVideoLayer = SimulcastLayer.medium,
    this.sessionOptions = const SfuSessionOptions(),
    this.pullRetry = const BackoffConfig(
      initialDelay: Duration(milliseconds: 250),
      maxDelay: Duration(seconds: 4),
      maxAttempts: 8,
      maxElapsed: Duration(minutes: 1),
    ),
  });

  /// Which remote tracks to pull without being asked. Default: audio only.
  final AutoSubscribe autoSubscribe;

  /// The layer a simulcast video track is first pulled at, until
  /// [RemoteTrackPublication.setPreferredLayer] picks another. Default
  /// [SimulcastLayer.medium], the gallery size.
  final SimulcastLayer defaultVideoLayer;

  /// Options for the room's SFU session: ICE servers, publish defaults
  /// (simulcast encodings, codecs) and timeouts.
  final SfuSessionOptions sessionOptions;

  /// How failed pulls are retried.
  ///
  /// A track is advertised as soon as the SFU accepts it, which can be
  /// before its first packets arrive; a pull that races them, or one of a
  /// muted track that never sent, can fail. The room retries it with this
  /// backoff, and again whenever the publisher's state changes (for example
  /// when they unmute or move to a new session).
  final BackoffConfig pullRetry;
}
