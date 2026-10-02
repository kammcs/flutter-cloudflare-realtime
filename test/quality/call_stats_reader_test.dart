import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/call_stats_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

/// A reader on a test clock; `timestamp`s are in µs as on native platforms.
class _Reader {
  Duration now = Duration.zero;
  late final CallStatsReader reader = CallStatsReader(
    elapsed: () => now,
    now: () => DateTime(2026, 10, 2),
    timestampsInMicroseconds: true,
  );
}

const _cam = (
  trackName: 'camera-1',
  kind: TrackKind.video,
  source: TrackSource.camera,
  mid: '0',
  trackId: 'cam-track',
);

const _remoteMic = (
  id: 'ann/mic-1',
  participantId: 'ann',
  trackName: 'mic-1',
  kind: TrackKind.audio,
  source: TrackSource.microphone,
  mid: '3',
  trackId: 'ann-mic',
  rid: null,
);

const _remoteCam = (
  id: 'ann/camera-1',
  participantId: 'ann',
  trackName: 'camera-1',
  kind: TrackKind.video,
  source: TrackSource.camera,
  mid: '4',
  trackId: 'ann-cam',
  rid: 'b',
);

StatsReport _outbound(
  String rid, {
  required int index,
  int bytes = 0,
  double ts = 0,
  String? mid = '0',
  Map<String, Object?> extra = const {},
}) => StatsReport('out-$rid', 'outbound-rtp', ts, {
  'kind': 'video',
  'mid': ?mid,
  'rid': rid,
  'encodingIndex': index,
  'mediaSourceId': 'src-cam',
  'codecId': 'codec-vp8',
  'bytesSent': bytes,
  'ssrc': 100 + index,
  ...extra,
});

final _vp8 = StatsReport('codec-vp8', 'codec', 0, {
  'mimeType': 'video/VP8',
  'payloadType': 96,
});

