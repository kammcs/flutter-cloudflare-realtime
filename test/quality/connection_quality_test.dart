import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/connection_quality.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = ConnectionQualityOptions();
const _poll = Duration(seconds: 2);

ConnectionQuality? _rate(QualitySample sample) => rateQuality(sample, _config);

RemoteTrackStats _remote(
  String name, {
  TrackKind kind = TrackKind.audio,
  int? bitrate = 40000,
  int? received,
  int? lost,
  Duration? jitter,
  Duration? frozen,
}) => RemoteTrackStats(
  publicationId: 'ann/$name',
  participantId: 'ann',
  trackName: name,
  kind: kind,
  source: kind == TrackKind.audio ? TrackSource.microphone : TrackSource.camera,
  bitrate: bitrate,
  packetsReceived: received,
  packetsLost: lost,
  jitter: jitter,
  totalFreezesDuration: frozen,
);

void main() {
  group('rateQuality', () {
    test('nothing measured: no rating', () {
      expect(_rate(const QualitySample()), isNull);
    });

    test('the worst metric decides', () {
      expect(
        _rate(
          const QualitySample(
            roundTripTime: Duration(milliseconds: 40),
            packetLoss: 0,
            jitter: Duration(milliseconds: 5),
          ),
        ),
        ConnectionQuality.excellent,
      );
      // Each metric just over excellent's limit: good.
      for (final sample in const [
        QualitySample(roundTripTime: Duration(milliseconds: 151)),
        QualitySample(packetLoss: 0.011),
        QualitySample(jitter: Duration(milliseconds: 21)),
        QualitySample(freezeRatio: 0.01),
        QualitySample(
          roundTripTime: Duration(milliseconds: 20),
          bandwidthLimited: true,
        ),
      ]) {
        expect(_rate(sample), ConnectionQuality.good, reason: '$sample');
      }
      // Each metric over good's limit: poor.
      for (final sample in const [
        QualitySample(roundTripTime: Duration(milliseconds: 301)),
        QualitySample(
          packetLoss: 0.06,
          roundTripTime: Duration(milliseconds: 5),
        ),
        QualitySample(jitter: Duration(milliseconds: 51)),
        QualitySample(freezeRatio: 0.2),
        QualitySample(starved: true),
      ]) {
        expect(_rate(sample), ConnectionQuality.poor, reason: '$sample');
      }
    });
  });

  group('QualityTracker', () {
    test('the first rating applies at once; no rating keeps the level', () {
      final t = QualityTracker(_config);
      expect(t.current, ConnectionQuality.unknown);
      expect(t.add(null, _poll), ConnectionQuality.unknown);
      expect(t.add(ConnectionQuality.good, _poll), ConnectionQuality.good);
      expect(t.add(null, _poll), ConnectionQuality.good);
    });

    test('degrades after 4 s below, improves after 6 s above', () {
      final t = QualityTracker(_config)..set(ConnectionQuality.excellent);
      expect(t.add(ConnectionQuality.poor, _poll), ConnectionQuality.excellent);
      expect(t.add(ConnectionQuality.poor, _poll), ConnectionQuality.poor);
      expect(t.add(ConnectionQuality.excellent, _poll), ConnectionQuality.poor);
      expect(t.add(ConnectionQuality.excellent, _poll), ConnectionQuality.poor);
      expect(
        t.add(ConnectionQuality.excellent, _poll),
        ConnectionQuality.excellent,
      );
    });

    test('a link that alternates doesn\'t flap', () {
      final t = QualityTracker(_config)..set(ConnectionQuality.good);
      for (var i = 0; i < 20; i++) {
        final rating = i.isEven
            ? ConnectionQuality.poor
            : ConnectionQuality.good;
        expect(t.add(rating, _poll), ConnectionQuality.good, reason: '$i');
      }
      for (var i = 0; i < 20; i++) {
        final rating = i.isEven
            ? ConnectionQuality.excellent
            : ConnectionQuality.good;
        expect(t.add(rating, _poll), ConnectionQuality.good, reason: '$i');
      }
    });

    test('drops to the closest level among the lower ratings', () {
      final t = QualityTracker(_config)..set(ConnectionQuality.excellent);
      t.add(ConnectionQuality.poor, _poll);
      expect(t.add(ConnectionQuality.good, _poll), ConnectionQuality.good);
      // And rises to the lowest of the higher ones.
      t.set(ConnectionQuality.poor);
      t.add(ConnectionQuality.excellent, _poll);
      t.add(ConnectionQuality.good, _poll);
      expect(t.add(ConnectionQuality.excellent, _poll), ConnectionQuality.good);
    });

    test('lost applies at once, and so does the first rating after it', () {
      final t = QualityTracker(_config)..set(ConnectionQuality.excellent);
      expect(t.add(ConnectionQuality.lost, _poll), ConnectionQuality.lost);
      expect(t.add(ConnectionQuality.good, _poll), ConnectionQuality.good);
    });

    test('the window lengths count, not the number of polls', () {
      final t = QualityTracker(_config)..set(ConnectionQuality.excellent);
      expect(
        t.add(ConnectionQuality.poor, const Duration(seconds: 1)),
        ConnectionQuality.excellent,
      );
      expect(
        t.add(ConnectionQuality.poor, const Duration(seconds: 3)),
        ConnectionQuality.poor,
      );
    });
  });

  group('localQualitySample', () {
    RoomStats stats({
      Duration? pairRtt,
      int? available,
      List<LocalTrackStats> local = const [],
    }) => RoomStats(
      timestamp: DateTime(2026),
      connection: ConnectionStats(
        roundTripTime: pairRtt,
        availableOutgoingBitrate: available,
      ),
      local: {for (final t in local) t.trackName: t},
    );

    LocalTrackStats video(List<OutboundLayerStats> layers) => LocalTrackStats(
      trackName: 'cam',
      kind: TrackKind.video,
      source: TrackSource.camera,
      layers: layers,
    );

    test('RTT from the pair, else the receiver reports', () {
      expect(
        localQualitySample(
          stats(pairRtt: const Duration(milliseconds: 30)),
          _config,
        ).roundTripTime,
        const Duration(milliseconds: 30),
      );
      expect(
        localQualitySample(
          stats(
            local: [
              video(const [
                OutboundLayerStats(
                  rid: 'a',
                  roundTripTime: Duration(milliseconds: 70),
                ),
              ]),
            ],
          ),
          _config,
        ).roundTripTime,
        const Duration(milliseconds: 70),
      );
    });

    test('loss weighted by bitrate over the layers that send; audio jitter; '
        'bandwidth limits', () {
      final sample = localQualitySample(
        stats(
          pairRtt: const Duration(milliseconds: 20),
          available: 2000000,
          local: [
            video(const [
              OutboundLayerStats(
                rid: 'a',
                bitrate: 900000,
                fractionLost: 0.0,
                qualityLimitationReason: QualityLimitationReason.bandwidth,
                jitter: Duration(milliseconds: 90),
              ),
              OutboundLayerStats(rid: 'b', bitrate: 100000, fractionLost: 0.1),
              // Not sending: ignored.
              OutboundLayerStats(rid: 'c', bitrate: 0, fractionLost: 1),
            ]),
            const LocalTrackStats(
              trackName: 'mic',
              kind: TrackKind.audio,
              source: TrackSource.microphone,
              layers: [
                OutboundLayerStats(
                  bitrate: 40000,
                  jitter: Duration(milliseconds: 8),
                ),
              ],
            ),
          ],
        ),
        _config,
      );
      expect(sample.packetLoss, closeTo(0.1 * 100 / 1000, 1e-9));
      expect(sample.jitter, const Duration(milliseconds: 8));
      expect(sample.bandwidthLimited, isTrue);
      expect(sample.starved, isFalse);
      expect(rateQuality(sample, _config), ConnectionQuality.good);
    });

    test('video with too little outgoing bandwidth is starved', () {
      final sample = localQualitySample(
        stats(
          available: 100000,
          local: [
            video(const [OutboundLayerStats(rid: 'c', bitrate: 90000)]),
          ],
        ),
        _config,
      );
      expect(sample.starved, isTrue);
      expect(rateQuality(sample, _config), ConnectionQuality.poor);
    });
  });

  group('remoteQualitySample', () {
    test('loss over all packets, audio jitter, video freezes', () {
      final before = {
        'ann/mic': _remote('mic', received: 1000, lost: 0),
        'ann/cam': _remote(
          'cam',
          kind: TrackKind.video,
          received: 5000,
          lost: 10,
          frozen: Duration.zero,
        ),
      };
      final sample = remoteQualitySample(
        [
          _remote(
            'mic',
            received: 1100,
            lost: 0,
            jitter: const Duration(milliseconds: 15),
          ),
          _remote(
            'cam',
            kind: TrackKind.video,
            bitrate: 500000,
            received: 5880,
            lost: 30,
            // Video jitter is left out.
            jitter: const Duration(milliseconds: 200),
            frozen: const Duration(milliseconds: 500),
          ),
        ],
        before,
        _poll,
      );
      expect(sample.packetLoss, closeTo(20 / 1000, 1e-9));
      expect(sample.jitter, const Duration(milliseconds: 15));
      expect(sample.freezeRatio, closeTo(0.25, 1e-9));
      expect(rateQuality(sample, _config), ConnectionQuality.poor);
    });

    test('no previous snapshot: no loss, but jitter counts', () {
      final sample = remoteQualitySample(
        [_remote('mic', received: 10, jitter: const Duration(milliseconds: 3))],
        const {},
        null,
      );
      expect(sample.packetLoss, isNull);
      expect(sample.jitter, const Duration(milliseconds: 3));
      expect(rateQuality(sample, _config), ConnectionQuality.excellent);
    });
  });
}
