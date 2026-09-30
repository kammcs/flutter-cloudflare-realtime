/// @docImport 'room.dart';
library;

import 'package:flutter/foundation.dart';

import '../quality/active_speaker_config.dart';
import '../quality/layer_selection.dart';
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
///
/// The room normally picks the layer from the size of the views that show
/// the track (§6.1); [RemoteTrackPublication.setPreferredLayer] overrides
/// that.
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
    this.layerSelection = const LayerSelectionConfig(),
    this.hiddenVideoLinger = const Duration(seconds: 5),
    this.leaseReleaseGrace = const Duration(milliseconds: 500),
    this.activeSpeaker = const ActiveSpeakerConfig(),
  });

  /// Which remote tracks to pull without being asked. Default: audio only.
  final AutoSubscribe autoSubscribe;

  /// The layer a simulcast video track is pulled at while no view has
  /// reported its size (for example after an explicit
  /// [RemoteTrackPublication.subscribe]) and no layer was picked with
  /// [RemoteTrackPublication.setPreferredLayer]. Default
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

  /// How simulcast layers are picked from the size of the views that show
  /// a remote video (`docs/design.md` §6.1), and the `simulcast` fallback
  /// settings sent with pulls and `tracks/update`
  /// ([LayerSelectionConfig.ridNotAvailable] is `asciibetical` by default).
  final LayerSelectionConfig layerSelection;

  /// How long a remote video stays pulled, at its lowest layer, after every
  /// view showing it became hidden (`visible: false`, or a covered route),
  /// before the pull is released. A view that becomes visible again sooner
  /// gets its layer back without a new pull. Default 5 s; `null` keeps the
  /// lowest layer for as long as the views stay mounted.
  ///
  /// Only pulls held by views ([RemoteTrackPublication.retain]) are
  /// released this way; an explicit [RemoteTrackPublication.subscribe] (or
  /// [autoSubscribe]) keeps the track pulled at its lowest layer.
  final Duration? hiddenVideoLinger;

  /// How long a released [RemoteTrackLease] keeps its track pulled. A view
  /// that is unmounted and mounted again within this time (a rebuild with a
  /// new key, or a move between layouts) keeps the pull instead of closing
  /// and pulling it again. Default 500 ms; [Duration.zero] releases at
  /// once.
  final Duration leaseReleaseGrace;

  /// Active-speaker detection (`docs/design.md` §7): how often audio levels
  /// are read and how they are smoothed. `null` turns detection off: then
  /// [Room.activeSpeakers] stays empty and no stats are polled.
  final ActiveSpeakerConfig? activeSpeaker;
}