void main() {
  group('local tracks', () {
    test('maps every simulcast layer by mid, highest first, with codec, '
        'counters and the SFU\'s receiver report', () {
      final r = _Reader();
      final stats = r.reader.read(
        [
          _vp8,
          _outbound('c', index: 2),
          _outbound(
            'a',
            index: 0,
            extra: {
              'frameWidth': 1280,
              'frameHeight': 720,
              'framesPerSecond': 30.0,
              'qualityLimitationReason': 'bandwidth',
              'packetsSent': 900,
              'nackCount': 3,
              'pliCount': 1,
              'firCount': 0,
              'active': true,
              'remoteId': 'ri-a',
            },
          ),
          _outbound('b', index: 1),
          StatsReport('ri-a', 'remote-inbound-rtp', 0, {
            'kind': 'video',
            'localId': 'out-a',
            'roundTripTime': 0.025,
            'packetsLost': 4,
            'fractionLost': 0.01,
            'jitter': 0.004,
          }),
          // Another track's stream on another mid: not this track.
          StatsReport('out-x', 'outbound-rtp', 0, {
            'kind': 'video',
            'mid': '9',
            'bytesSent': 1,
          }),
        ],
        local: [_cam],
      );
      final cam = stats.local['camera-1']!;
      expect([for (final l in cam.layers) l.rid], ['a', 'b', 'c']);
      expect(cam.codec, 'video/VP8');
      expect(cam.kind, TrackKind.video);
      expect(cam.source, TrackSource.camera);
      final a = cam.layer('a')!;
      expect(a.width, 1280);
      expect(a.height, 720);
      expect(a.framesPerSecond, 30);
      expect(a.qualityLimitationReason, QualityLimitationReason.bandwidth);
      expect(a.packetsSent, 900);
      expect(a.nackCount, 3);
      expect(a.pliCount, 1);
      expect(a.firCount, 0);
      expect(a.active, isTrue);
      expect(a.roundTripTime, const Duration(milliseconds: 25));
      expect(a.packetsLost, 4);
      expect(a.fractionLost, 0.01);
      expect(a.jitter, const Duration(milliseconds: 4));
      // Missing values are null, not 0.
      final b = cam.layer('b')!;
      expect(b.width, isNull);
      expect(b.framesPerSecond, isNull);
      expect(b.qualityLimitationReason, isNull);
      expect(b.roundTripTime, isNull);
      expect(b.nackCount, isNull);
      // No previous read: no rates.
      expect(a.bitrate, isNull);
      expect(cam.bitrate, isNull);
      expect(stats.interval, isNull);
    });

    test('finds the layers through the media-source when there is no mid, '
        'and the receiver report by ssrc', () {
      final r = _Reader();
      final stats = r.reader.read(
        [
          StatsReport('src-cam', 'media-source', 0, {
            'kind': 'video',
            'trackIdentifier': 'cam-track',
          }),
          _outbound('a', index: 0, mid: null),
          StatsReport('ri', 'remote-inbound-rtp', 0, {
            'kind': 'video',
            'ssrc': 100,
            'roundTripTime': 0.04,
          }),
        ],
        local: [_cam],
      );
      final layer = stats.local['camera-1']!.layers.single;
      expect(layer.rid, 'a');
      expect(layer.roundTripTime, const Duration(milliseconds: 40));
    });

    test('a track without reports is left out', () {
      final r = _Reader();
      expect(r.reader.read([_vp8], local: [_cam]).local, isEmpty);
    });

    test('the local audio level comes from the media-source', () {
      final r = _Reader();
      final stats = r.reader.read(
        [
          StatsReport('src-mic', 'media-source', 0, {
            'kind': 'audio',
            'trackIdentifier': 'mic-track',
            'audioLevel': 0.25,
          }),
          StatsReport('out-mic', 'outbound-rtp', 0, {
            'kind': 'audio',
            'mid': '1',
            'mediaSourceId': 'src-mic',
          }),
        ],
        local: [
          (
            trackName: 'mic',
            kind: TrackKind.audio,
            source: TrackSource.microphone,
            mid: '1',
            trackId: 'mic-track',
          ),
        ],
      );
      final mic = stats.local['mic']!;
      expect(mic.audioLevel, 0.25);
      expect(mic.layers.single.rid, isNull);
    });
  });

  group('rates', () {
    test('bitrate and frame rate from the change between reads, over the '
        'reports\' timestamps when plausible', () {
      final r = _Reader();
      r.reader.read(
        [
          _outbound(
            'a',
            index: 0,
            bytes: 10000,
            ts: 1e6,
            extra: {'framesSent': 0},
          ),
        ],
        local: [_cam],
      );
      // Two seconds by the wall clock, but the reports are 2.5 s apart
      // (µs): the reports' own interval wins.
      r.now = const Duration(seconds: 2);
      final stats = r.reader.read(
        [
          _outbound(
            'a',
            index: 0,
            bytes: 260000,
            ts: 3.5e6,
            extra: {'framesSent': 75},
          ),
        ],
        local: [_cam],
      );
      final a = stats.local['camera-1']!.layer('a')!;
      expect(a.bitrate, 800000); // 250000 bytes * 8 / 2.5 s
      expect(a.framesPerSecond, 30); // no framesPerSecond: 75 / 2.5 s
      expect(stats.interval, const Duration(seconds: 2));
    });

    test('an implausible timestamp interval falls back to the wall clock', () {
      final r = _Reader();
      r.reader.read(
        [_outbound('a', index: 0, bytes: 0, ts: 1000)],
        local: [_cam],
      );
      r.now = const Duration(seconds: 2);
      // 1 ms apart if µs: not plausible (milliseconds on the web would be).
      final stats = r.reader.read(
        [_outbound('a', index: 0, bytes: 100000, ts: 2000)],
        local: [_cam],
      );
      expect(stats.local['camera-1']!.layer('a')!.bitrate, 400000);
    });

    test('a counter that went down gives no rate; reset() forgets', () {
      final r = _Reader();
      r.reader.read([_outbound('a', index: 0, bytes: 5000)], local: [_cam]);
      r.now = const Duration(seconds: 2);
      var stats = r.reader.read(
        [_outbound('a', index: 0, bytes: 100)],
        local: [_cam],
      );
      expect(stats.local['camera-1']!.layer('a')!.bitrate, isNull);
      r.now = const Duration(seconds: 4);
      stats = r.reader.read(
        [_outbound('a', index: 0, bytes: 1100)],
        local: [_cam],
      );
      expect(stats.local['camera-1']!.layer('a')!.bitrate, 4000);
      r.reader.reset();
      r.now = const Duration(seconds: 6);
      stats = r.reader.read(
        [_outbound('a', index: 0, bytes: 9100)],
        local: [_cam],
      );
      expect(stats.local['camera-1']!.layer('a')!.bitrate, isNull);
      expect(stats.interval, isNull);
    });

    test('remote loss, concealment and bitrate over the interval', () {
      final r = _Reader();
      StatsReport mic(int received, int lost, int bytes, int samples, int c) =>
          StatsReport('in-mic', 'inbound-rtp', 0, {
            'kind': 'audio',
            'mid': '3',
            'packetsReceived': received,
            'packetsLost': lost,
            'bytesReceived': bytes,
            'totalSamplesReceived': samples,
            'concealedSamples': c,
            'jitter': 0.012,
            'audioLevel': 0.1,
          });
      r.reader.read([mic(1000, 10, 50000, 480000, 100)], remote: [_remoteMic]);
      r.now = const Duration(seconds: 2);
      final stats = r.reader.read(
        [mic(1095, 15, 60000, 576000, 1060)],
        remote: [_remoteMic],
      );
      final t = stats.remote['ann/mic-1']!;
      expect(t.participantId, 'ann');
      expect(t.packetLoss, closeTo(5 / 100, 1e-9));
      expect(t.bitrate, 40000);
      expect(t.concealment, closeTo(960 / 96000, 1e-9));
      expect(t.jitter, const Duration(milliseconds: 12));
      expect(t.audioLevel, 0.1);
      expect(t.packetsLost, 15);
      // Video-only fields stay null for audio.
      expect(t.width, isNull);
      expect(t.freezeCount, isNull);
    });
  });

  group('remote tracks', () {
    test('match by mid, else by trackIdentifier; numbers may be strings and '
        'kind may be mediaType', () {
      final r = _Reader();
      final stats = r.reader.read(
        [
          _vp8,
          StatsReport('in-cam', 'inbound-rtp', 0, {
            'mediaType': 'video',
            'trackIdentifier': 'ann-cam',
            'codecId': 'codec-vp8',
            'frameWidth': '640',
            'frameHeight': 360,
            'framesPerSecond': 29.97,
            'framesDecoded': 300,
            'framesDropped': 2,
            'freezeCount': 1,
            'totalFreezesDuration': 0.5,
            'pliCount': 2,
          }),
          StatsReport('in-mic', 'inbound-rtp', 0, {
            'kind': 'audio',
            'mid': '3',
          }),
          // Same mid, wrong kind: never matched.
          StatsReport('in-x', 'inbound-rtp', 0, {'kind': 'video', 'mid': '3'}),
        ],
        remote: [_remoteMic, _remoteCam],
      );
      final cam = stats.remote['ann/camera-1']!;
      expect(cam.codec, 'video/VP8');
      expect(cam.width, 640);
      expect(cam.height, 360);
      expect(cam.framesPerSecond, closeTo(29.97, 1e-9));
      expect(cam.framesDropped, 2);
      expect(cam.freezeCount, 1);
      expect(cam.totalFreezesDuration, const Duration(milliseconds: 500));
      expect(cam.rid, 'b');
      expect(stats.remote['ann/mic-1'], isNotNull);
      expect(stats.remoteOf('ann'), hasLength(2));
    });
  });

  group('the connection', () {
    List<StatsReport> candidates({String localType = 'host'}) => [
      StatsReport('local-1', 'local-candidate', 0, {
        'candidateType': localType,
        'protocol': 'udp',
        'relayProtocol': ?(localType == 'relay' ? 'tls' : null),
        'networkType': 'wifi',
        'address': '192.0.2.1',
      }),
      StatsReport('remote-1', 'remote-candidate', 0, {
        'candidateType': 'host',
        'protocol': 'udp',
      }),
    ];

    StatsReport pair(String id, Map<String, Object?> values) =>
        StatsReport(id, 'candidate-pair', 0, {
          'localCandidateId': 'local-1',
          'remoteCandidateId': 'remote-1',
          ...values,
        });

    test('the transport\'s selected pair: RTT, bandwidth, candidates', () {
      final r = _Reader();
      final stats = r.reader.read([
        StatsReport('T01', 'transport', 0, {
          'selectedCandidatePairId': 'pair-2',
        }),
        pair('pair-1', {'currentRoundTripTime': 0.5, 'nominated': true}),
        pair('pair-2', {
          'currentRoundTripTime': 0.031,
          'availableOutgoingBitrate': 2500000.0,
          'bytesSent': 1000,
          'bytesReceived': 2000,
        }),
        ...candidates(),
      ]);
      final c = stats.connection!;
      expect(c.roundTripTime, const Duration(milliseconds: 31));
      expect(c.availableOutgoingBitrate, 2500000);
      expect(c.availableIncomingBitrate, isNull);
      expect(c.localCandidate!.type, IceCandidateType.host);
      expect(c.localCandidate!.networkType, 'wifi');
      expect(c.remoteCandidate!.protocol, 'udp');
      expect(c.isRelayed, isFalse);
      expect(c.bytesSent, 1000);
      expect(c.sendBitrate, isNull);
    });

    test('without a transport: the pair marked selected (Firefox), else the '
        'busiest nominated one; a relay is reported', () {
      final r = _Reader();
      var stats = r.reader.read([
        pair('p1', {'selected': false, 'currentRoundTripTime': 0.2}),
        pair('p2', {'selected': true, 'currentRoundTripTime': 0.05}),
        ...candidates(localType: 'relay'),
      ]);
      expect(stats.connection!.roundTripTime, const Duration(milliseconds: 50));
      expect(stats.connection!.isRelayed, isTrue);
      expect(stats.connection!.localCandidate!.relayProtocol, 'tls');

      stats = r.reader.read([
        pair('p1', {
          'nominated': true,
          'state': 'succeeded',
          'bytesSent': 10,
          'currentRoundTripTime': 0.2,
        }),
        pair('p2', {
          'nominated': true,
          'state': 'succeeded',
          'bytesSent': 99999,
          'currentRoundTripTime': 0.02,
        }),
        pair('p3', {
          'nominated': false,
          'state': 'succeeded',
          'bytesSent': 999999,
        }),
      ]);
      expect(stats.connection!.roundTripTime, const Duration(milliseconds: 20));
    });

    test('no pair yet: no connection', () {
      final r = _Reader();
      expect(r.reader.read(const []).connection, isNull);
    });

    test('send and receive rates on the pair', () {
      final r = _Reader();
      r.reader.read([
        StatsReport('T', 'transport', 0, {'selectedCandidatePairId': 'p'}),
        pair('p', {'bytesSent': 0, 'bytesReceived': 0}),
      ]);
      r.now = const Duration(seconds: 1);
      final stats = r.reader.read([
        StatsReport('T', 'transport', 0, {'selectedCandidatePairId': 'p'}),
        pair('p', {'bytesSent': 1000, 'bytesReceived': 500}),
      ]);
      expect(stats.connection!.sendBitrate, 8000);
      expect(stats.connection!.receiveBitrate, 4000);
    });
  });

  group('Firefox', () {
    // The fields Firefox 155 reports (M13): a transport with its selected
    // pair, outbound layers with rid and mid but no encodingIndex, active,
    // mediaSourceId or qualityLimitationReason, no availableOutgoingBitrate,
    // no decoderImplementation, no media-source audioLevel; timestamps in
    // milliseconds.
    List<StatsReport> publisher({required double ts, required int bytes}) => [
      for (final (rid, w, h, scale) in [
        ('c', 320, 180, 4),
        ('a', 1280, 720, 1),
        ('b', 640, 360, 2),
      ])
        StatsReport('out-$rid', 'outbound-rtp', ts, {
          'kind': 'video',
          'mediaType': 'video',
          'mid': '1',
          'rid': rid,
          'codecId': 'codec-vp8',
          'ssrc': 1000 + scale,
          'bytesSent': bytes ~/ scale,
          'packetsSent': 394,
          'frameWidth': w,
          'frameHeight': h,
          'framesEncoded': 156,
          'framesPerSecond': 29,
          'framesSent': 156,
          'remoteId': 'ri-$rid',
        }),
      StatsReport('ri-a', 'remote-inbound-rtp', ts, {
        'kind': 'video',
        'localId': 'out-a',
        'roundTripTime': 0.001999,
        'packetsLost': 0,
        'fractionLost': 0,
        'jitter': 0.00036666666666666667,
      }),
      StatsReport('out-mic', 'outbound-rtp', ts, {
        'kind': 'audio',
        'mid': '2',
        'codecId': 'codec-opus',
        'bytesSent': bytes ~/ 10,
        'remoteId': 'ri-mic',
      }),
      StatsReport('mediasource_audio_2{mic}', 'media-source', ts, {
        'kind': 'audio',
        'trackIdentifier': '{mic}',
      }),
      StatsReport('codec-vp8', 'codec', ts, {'mimeType': 'video/VP8'}),
      StatsReport('codec-opus', 'codec', ts, {'mimeType': 'audio/opus'}),
      StatsReport('cp-other', 'candidate-pair', ts, {
        'currentRoundTripTime': 0.14,
        'localCandidateId': 'lc',
        'remoteCandidateId': 'rc',
        'nominated': false,
        'selected': false,
        'state': 'in-progress',
      }),
      StatsReport('cp-sel', 'candidate-pair', ts, {
        'currentRoundTripTime': 0.002,
        'localCandidateId': 'lc-prflx',
        'remoteCandidateId': 'rc',
        'nominated': true,
        'selected': true,
        'state': 'succeeded',
      }),
      StatsReport('lc-prflx', 'local-candidate', ts, {
        'candidateType': 'prflx',
        'protocol': 'udp',
      }),
      StatsReport('rc', 'remote-candidate', ts, {
        'candidateType': 'host',
        'protocol': 'udp',
      }),
      StatsReport('tr', 'transport', ts, {
        'selectedCandidatePairId': 'cp-sel',
        'dtlsState': 'connected',
      }),
    ];

    test('a simulcast publisher: layers ordered by rid, missing fields '
        'null, rates over millisecond timestamps', () {
      var now = Duration.zero;
      final reader = CallStatsReader(
        elapsed: () => now,
        timestampsInMicroseconds: false,
      );
      const mic = (
        trackName: 'mic',
        kind: TrackKind.audio,
        source: TrackSource.microphone,
        mid: '2',
        trackId: '{mic}',
      );
      const cam = (
        trackName: 'camera-1',
        kind: TrackKind.video,
        source: TrackSource.camera,
        mid: '1',
        trackId: '{cam}',
      );
      reader.read(
        publisher(ts: 1790981737837, bytes: 352048),
        local: [cam, mic],
      );
      now = const Duration(milliseconds: 1000);
      final stats = reader.read(
        publisher(ts: 1790981738837, bytes: 423548),
        local: [cam, mic],
      );

      final camStats = stats.local['camera-1']!;
      expect([for (final l in camStats.layers) l.rid], ['a', 'b', 'c']);
      expect(camStats.codec, 'video/VP8');
      final a = camStats.layer('a')!;
      expect((a.width, a.height), (1280, 720));
      expect(camStats.layer('b')!.height, 360);
      expect(camStats.layer('c')!.height, 180);
      expect(a.framesPerSecond, 29);
      expect(a.bitrate, 572000);
      expect(a.roundTripTime, const Duration(microseconds: 1999));
      expect(a.active, isNull);
      expect(a.qualityLimitationReason, isNull);
      expect(a.targetBitrate, isNull);
      expect(a.encoderImplementation, isNull);

      final micStats = stats.local['mic']!;
      expect(micStats.codec, 'audio/opus');
      expect(micStats.audioLevel, isNull);
      expect(micStats.layers.single.rid, isNull);

      final c = stats.connection!;
      expect(c.roundTripTime, const Duration(milliseconds: 2));
      expect(c.availableOutgoingBitrate, isNull);
      expect(c.localCandidate!.type, IceCandidateType.prflx);
      expect(c.remoteCandidate!.type, IceCandidateType.host);
    });
  });
}
