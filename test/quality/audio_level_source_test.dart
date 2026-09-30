import 'package:cloudflare_realtime/src/quality/audio_level_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

StatsReport _report(String id, String type, Map<String, Object?> values) =>
    StatsReport(id, type, 0, values);

StatsReport _inbound(
  String id, {
  String kind = 'audio',
  String? track,
  String? mid,
  num? audioLevel,
  num? energy,
  num? duration,
}) => _report(id, 'inbound-rtp', {
  'kind': kind,
  'trackIdentifier': ?track,
  'mid': ?mid,
  'audioLevel': ?audioLevel,
  'totalAudioEnergy': ?energy,
  'totalSamplesDuration': ?duration,
});

void main() {
  late List<StatsReport> reports;
  late int calls;

  setUp(() {
    reports = [];
    calls = 0;
  });

  Future<List<StatsReport>> getStats() async {
    calls++;
    return reports;
  }

  /// Maps mids "1".."9" to participants p1..p9, by track ID as a fallback.
  String? byMid(InboundAudioStream s) =>
      s.mid != null ? 'p${s.mid}' : s.trackIdentifier;

  test('reads audioLevel from audio inbound-rtp reports', () async {
    final source = StatsAudioLevelSource(
      getStats: getStats,
      participantFor: byMid,
    );
    reports = [
      _inbound('in1', mid: '1', audioLevel: 0.25),
      _inbound('in2', mid: '2', audioLevel: 0),
      _inbound('vid', kind: 'video', mid: '3'),
      _report('cp', 'candidate-pair', {'bytesSent': 10}),
    ];
    expect(await source.getAudioLevels(), {'p1': 0.25, 'p2': 0.0});
    expect(calls, 1);
  });

  test('resolves by trackIdentifier and mid, and skips unresolved', () async {
    final seen = <InboundAudioStream>[];
    final source = StatsAudioLevelSource(
      getStats: getStats,
      participantFor: (s) {
        seen.add(s);
        return s.trackIdentifier == 'known' ? 'alice' : null;
      },
    );
    reports = [
      _inbound('a', track: 'known', mid: '4', audioLevel: 0.5),
      _inbound('b', track: 'screen-audio', audioLevel: 0.9),
    ];
    expect(await source.getAudioLevels(), {'alice': 0.5});
    expect(seen, [
      const InboundAudioStream(trackIdentifier: 'known', mid: '4'),
      const InboundAudioStream(trackIdentifier: 'screen-audio'),
    ]);
  });

  test('the loudest stream wins when several map to one participant', () {
    final source = StatsAudioLevelSource(
      getStats: getStats,
      participantFor: (_) => 'p',
    );
    reports = [
      _inbound('a', audioLevel: 0.2),
      _inbound('b', audioLevel: 0.6),
      _inbound('c', audioLevel: 0.1),
    ];
    expect(source.getAudioLevels(), completion({'p': 0.6}));
  });

  test('accepts the legacy mediaType field and integer values', () async {
    final source = StatsAudioLevelSource(
      getStats: getStats,
      participantFor: byMid,
    );
    reports = [
      _report('x', 'inbound-rtp', {
        'mediaType': 'audio',
        'mid': '1',
        'audioLevel': 1,
      }),
    ];
    expect(await source.getAudioLevels(), {'p1': 1.0});
  });

  test('clamps out-of-range levels', () async {
    final source = StatsAudioLevelSource(
      getStats: getStats,
      participantFor: byMid,
    );
    reports = [_inbound('x', mid: '1', audioLevel: 3.5)];
    expect(await source.getAudioLevels(), {'p1': 1.0});
  });

  group('energy fallback', () {
    test('derives the RMS level from energy and duration deltas', () async {
      final source = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
      );
      reports = [_inbound('x', mid: '1', energy: 1.0, duration: 10.0)];
      // First poll: no previous totals, no reading.
      expect(await source.getAudioLevels(), isEmpty);

      // 0.25 s at a level of 0.2 adds 0.2² × 0.25 = 0.01 energy.
      reports = [_inbound('x', mid: '1', energy: 1.01, duration: 10.25)];
      final levels = await source.getAudioLevels();
      expect(levels['p1'], closeTo(0.2, 1e-9));
    });

    test('no new samples means silence', () async {
      final source = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
      );
      reports = [_inbound('x', mid: '1', energy: 1.0, duration: 10.0)];
      await source.getAudioLevels();
      expect(await source.getAudioLevels(), {'p1': 0.0});
    });

    test('a counter reset reads as silence, then recovers', () async {
      final source = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
      );
      reports = [_inbound('x', mid: '1', energy: 5.0, duration: 10.0)];
      await source.getAudioLevels();
      reports = [_inbound('x', mid: '1', energy: 0.0, duration: 0.0)];
      expect(await source.getAudioLevels(), {'p1': 0.0});
      reports = [_inbound('x', mid: '1', energy: 0.04, duration: 1.0)];
      expect((await source.getAudioLevels())['p1'], closeTo(0.2, 1e-9));
    });

    test('audioLevel wins when both are present', () async {
      final source = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
      );
      reports = [
        _inbound('x', mid: '1', audioLevel: 0.7, energy: 1, duration: 1),
      ];
      expect(await source.getAudioLevels(), {'p1': 0.7});
    });

    test('forgets streams that disappear', () async {
      final source = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
      );
      reports = [_inbound('x', mid: '1', energy: 1.0, duration: 10.0)];
      await source.getAudioLevels();
      reports = [];
      await source.getAudioLevels();
      // It came back: that's a first poll again, not a delta from before.
      reports = [_inbound('x', mid: '1', energy: 2.0, duration: 11.0)];
      expect(await source.getAudioLevels(), isEmpty);
    });
  });

  group('local microphone', () {
    StatsReport source(String id, String track, double level) => _report(
      id,
      'media-source',
      {'kind': 'audio', 'trackIdentifier': track, 'audioLevel': level},
    );

    test('reads audio media-source under the local ID', () async {
      final levels = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
        localParticipantId: 'me',
      );
      reports = [
        source('ms1', 'mic', 0.3),
        _report('ms2', 'media-source', {
          'kind': 'video',
          'trackIdentifier': 'cam',
        }),
        _inbound('in', mid: '1', audioLevel: 0.1),
      ];
      expect(await levels.getAudioLevels(), {'me': 0.3, 'p1': 0.1});
    });

    test('picks the microphone track when told which it is', () async {
      final levels = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
        localParticipantId: 'me',
        localTrackId: () => 'mic',
      );
      reports = [source('ms1', 'mic', 0.1), source('ms2', 'screen', 0.8)];
      expect(await levels.getAudioLevels(), {'me': 0.1});
    });

    test('takes the loudest source when not told', () async {
      final levels = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
        localParticipantId: 'me',
      );
      reports = [source('ms1', 'mic', 0.1), source('ms2', 'other', 0.8)];
      expect(await levels.getAudioLevels(), {'me': 0.8});
    });

    test('is skipped without a local ID', () async {
      final levels = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
      );
      reports = [source('ms1', 'mic', 0.5)];
      expect(await levels.getAudioLevels(), isEmpty);
    });

    test('uses the energy fallback too', () async {
      final levels = StatsAudioLevelSource(
        getStats: getStats,
        participantFor: byMid,
        localParticipantId: 'me',
      );
      StatsReport energy(num e, num d) => _report('ms', 'media-source', {
        'kind': 'audio',
        'totalAudioEnergy': e,
        'totalSamplesDuration': d,
      });
      reports = [energy(0, 0)];
      expect(await levels.getAudioLevels(), isEmpty);
      reports = [energy(0.5 * 0.5 * 2, 2)];
      expect((await levels.getAudioLevels())['me'], closeTo(0.5, 1e-9));
    });
  });

  test('propagates getStats errors to the poller', () {
    final source = StatsAudioLevelSource(
      getStats: () async => throw StateError('closed'),
      participantFor: byMid,
    );
    expect(source.getAudioLevels(), throwsStateError);
  });
}
