import 'package:flutter/foundation.dart';

/// Tuning for active-speaker detection (design.md §7).
///
/// Audio levels are linear, `0..1` (1 is full scale), as WebRTC's
/// `audioLevel` reports them. Rough guide: 0.01 ≈ −40 dBFS, 0.03 ≈ −30 dBFS,
/// 0.1 ≈ −20 dBFS. With noise suppression on, a quiet room reads well under
/// 0.01 and normal speech 0.05–0.5.
///
/// The pipeline, per participant, on every poll:
///
/// 1. **Smooth** the level with an exponential moving average whose time
///    constant is [smoothingTimeConstant].
/// 2. **Start speaking** once the smoothed level has stayed at or above
///    [speakingThreshold] for [activationTime].
/// 3. **Stop speaking** once it has stayed below [silenceThreshold] for
///    [releaseTime]. The gap between the two thresholds is the hysteresis.
/// 4. **Order** the speakers loudest first. Two neighbours only swap places
///    when the quieter one is louder by more than [reorderMargin].
/// 5. **Dominant speaker:** the loudest speaker becomes dominant once they
///    have been loudest for [dominantSwitchTime] without interruption. The
///    first speaker is dominant at once, and a dominant speaker who falls
///    silent stays dominant until someone else takes over.
@immutable
class ActiveSpeakerConfig {
  /// Creates an active-speaker configuration.
  const ActiveSpeakerConfig({
    this.pollInterval = const Duration(milliseconds: 250),
    this.smoothingTimeConstant = const Duration(milliseconds: 300),
    this.speakingThreshold = 0.04,
    this.silenceThreshold = 0.02,
    this.activationTime = const Duration(milliseconds: 200),
    this.releaseTime = const Duration(milliseconds: 800),
    this.reorderMargin = 0.02,
    this.dominantSwitchTime = const Duration(milliseconds: 1500),
    this.localCanBeDominant = false,
    this.mutedActivationTime = const Duration(milliseconds: 500),
  }) : assert(
         silenceThreshold <= speakingThreshold,
         'silenceThreshold must not exceed speakingThreshold',
       ),
       assert(reorderMargin >= 0);

  /// How often audio levels are read (`getStats`). Default 250 ms.
  final Duration pollInterval;

  /// The time constant of the level smoothing: after this long, a step in
  /// the raw level is about 63% reflected in the smoothed level.
  /// [Duration.zero] turns smoothing off. Default 300 ms.
  final Duration smoothingTimeConstant;

  /// The smoothed level at or above which a participant starts speaking.
  /// Default 0.04.
  final double speakingThreshold;

  /// The smoothed level below which a speaking participant starts falling
  /// silent. Must not exceed [speakingThreshold]. Default 0.02.
  final double silenceThreshold;

  /// How long the level must stay at or above [speakingThreshold] before a
  /// participant counts as speaking. Filters out clicks and coughs; with
  /// the default poll interval, it takes two loud polls in a row. Default
  /// 200 ms.
  final Duration activationTime;

  /// How long the level must stay below [silenceThreshold] before a
  /// participant stops speaking. Bridges the pauses between words.
  /// Default 800 ms.
  final Duration releaseTime;

  /// How much louder (in level units) a speaker must be than the one ranked
  /// just above them to swap places. Keeps the order stable when two people
  /// talk at similar levels. Default 0.02.
  final double reorderMargin;

  /// How long a new loudest speaker must stay loudest before they become
  /// the dominant speaker. Default 1.5 s.
  final Duration dominantSwitchTime;

  /// Whether the local participant can be the dominant speaker. Apps
  /// usually don't put the user on their own stage. Default `false`. (The
  /// local participant is always in the speakers list while unmuted.)
  final bool localCanBeDominant;

  /// The [activationTime] used for the "speaking while muted" hint, which
  /// should not pop up for a cough. Default 500 ms.
  final Duration mutedActivationTime;

  /// Returns a copy with the given fields replaced.
  ActiveSpeakerConfig copyWith({
    Duration? pollInterval,
    Duration? smoothingTimeConstant,
    double? speakingThreshold,
    double? silenceThreshold,
    Duration? activationTime,
    Duration? releaseTime,
    double? reorderMargin,
    Duration? dominantSwitchTime,
    bool? localCanBeDominant,
    Duration? mutedActivationTime,
  }) => ActiveSpeakerConfig(
    pollInterval: pollInterval ?? this.pollInterval,
    smoothingTimeConstant: smoothingTimeConstant ?? this.smoothingTimeConstant,
    speakingThreshold: speakingThreshold ?? this.speakingThreshold,
    silenceThreshold: silenceThreshold ?? this.silenceThreshold,
    activationTime: activationTime ?? this.activationTime,
    releaseTime: releaseTime ?? this.releaseTime,
    reorderMargin: reorderMargin ?? this.reorderMargin,
    dominantSwitchTime: dominantSwitchTime ?? this.dominantSwitchTime,
    localCanBeDominant: localCanBeDominant ?? this.localCanBeDominant,
    mutedActivationTime: mutedActivationTime ?? this.mutedActivationTime,
  );

  @override
  bool operator ==(Object other) =>
      other is ActiveSpeakerConfig &&
      other.pollInterval == pollInterval &&
      other.smoothingTimeConstant == smoothingTimeConstant &&
      other.speakingThreshold == speakingThreshold &&
      other.silenceThreshold == silenceThreshold &&
      other.activationTime == activationTime &&
      other.releaseTime == releaseTime &&
      other.reorderMargin == reorderMargin &&
      other.dominantSwitchTime == dominantSwitchTime &&
      other.localCanBeDominant == localCanBeDominant &&
      other.mutedActivationTime == mutedActivationTime;

  @override
  int get hashCode => Object.hash(
    pollInterval,
    smoothingTimeConstant,
    speakingThreshold,
    silenceThreshold,
    activationTime,
    releaseTime,
    reorderMargin,
    dominantSwitchTime,
    localCanBeDominant,
    mutedActivationTime,
  );
}
