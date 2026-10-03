// Typed stats and connection quality against a real broker (roadmap M12,
// part A; docs/design.md §7.1).
//
// Two rooms in one process, Alice and Bob, on an InMemorySignalingHub.
// Alice publishes her camera (three simulcast layers, h720) and her
// microphone; Bob pulls both. Then:
//
// 0. Both connections have a round-trip time and rate themselves good or
//    excellent (no capture needed), and Alice's camera captures frames
//    (else the test stops with a hint about permissions).
// 1. Alice's typed stats show layers a, b and c with sizes that halve from
//    layer to layer, bitrates and frame rates, and the VP8 codec; her
//    connection has a round-trip time.
// 2. Bob's typed stats show Alice's video arriving (frames, size,
//    bitrate) and her audio.
// 3. Both rate the connection good or excellent (a healthy LAN).
// 4. Alice's session is failed with reconnection off, so she stays in
//    signaling but her media stops: she is lost to herself at once, and
//    Bob rates her lost within ConnectionQualityOptions.lostAfter.
//
// Skipped unless CF_REALTIME_BROKER_URL is set; see broker_settings.dart.

import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

/// Long enough for the bandwidth estimate to enable the top layer.
const _layersTimeout = Duration(seconds: 60);
const _timeout = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  testWidgets(
    'typed stats are plausible, quality is good on a healthy network, and '
    'a participant whose media stops is lost',
    (tester) async {
      await _askForPermissions();
      final realtime = CloudflareRealtime(broker: settings.brokerOptions());
      final hub = InMemorySignalingHub();
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'stats-alice-$suffix',
        // Step 4 fails her session: she must stay on it, in signaling.
        options: const RoomOptions(reconnect: ReconnectOptions.disabled),
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'stats-bob-$suffix',
        options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
      );
      addTearDown(bob.leave);
      for (final room in [alice, bob]) {
        final sub = room.events.listen((e) {
          if (e is ParticipantConnectionQualityChangedEvent) {
            _log(
              '${room == alice ? 'Alice' : 'Bob'} sees '
              '${e.participant.participantId.split('-').take(2).join('-')} '
              '${e.quality.name}',
            );
          }
        });
        addTearDown(sub.cancel);
      }

      final cam = await alice.localParticipant.publishCamera();
      final mic = await alice.localParticipant.publishMicrophone();
      expect(cam.publication.sendEncodings, hasLength(3));

      // 0. The transport, which needs no capture: an RTT on both sides, and
      // their own connection rated good or better.
      for (final room in [alice, bob]) {
        final s = await _until(
          room,
          'An RTT on the connection',
          (s) => (s.connection?.roundTripTime ?? Duration.zero) > Duration.zero,
        );
        _log('connection: ${s.connection}');
      }
      const good = ConnectionQuality.good;
      await _quality(alice.localParticipant, 'Alice (local)', good);
      await _quality(bob.localParticipant, 'Bob (local)', good);

      // Capture works (else the rest can't): the camera's media-source
      // counts frames, in the raw reports.
      final camTrack = cam.publication.track?.id;
      await _until(
        alice,
        'The camera captures frames (no frames: check the Camera and '
        'Microphone permissions of the example app)',
        (s) => s.reports.any(
          (r) =>
              r.type == 'media-source' &&
              r.values['trackIdentifier'] == camTrack &&
              ((r.values['frames'] as num?) ?? 0) > 0,
        ),
        timeout: const Duration(seconds: 20),
      );

      // 1. The publisher's layers, and the microphone (published after the
      // camera, so its first report may come a read later: no rate yet).
      final sent = await _until(alice, 'Alice sends three layers', (s) {
        final c = s.local[cam.trackName];
        return c != null &&
            (s.local[mic.trackName]?.bitrate ?? 0) > 0 &&
            ['a', 'b', 'c'].every(
              (rid) =>
                  (c.layer(rid)?.bitrate ?? 0) > 0 &&
                  (c.layer(rid)?.height ?? 0) > 0,
            ) &&
            (s.connection?.roundTripTime ?? Duration.zero) > Duration.zero;
      }, timeout: _layersTimeout);
      final camStats = sent.local[cam.trackName]!;
      _log('Alice sends ${camStats.codec}: ${camStats.layers}');
      _log('Alice\'s connection: ${sent.connection}');
      expect(camStats.codec, 'video/VP8');
      final a = camStats.layer('a')!;
      final b = camStats.layer('b')!;
      final c = camStats.layer('c')!;
      // Each layer is half the one above (scaleResolutionDownBy 2 and 4),
      // give or take the encoder's rounding. A loaded machine may scale the
      // whole ladder down (qualityLimitationReason cpu), so the ratios are
      // checked rather than 720p.
      expect(a.height! >= 180, isTrue, reason: 'a: ${a.height}');
      expect(b.height, closeTo(a.height! / 2, 2));
      expect(c.height, closeTo(a.height! / 4, 2));
      expect(b.width, closeTo(a.width! / 2, 2));
      final reportsLimitation = sent.reports.any(
        (r) =>
            r.type == 'outbound-rtp' &&
            r.values['qualityLimitationReason'] != null,
      );
      if (!reportsLimitation) {
        _log('No qualityLimitationReason in the reports (as in Firefox)');
      }
      for (final layer in [a, b, c]) {
        expect(
          layer.bitrate,
          inInclusiveRange(10000, 5000000),
          reason: '$layer',
        );
        expect(layer.framesPerSecond, greaterThan(0), reason: '$layer');
        expect(layer.packetsSent, greaterThan(0));
        // Parsed wherever the platform reports it; Firefox doesn't, and
        // the typed value is then null (unknown), not "none".
        if (reportsLimitation) {
          expect(layer.qualityLimitationReason, isNotNull, reason: '$layer');
        }
      }
      expect(sent.connection!.roundTripTime, greaterThan(Duration.zero));
      expect(sent.connection!.localCandidate?.type, isNotNull);
      final micStats = sent.local[mic.trackName];
      expect(micStats?.codec, 'audio/opus');
      expect(micStats?.bitrate, greaterThan(0), reason: '$micStats');
      // The same through the publication.
      expect(cam.stats?.layers, hasLength(3));

      // 2. The subscriber.
      final aliceAtBob = bob.participant(alice.localParticipant.participantId)!;
      final camAtBob = aliceAtBob.camera!;
      final micAtBob = aliceAtBob.microphone!;
      final received = await _until(bob, 'Bob receives Alice', (s) {
        final v = s.remote[camAtBob.id];
        final m = s.remote[micAtBob.id];
        return (v?.bitrate ?? 0) > 0 &&
            (v?.framesPerSecond ?? 0) > 0 &&
            (v?.height ?? 0) > 0 &&
            (m?.bitrate ?? 0) > 0;
      });
      final video = received.remote[camAtBob.id]!;
      final audio = received.remote[micAtBob.id]!;
      _log('Bob receives $video and $audio');
      expect(video.codec, 'video/VP8');
      expect(video.framesDecoded, greaterThan(0));
      expect(video.packetsReceived, greaterThan(0));
      expect(video.rid, isNotNull, reason: 'a simulcast pull');
      expect(audio.codec, 'audio/opus');
      expect(audio.jitter, isNotNull);
      expect(received.connection!.roundTripTime, greaterThan(Duration.zero));

      // 3. Quality on a healthy network, now with media both ways.
      await _quality(alice.localParticipant, 'Alice (local)', good);
      await _quality(aliceAtBob, 'Alice at Bob', good);

      // 4. Alice's media stops while she stays in signaling.
      final failedAt = DateTime.now();
      alice.debugSimulateConnectionFailure();
      await _quality(
        alice.localParticipant,
        'Alice (local) after the failure',
        ConnectionQuality.lost,
        exactly: true,
        timeout: const Duration(seconds: 5),
      );
      await _quality(
        aliceAtBob,
        'Alice at Bob after the failure',
        ConnectionQuality.lost,
        exactly: true,
      );
      _log(
        'Bob saw Alice lost after '
        '${DateTime.now().difference(failedAt).inMilliseconds} ms',
      );
      expect(aliceAtBob.isPresent, isTrue, reason: 'still in signaling');
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}

