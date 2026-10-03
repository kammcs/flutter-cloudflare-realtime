import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'active_speaker_config.dart';

/// The detector's output after one sample.
@immutable
class ActiveSpeakerSnapshot {
  /// Creates a snapshot.
  const ActiveSpeakerSnapshot({
    required this.speakers,
    required this.dominantSpeaker,
    required this.localSpeakingWhileMuted,
    required this.levels,
  });

  /// An empty snapshot: nobody speaking.
  static const empty = ActiveSpeakerSnapshot(
    speakers: [],
    dominantSpeaker: null,
    localSpeakingWhileMuted: false,
    levels: {},
  );

  /// The participants speaking now, loudest first, with a stable order.
  /// Includes the local participant while unmuted.
  final List<String> speakers;

  /// The dominant speaker, for a "stage" layout. Changes only after
  /// [ActiveSpeakerOptions.dominantSwitchTime]; stays set while everyone is
  /// silent. `null` until someone has spoken.
  final String? dominantSpeaker;

  /// Whether the local participant is muted but speaking, for a "you are
  /// muted" hint.
  final bool localSpeakingWhileMuted;

  /// The smoothed level per participant, `0..1`, for level meters.
  final Map<String, double> levels;

  @override
  bool operator ==(Object other) =>
      other is ActiveSpeakerSnapshot &&
      listEquals(other.speakers, speakers) &&
      other.dominantSpeaker == dominantSpeaker &&
      other.localSpeakingWhileMuted == localSpeakingWhileMuted &&
      mapEquals(other.levels, levels);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(speakers),
    dominantSpeaker,
    localSpeakingWhileMuted,
    levels.length,
  );

  @override
  String toString() =>
      'ActiveSpeakerSnapshot(speakers: $speakers, dominant: $dominantSpeaker, '
      'localSpeakingWhileMuted: $localSpeakingWhileMuted)';
}

class _Participant {
  double level = 0;
  bool speaking = false;
  Duration? aboveSince;
  Duration? belowSince;
}

/// Turns periodic audio-level samples into active speakers.
///
/// Pure logic: no timers, no WebRTC. Feed it with [addSample] (the
/// [ActiveSpeakerOptions.pollInterval] poller does this) and read the
/// returned [ActiveSpeakerSnapshot]. The algorithm is described on
/// [ActiveSpeakerOptions].
///
/// A participant missing from a sample counts as silent (level 0), so its
/// smoothed level decays and it stops speaking normally. Its state is
/// dropped once it is silent and its level has decayed; [removeParticipant]
/// drops it at once, for a participant who left.
///
/// Internal: not exported from the package barrel. The Room wraps it.
class ActiveSpeakerDetector {
  /// Creates a detector.
  ///
  /// [localParticipantId] is the key under which samples carry the local
  /// microphone level; `null` if they don't.
  ActiveSpeakerDetector({
    this.config = const ActiveSpeakerOptions(),
    this.localParticipantId,
  });

  /// The tuning.
  final ActiveSpeakerOptions config;

  /// The key of the local participant in samples, if any.
  final String? localParticipantId;

  final Map<String, _Participant> _participants = {};
  Duration? _lastSampleAt;
  bool _localMuted = false;
  List<String> _order = const [];
  String? _dominant;
  String? _challenger;
  Duration? _challengerSince;
  ActiveSpeakerSnapshot _snapshot = ActiveSpeakerSnapshot.empty;

  /// The latest snapshot.
  ActiveSpeakerSnapshot get snapshot => _snapshot;

  /// Whether the local participant is muted (not broadcasting).
  bool get localMuted => _localMuted;

  /// Tells the detector whether the local microphone is muted.
  ///
  /// While muted, the local participant is left out of
  /// [ActiveSpeakerSnapshot.speakers] (nobody hears them) and feeds
  /// [ActiveSpeakerSnapshot.localSpeakingWhileMuted] instead, with
  /// [ActiveSpeakerOptions.mutedActivationTime]. Changing it restarts the
  /// local participant's speaking state, so the hint doesn't show the moment
  /// someone mutes mid-sentence.
  set localMuted(bool muted) {
    if (muted == _localMuted) return;
    _localMuted = muted;
    final local = _participants[localParticipantId];
    if (local != null) {
      local
        ..speaking = false
        ..aboveSince = null
        ..belowSince = null;
    }
  }

