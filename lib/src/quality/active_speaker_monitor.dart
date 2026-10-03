import 'dart:async';

import 'package:flutter/foundation.dart';

import '../util/state_stream.dart';
import 'active_speaker_config.dart';
import 'active_speaker_detector.dart';
import 'audio_level_source.dart';

/// Polls an [AudioLevelSource] every [ActiveSpeakerOptions.pollInterval] and
/// runs the samples through an [ActiveSpeakerDetector].
///
/// - Polls never overlap: a tick that arrives while the previous
///   `getAudioLevels` is still running is skipped.
/// - A failed poll is skipped silently. `getStats` can fail briefly during
///   renegotiation or teardown, and one missing sample doesn't matter.
/// - The outputs replay their current value to new listeners and only emit
///   changes.
///
/// Internal: not exported from the package barrel. The Room owns one per
/// room and re-exposes [speakers] as `activeSpeakers`.
class ActiveSpeakerMonitor {
  /// Creates a monitor. Call [start] to begin polling.
  ///
  /// [clock] returns monotonic elapsed time; it defaults to a [Stopwatch]
  /// started here. Tests pass fake time.
  ActiveSpeakerMonitor({
    required AudioLevelSource source,
    ActiveSpeakerOptions config = const ActiveSpeakerOptions(),
    String? localParticipantId,
    Duration Function()? clock,
  }) : _source = source,
       _detector = ActiveSpeakerDetector(
         config: config,
         localParticipantId: localParticipantId,
       ),
       _clock = clock ?? _stopwatchClock();

  static Duration Function() _stopwatchClock() {
    final stopwatch = Stopwatch()..start();
    return () => stopwatch.elapsed;
  }

  final AudioLevelSource _source;
  final ActiveSpeakerDetector _detector;
  final Duration Function() _clock;
  Timer? _timer;
  bool _polling = false;
  bool _disposed = false;

  final StateStream<List<String>> _speakers = StateStream(
    const [],
    equals: listEquals,
  );
  final StateStream<String?> _dominant = StateStream(null, distinct: true);
  final StateStream<bool> _mutedHint = StateStream(false, distinct: true);
  final StateStream<ActiveSpeakerSnapshot> _snapshots = StateStream(
    ActiveSpeakerSnapshot.empty,
    distinct: true,
  );

  /// The tuning.
  ActiveSpeakerOptions get config => _detector.config;

  /// Whether the poll timer is running.
  bool get isRunning => _timer != null;

  /// The speaking participants, loudest first. Replays the current list.
  Stream<List<String>> get speakers => _speakers.stream;

  /// The current value of [speakers].
  List<String> get currentSpeakers => _speakers.value;

  /// The dominant speaker. Replays the current value.
  Stream<String?> get dominantSpeaker => _dominant.stream;

  /// The current value of [dominantSpeaker].
  String? get currentDominantSpeaker => _dominant.value;

  /// Whether the local participant is speaking while muted. Replays the
  /// current value.
  Stream<bool> get localSpeakingWhileMuted => _mutedHint.stream;

  /// Every changed snapshot, including levels, for level meters. Replays
  /// the current one.
  Stream<ActiveSpeakerSnapshot> get snapshots => _snapshots.stream;

  /// The latest snapshot.
  ActiveSpeakerSnapshot get snapshot => _snapshots.value;

  /// Whether the local microphone is muted; see
  /// [ActiveSpeakerDetector.localMuted].
  bool get localMuted => _detector.localMuted;
  set localMuted(bool muted) => _detector.localMuted = muted;

  /// Starts polling. Does nothing if already running or disposed.
  void start() {
    if (_timer != null || _disposed) return;
    _timer = Timer.periodic(config.pollInterval, (_) => pollNow());
  }

  /// Stops polling and clears the outputs (nobody is speaking).
  void stop() {
    _timer?.cancel();
    _timer = null;
    _detector.reset();
    if (!_disposed) _publish(ActiveSpeakerSnapshot.empty);
  }

  /// Takes one sample now. The timer calls this; tests may too.
  Future<void> pollNow() async {
    if (_polling || _disposed) return;
    _polling = true;
    try {
      final Map<String, double> levels;
      try {
        levels = await _source.getAudioLevels();
      } catch (_) {
        return; // Skip this sample; see the class docs.
      }
      if (_disposed) return;
      _publish(_detector.addSample(levels, _clock()));
    } finally {
      _polling = false;
    }
  }

  /// Forgets a participant who left.
  void removeParticipant(String participantId) {
    _detector.removeParticipant(participantId);
  }

  /// Stops polling and closes the streams.
  Future<void> dispose() async {
    if (_disposed) return;
    _timer?.cancel();
    _timer = null;
    _disposed = true;
    await Future.wait([
      _speakers.close(),
      _dominant.close(),
      _mutedHint.close(),
      _snapshots.close(),
    ]);
  }

  void _publish(ActiveSpeakerSnapshot snapshot) {
    _speakers.set(snapshot.speakers);
    _dominant.set(snapshot.dominantSpeaker);
    _mutedHint.set(snapshot.localSpeakingWhileMuted);
    _snapshots.set(snapshot);
  }
}
