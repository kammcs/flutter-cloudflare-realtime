/// @docImport 'room.dart';
library;

import 'package:flutter/foundation.dart';

import '../quality/active_speaker_config.dart';
import '../quality/connection_quality.dart';
import '../quality/layer_selection.dart';
import '../reconnect/backoff.dart';
import '../reconnect/reconnect_trigger.dart';
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

  /// The SFU connection dropped and may come back on its own (the peer
  /// connection is `disconnected`), or the room is replacing its session
  /// (`docs/design.md` §8): see [RoomReconnectingEvent].
  reconnecting,

  /// Left, or the session is gone and the room isn't replacing it: the
  /// reconnection gave up ([RoomReconnectFailedEvent]), or automatic
  /// reconnection is off ([ReconnectOptions.enabled]) and the session
  /// failed. The room stays in signaling; [Room.reconnect] tries again, and
  /// [Room.leave] releases it.
  disconnected,
}

/// How a [Room] replaces a broken SFU session (`docs/design.md` §8).
///
/// When the session fails (or looks dead: see [trigger]), the room creates
/// a new session, moves its published tracks and DataChannels onto it under
/// the same names, announces the new session ID, and pulls its
/// subscriptions again from the publishers' current sessions. Local capture
/// is never restarted. Attempts are spaced by [backoff]; when it gives up,
/// the room is [RoomConnectionState.disconnected] until [Room.reconnect].
@immutable
class ReconnectOptions {
  /// Creates reconnection options.
  const ReconnectOptions({
    this.enabled = true,
    this.backoff = const BackoffConfig(),
    this.trigger = const ReconnectTriggerConfig(),
    this.stablePeriod = const Duration(seconds: 10),
  });

  /// No automatic reconnection: a failed session leaves the room
  /// [RoomConnectionState.disconnected]. [Room.reconnect] still works.
  static const disabled = ReconnectOptions(enabled: false);

  /// Whether the room replaces a broken session by itself. Default `true`.
  final bool enabled;

  /// The delay before each attempt (full jitter, so clients that dropped
  /// together don't come back together) and when to give up. Default:
  /// up to 500 ms before the first attempt, doubling to 10 s, giving up
  /// after 2 minutes. A failing signaling update during a reconnection is
  /// retried with the same schedule.
  final BackoffConfig backoff;

  /// When a session counts as broken: `failed` at once, `disconnected`
  /// after 5 s (at once after a network change), a stuck connect after
  /// 15 s, a return from 30 s or more in the background, or a
  /// session-gone (410) error.
  final ReconnectTriggerConfig trigger;

  /// How long a new session must last before [backoff] starts over. A
  /// session that breaks sooner continues the previous schedule, so a
  /// connection that keeps dropping backs off (and eventually gives up)
  /// instead of reconnecting in a tight loop. Default 10 s.
  final Duration stablePeriod;

  @override
  bool operator ==(Object other) =>
      other is ReconnectOptions &&
      other.enabled == enabled &&
      other.backoff == backoff &&
      other.trigger == trigger &&
      other.stablePeriod == stablePeriod;

  @override
  int get hashCode => Object.hash(enabled, backoff, trigger, stablePeriod);

  @override
  String toString() =>
      'ReconnectOptions(enabled: $enabled, $backoff, '
      'stablePeriod: $stablePeriod)';
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
    this.reconnect = const ReconnectOptions(),
    this.layerSelection = const LayerSelectionConfig(),
    this.hiddenVideoLinger = const Duration(seconds: 5),
    this.leaseReleaseGrace = const Duration(milliseconds: 500),
    this.activeSpeaker = const ActiveSpeakerConfig(),
    this.stats = const RoomStatsOptions(),
    this.screenShareStallTimeout = const Duration(seconds: 8),
    this.speakerphone,
    this.connectEarly = true,
    this.foregroundService = true,
    this.proximitySensor = true,
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

  /// How a broken SFU session is replaced. Default: automatically, see
  /// [ReconnectOptions].
  final ReconnectOptions reconnect;

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

  /// Typed stats and connection quality (`docs/design.md` §7.1): how often
  /// [Room.stats] reads `getStats()` (2 s), and how
  /// [LocalParticipant.connectionQuality] and
  /// [RemoteParticipant.connectionQuality] are rated. Quality is on by
  /// default, which polls for as long as the room is joined; with
  /// `RoomStatsOptions(connectionQuality: null)` the room polls only while
  /// someone listens to [Room.stats].
  final RoomStatsOptions stats;

  /// How long a local screen share may go without a captured or encoded
  /// frame, counted while the room is connected, before the room reports
  /// [LocalScreenShareStalledEvent]. On macOS that is the symptom of a
  /// missing Screen Recording permission. Checked once a second through
  /// `getStats()` while a share captures. Default 8 s; `null` turns the
  /// check off.
  final Duration? screenShareStallTimeout;

  /// Where call audio plays on phones when no headset is connected
  /// (`docs/design.md` §4.6). `null` (the default) follows the call, the
  /// same way on Android and iOS: the earpiece for a voice call, and the
  /// speaker once the call has video (a camera or screen, sent or
  /// received). `true` forces the speaker, `false` the earpiece. A connected
  /// headset comes first either way, and the user can still pick a route
  /// with [Room.selectAudioRoute]. No effect on desktops and in browsers.
  final bool? speakerphone;

  /// Whether the room connects its SFU session's peer connection as soon as
  /// it has one, at join and after every re-session, rather than at the
  /// first publish or pull. Default `true`.
  ///
  /// The SFU expires a session whose peer connection never connected
  /// (about ten seconds after creating it), so a first publish that waits
  /// on a permission prompt or a screen-share picker would otherwise find
  /// the session gone. Connecting early ([SfuSession.establishConnection])
  /// sets up the session's DataChannel transport, which costs one more
  /// exchange with the broker and keeps an idle SCTP association. Either
  /// way, a publish that finds its session gone is retried once on the
  /// room's new session (`docs/design.md` §8.1).
  final bool connectEarly;

  /// Whether the room keeps the call alive in the background on Android
  /// with this package's foreground service (`docs/design.md` §4.7).
  /// Default `true`.
  ///
  /// While the room publishes a microphone or a capturing camera, the
  /// service runs with the type `microphone` (plus `camera` while the camera
  /// captures) and shows an ongoing notification; without it, Android 11+
  /// silences the microphone and stops the camera once the app is in the
  /// background. Turn it off for an app that runs its own foreground service
  /// (or Telecom's). No effect on other platforms: iOS keeps a call's audio
  /// with the app's `UIBackgroundModes: audio`.
  final bool foregroundService;

  /// Whether the screen turns off when the phone is held to the ear
  /// (`docs/design.md` §4.7). Default `true`.
  ///
  /// The proximity sensor is on only while call audio plays on the earpiece
  /// and no room has video; never on the speaker or a headset. Any joined
  /// room with `false` keeps it off. No effect on desktops, in browsers, and
  /// on devices without the sensor. See [Room.proximitySensorActive].
  final bool proximitySensor;
}
