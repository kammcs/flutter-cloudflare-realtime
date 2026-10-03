import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/active_speaker_detector.dart';
import 'package:flutter_test/flutter_test.dart';

const _tick = Duration(milliseconds: 250);

/// Feeds a detector samples every 250 ms and tracks time.
class _Driver {
  _Driver(this.detector);

  final ActiveSpeakerDetector detector;
  Duration now = Duration.zero;

  ActiveSpeakerSnapshot feed(Map<String, double> levels, {int times = 1}) {
    late ActiveSpeakerSnapshot snapshot;
    for (var i = 0; i < times; i++) {
      now += _tick;
      snapshot = detector.addSample(levels, now);
    }
    return snapshot;
  }
}

/// No smoothing, so raw levels drive the thresholds directly.
const _raw = ActiveSpeakerOptions(smoothingTimeConstant: Duration.zero);

void main() {
  test('defaults', () {
    const config = ActiveSpeakerOptions();
    expect(config.pollInterval, const Duration(milliseconds: 250));
    expect(config.speakingThreshold, 0.04);
    expect(config.silenceThreshold, 0.02);
    expect(config.activationTime, const Duration(milliseconds: 200));
    expect(config.releaseTime, const Duration(milliseconds: 800));
    expect(config.dominantSwitchTime, const Duration(milliseconds: 1500));
    expect(config.localCanBeDominant, isFalse);
    expect(config, const ActiveSpeakerOptions());
    expect(config.copyWith(speakingThreshold: 0.1).speakingThreshold, 0.1);
  });

  group('speaking state', () {
    test('silence produces no speakers', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      final snap = d.feed({'a': 0.001, 'b': 0.0}, times: 10);
      expect(snap.speakers, isEmpty);
      expect(snap.dominantSpeaker, isNull);
    });

    test('one loud sample is not enough; two in a row are', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      expect(d.feed({'a': 0.3}).speakers, isEmpty); // A click.
      expect(d.feed({'a': 0.0}).speakers, isEmpty);
      expect(d.feed({'a': 0.3}).speakers, isEmpty);
      expect(d.feed({'a': 0.3}).speakers, ['a']);
    });

    test('pauses shorter than the release time are bridged', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      d.feed({'a': 0.3}, times: 2);
      // Three quiet polls: 500 ms since the first, under the 800 ms release.
      expect(d.feed({'a': 0.0}, times: 3).speakers, ['a']);
      expect(d.feed({'a': 0.3}).speakers, ['a']);
      // Quiet again, long enough this time.
      expect(d.feed({'a': 0.0}, times: 4).speakers, ['a']);
      expect(d.feed({'a': 0.0}).speakers, isEmpty);
    });

    test('levels between the thresholds keep but do not start speaking', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      expect(d.feed({'a': 0.03}, times: 10).speakers, isEmpty);
      d.feed({'a': 0.3}, times: 2);
      expect(d.feed({'a': 0.03}, times: 10).speakers, ['a']);
    });

    test('smoothing damps a single spike', () {
      final d = _Driver(ActiveSpeakerDetector()); // Default smoothing.
      final snap = d.feed({'a': 0.3});
      // 1 − e^(−250/300) ≈ 0.565 of the step.
      expect(snap.levels['a'], closeTo(0.3 * 0.5654, 0.001));
      expect(d.feed({'a': 0.0}).levels['a'], closeTo(0.0738, 0.001));
    });

    test('with default smoothing, steady speech is detected within 500 ms', () {
      final d = _Driver(ActiveSpeakerDetector());
      d.feed({'a': 0.1});
      expect(d.feed({'a': 0.1}).speakers, ['a']);
    });

    test('invalid levels are clamped or treated as silence', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      final snap = d.feed({'a': 7.0, 'b': double.nan, 'c': -1});
      expect(snap.levels['a'], 1.0);
      expect(snap.levels['b'], 0.0);
      expect(snap.levels['c'], 0.0);
    });

    test('a participant missing from samples fades out and is dropped', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      d.feed({'a': 0.3}, times: 2);
      expect(d.feed({}, times: 3).speakers, ['a']);
      final snap = d.feed({}, times: 2);
      expect(snap.speakers, isEmpty);
      expect(snap.levels.containsKey('a'), isFalse);
    });
  });

  group('ordering', () {
    test('speakers are ordered loudest first', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      final snap = d.feed({'a': 0.1, 'b': 0.5, 'c': 0.3}, times: 2);
      expect(snap.speakers, ['b', 'c', 'a']);
    });

    test('ties are ordered by ID', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      expect(d.feed({'z': 0.2, 'y': 0.2}, times: 2).speakers, ['y', 'z']);
    });

    test('small level differences do not reorder', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      expect(d.feed({'a': 0.30, 'b': 0.20}, times: 2).speakers, ['a', 'b']);
      // b is now louder, but by less than the 0.02 margin.
      expect(d.feed({'a': 0.30, 'b': 0.315}).speakers, ['a', 'b']);
      // By more than the margin: swap.
      expect(d.feed({'a': 0.30, 'b': 0.33}).speakers, ['b', 'a']);
    });

    test('a loud newcomer moves to the front', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      d.feed({'a': 0.2, 'b': 0.1}, times: 2);
      final snap = d.feed({'a': 0.2, 'b': 0.1, 'c': 0.6}, times: 2);
      expect(snap.speakers, ['c', 'a', 'b']);
    });
  });

  group('dominant speaker', () {
    test('the first speaker is dominant at once', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      expect(d.feed({'a': 0.3}, times: 2).dominantSpeaker, 'a');
    });

    test('a new loudest speaker takes over only after the switch time', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      d.feed({'a': 0.3}, times: 2);
      // b becomes loudest (active after 2 ticks), then must hold 1.5 s.
      var snap = d.feed({'a': 0.3, 'b': 0.6}, times: 2);
      expect(snap.speakers.first, 'b');
      expect(snap.dominantSpeaker, 'a');
      snap = d.feed({'a': 0.3, 'b': 0.6}, times: 5); // 1.25 s as loudest.
      expect(snap.dominantSpeaker, 'a');
      snap = d.feed({'a': 0.3, 'b': 0.6}); // 1.5 s.
      expect(snap.dominantSpeaker, 'b');
    });

    test('an interjection does not steal the stage', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      d.feed({'a': 0.3}, times: 4);
      d.feed({'a': 0.3, 'b': 0.6}, times: 4); // Loudest for 750 ms.
      final snap = d.feed({'a': 0.3, 'b': 0.0}, times: 8);
      expect(snap.speakers, ['a']);
      expect(snap.dominantSpeaker, 'a');
    });

    test('the dominant speaker stays while everyone is silent', () {
      final d = _Driver(ActiveSpeakerDetector(config: _raw));
      d.feed({'a': 0.3}, times: 2);
      final snap = d.feed({'a': 0.0}, times: 20);
      expect(snap.speakers, isEmpty);
      expect(snap.dominantSpeaker, 'a');
    });

    test('the local participant is not dominant by default', () {
      final d = _Driver(
        ActiveSpeakerDetector(config: _raw, localParticipantId: 'me'),
      );
      final snap = d.feed({'me': 0.5, 'a': 0.2}, times: 2);
      expect(snap.speakers, ['me', 'a']);
      expect(snap.dominantSpeaker, 'a');
    });

    test('localCanBeDominant allows it', () {
      final d = _Driver(
        ActiveSpeakerDetector(
          config: _raw.copyWith(localCanBeDominant: true),
          localParticipantId: 'me',
        ),
      );
      expect(d.feed({'me': 0.5, 'a': 0.2}, times: 2).dominantSpeaker, 'me');
    });

    test('removing the dominant speaker clears it', () {
      final detector = ActiveSpeakerDetector(config: _raw);
      final d = _Driver(detector);
      d.feed({'a': 0.3, 'b': 0.1}, times: 2);
      detector.removeParticipant('a');
      final snap = d.feed({'b': 0.1});
      expect(snap.speakers, ['b']);
      expect(snap.dominantSpeaker, 'b');
    });
  });

  group('local speaking while muted', () {
    test('a muted local participant is left out of speakers and hinted', () {
      final detector = ActiveSpeakerDetector(
        config: _raw,
        localParticipantId: 'me',
      );
      final d = _Driver(detector)..detector.localMuted = true;
      // The hint waits 500 ms, longer than normal activation.
      var snap = d.feed({'me': 0.3, 'a': 0.2}, times: 2);
      expect(snap.speakers, ['a']);
      expect(snap.localSpeakingWhileMuted, isFalse);
      snap = d.feed({'me': 0.3, 'a': 0.2}); // 500 ms above the threshold.
      expect(snap.localSpeakingWhileMuted, isTrue);
      expect(snap.speakers, ['a']);
    });

    test('muting mid-sentence does not show the hint at once', () {
      final detector = ActiveSpeakerDetector(
        config: _raw,
        localParticipantId: 'me',
      );
      final d = _Driver(detector);
      expect(d.feed({'me': 0.3}, times: 2).speakers, ['me']);
      detector.localMuted = true;
      expect(detector.localMuted, isTrue);
      final snap = d.feed({'me': 0.3});
      expect(snap.speakers, isEmpty);
      expect(snap.localSpeakingWhileMuted, isFalse);
    });

    test('unmuting ends the hint and restarts detection', () {
      final detector = ActiveSpeakerDetector(
        config: _raw,
        localParticipantId: 'me',
      )..localMuted = true;
      final d = _Driver(detector);
      expect(d.feed({'me': 0.3}, times: 4).localSpeakingWhileMuted, isTrue);
      detector.localMuted = false;
      var snap = d.feed({'me': 0.3});
      expect(snap.localSpeakingWhileMuted, isFalse);
      expect(snap.speakers, isEmpty);
      snap = d.feed({'me': 0.3});
      expect(snap.speakers, ['me']);
    });
  });

  test('reset forgets everything', () {
    final detector = ActiveSpeakerDetector(config: _raw);
    final d = _Driver(detector);
    d.feed({'a': 0.3}, times: 2);
    detector.reset();
    expect(detector.snapshot, ActiveSpeakerSnapshot.empty);
    expect(d.feed({'b': 0.3}, times: 2).dominantSpeaker, 'b');
  });

  test('time going backwards is treated as no elapsed time', () {
    final detector = ActiveSpeakerDetector();
    detector.addSample({'a': 0.3}, const Duration(seconds: 10));
    final level = detector.snapshot.levels['a'];
    detector.addSample({'a': 0.0}, const Duration(seconds: 5));
    expect(detector.snapshot.levels['a'], level);
  });
}