void _log(String message) => debugPrint('[stats] $message');

Future<void> _askForPermissions() async {
  for (final source in [CameraSource(), MicrophoneSource()]) {
    try {
      await source.enable();
    } on MediaException {
      // Reported by the publish.
    } finally {
      await source.dispose();
    }
  }
}

/// Waits for a [Room.statsChanges] snapshot that passes [test].
Future<RoomStats> _until(
  Room room,
  String what,
  bool Function(RoomStats stats) test, {
  Duration timeout = _timeout,
}) async {
  RoomStats? last;
  try {
    return await room.statsChanges
        .firstWhere((stats) {
          last = stats;
          return test(stats);
        })
        .timeout(timeout);
  } on TimeoutException {
    fail('$what: not within ${timeout.inSeconds} s. Last snapshot: $last');
  }
}

/// Waits until [participant]'s quality is at least [quality] (or exactly
/// it).
Future<void> _quality(
  Participant participant,
  String who,
  ConnectionQuality quality, {
  bool exactly = false,
  Duration timeout = _timeout,
}) async {
  try {
    final reached = await participant.connectionQualityChanges
        .firstWhere((q) => exactly ? q == quality : q.isAtLeast(quality))
        .timeout(timeout);
    _log('$who: ${reached.name}');
  } on TimeoutException {
    fail(
      '$who: not ${quality.name} within ${timeout.inSeconds} s '
      '(${participant.connectionQuality.name})',
    );
  }
}