  /// Adds a sample taken at [now] (monotonic time) and returns the new
  /// snapshot.
  ///
  /// [levels] maps participant IDs to raw audio levels, `0..1`. Values
  /// outside that range are clamped; non-finite ones count as 0.
  ActiveSpeakerSnapshot addSample(Map<String, double> levels, Duration now) {
    final last = _lastSampleAt;
    var dt = last == null ? config.pollInterval : now - last;
    if (dt.isNegative) dt = Duration.zero;
    _lastSampleAt = now;
    final alpha = _smoothingFactor(dt);

    for (final id in {..._participants.keys, ...levels.keys}) {
      final p = _participants.putIfAbsent(id, _Participant.new);
      p.level += alpha * (_sanitize(levels[id]) - p.level);
      _updateSpeaking(id, p, now);
    }
    _participants.removeWhere(
      (id, p) =>
          !p.speaking &&
          p.aboveSince == null &&
          p.level < 1e-4 &&
          !levels.containsKey(id),
    );

    _order = _orderSpeakers();
    _updateDominant(now);
    final local = _participants[localParticipantId];
    return _snapshot = ActiveSpeakerSnapshot(
      speakers: List.unmodifiable(_order),
      dominantSpeaker: _dominant,
      localSpeakingWhileMuted: _localMuted && local != null && local.speaking,
      levels: Map.unmodifiable({
        for (final e in _participants.entries) e.key: e.value.level,
      }),
    );
  }

  /// Forgets [participantId], for a participant who left. Clears the
  /// dominant speaker if it was them. The next [addSample] reflects it.
  void removeParticipant(String participantId) {
    _participants.remove(participantId);
    _order = [
      for (final id in _order)
        if (id != participantId) id,
    ];
    if (_dominant == participantId) _dominant = null;
    if (_challenger == participantId) {
      _challenger = null;
      _challengerSince = null;
    }
  }

  /// Forgets everything, for example when the room is left.
  void reset() {
    _participants.clear();
    _lastSampleAt = null;
    _order = const [];
    _dominant = null;
    _challenger = null;
    _challengerSince = null;
    _snapshot = ActiveSpeakerSnapshot.empty;
  }

  double _smoothingFactor(Duration dt) {
    final tau = config.smoothingTimeConstant.inMicroseconds;
    if (tau <= 0) return 1;
    return 1 - math.exp(-dt.inMicroseconds / tau);
  }

  static double _sanitize(double? level) {
    if (level == null || !level.isFinite) return 0;
    return level.clamp(0.0, 1.0);
  }

  void _updateSpeaking(String id, _Participant p, Duration now) {
    final activation = id == localParticipantId && _localMuted
        ? config.mutedActivationTime
        : config.activationTime;
    if (!p.speaking) {
      if (p.level >= config.speakingThreshold) {
        final since = p.aboveSince ??= now;
        if (now - since >= activation) {
          p
            ..speaking = true
            ..aboveSince = null
            ..belowSince = null;
        }
      } else {
        p.aboveSince = null;
      }
    } else {
      if (p.level < config.silenceThreshold) {
        final since = p.belowSince ??= now;
        if (now - since >= config.releaseTime) {
          p
            ..speaking = false
            ..belowSince = null
            ..aboveSince = null;
        }
      } else {
        p.belowSince = null;
      }
    }
  }

  bool _audible(String id) {
    final p = _participants[id];
    if (p == null || !p.speaking) return false;
    return !(id == localParticipantId && _localMuted);
  }

  List<String> _orderSpeakers() {
    double level(String id) => _participants[id]!.level;
    // Keep the previous order for those still speaking, then append new
    // speakers loudest first (ties by ID, for determinism).
    final order = [
      for (final id in _order)
        if (_audible(id)) id,
    ];
    final previous = order.toSet();
    final newcomers =
        [
          for (final id in _participants.keys)
            if (_audible(id) && !previous.contains(id)) id,
        ]..sort((a, b) {
          final byLevel = level(b).compareTo(level(a));
          return byLevel != 0 ? byLevel : a.compareTo(b);
        });
    order.addAll(newcomers);
    // Bubble passes: swap neighbours only when the lower one is louder by
    // more than the margin. At most n passes, so it always terminates.
    for (var pass = 0; pass < order.length; pass++) {
      var swapped = false;
      for (var i = 0; i + 1 < order.length; i++) {
        if (level(order[i + 1]) > level(order[i]) + config.reorderMargin) {
          final tmp = order[i];
          order[i] = order[i + 1];
          order[i + 1] = tmp;
          swapped = true;
        }
      }
      if (!swapped) break;
    }
    return order;
  }

  void _updateDominant(Duration now) {
    String? top;
    for (final id in _order) {
      if (config.localCanBeDominant || id != localParticipantId) {
        top = id;
        break;
      }
    }
    if (top == null || top == _dominant) {
      _challenger = null;
      _challengerSince = null;
      return;
    }
    if (_dominant == null) {
      _dominant = top;
      _challenger = null;
      _challengerSince = null;
      return;
    }
    if (_challenger != top) {
      _challenger = top;
      _challengerSince = now;
    }
    if (now - _challengerSince! >= config.dominantSwitchTime) {
      _dominant = top;
      _challenger = null;
      _challengerSince = null;
    }
  }
}
