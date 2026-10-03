// A call between two devices through the same SFU: run this test on two
// devices at the same time (say Windows and an Android phone), in the same
// room, against the DEV ONLY dev server (tools/dev-server), whose
// WebSocket signaling introduces them.
//
// Each side joins the room as a Room, publishes its camera (or, without
// one, its microphone) and pulls the other's. It checks that media
// arrives: the inbound bytes and decoded frames (or audio samples) in
// getStats() keep rising. If the other side's camera is simulcast (the
// Room's default), it asks for the low layer, then the high one, then the
// low one again, and checks that the received frame height follows.
// Then each side says it is done (in its signaling metadata) and waits for
// the other before leaving, so neither cuts the other's media short.
//
// With CF_REALTIME_CROSS_DEVICE_SCREEN=true, a phone shares its screen
// instead of its camera (answer Android's consent dialog, or tap "Start
// Broadcast" in iOS's picker within 2 minutes; it publishes its microphone
// first, so its session stays connected meanwhile), so the other side
// checks a phone's screen share arriving. Each side pulls the
// other's screen, else camera, else microphone.
//
// Skipped unless CF_REALTIME_BROKER_URL, CF_REALTIME_BROKER_TOKEN,
// CF_REALTIME_BROKER_USER and CF_REALTIME_CROSS_DEVICE=1 are set; see
// broker_settings.dart and docs/checkpoint.md §7. Give both devices the
// same CF_REALTIME_ROOM (fresh for each run) and different users. The test
// never prints the settings.

import 'dart:async';
import 'dart:math';

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

/// How long to wait for the other device to join: it may still be
/// building.
const _peerTimeout = Duration(minutes: 5);

/// How long one media check may take.
const _timeout = Duration(seconds: 30);

/// Whether a phone shares its screen instead of its camera.
const _shareScreen = bool.fromEnvironment('CF_REALTIME_CROSS_DEVICE_SCREEN');

/// The metadata key each side sets to `done` when it has finished.
const _phaseKey = 'crossDevicePhase';

/// The metadata key for the frame height of each video layer a side sends.
const _heightsKey = 'crossDeviceLayerHeights';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  testWidgets(
    'two devices exchange media through the SFU and switch layers',
    (tester) async {
      final dev = settings.devServer();
      final realtime = CloudflareRealtime(broker: dev.brokerOptions());
      final signaling = dev.createSignaling();
      final random = Random.secure();
      // Not 1 << 32: shifts are 32-bit on the web, which makes that 0.
      final self = '${dev.userName}:${random.nextInt(0x7fffffff)}';
      final room = await realtime.join(
        settings.room,
        signaling: signaling,
        participantId: self,
        metadata: const {_phaseKey: 'running'},
        options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
      );
      var left = false;
      Future<void> leave() async {
        if (left) return;
        left = true;
        await room.leave();
        await signaling.dispose();
      }

      addTearDown(leave);
      _log('joined as $self');

      // Camera with the default simulcast layers, else the microphone; or
      // the screen, on a phone when asked.
      LocalMediaPublication published;
      final screen =
          _shareScreen &&
          !kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS);
      try {
        if (screen) {
          // The microphone first, so the session is connected while the
          // consent dialog waits: the SFU drops a session whose
          // PeerConnection never connected (410 on the first push).
          await room.localParticipant.publishMicrophone();
          if (defaultTargetPlatform == TargetPlatform.iOS) {
            _log('TAP "Start Broadcast" on the iPhone (within 2 minutes)');
          }
        }
        published = screen
            ? await room.localParticipant.publishScreen(
                // iOS waits this long for "Start Broadcast".
                options: const ScreenShareOptions(
                  broadcastStartTimeout: Duration(minutes: 2),
                ),
              )
            : await room.localParticipant.publishCamera();
      } on MediaException catch (e) {
        _log('no camera ($e), publishing the microphone');
        published = await room.localParticipant.publishMicrophone();
      }
      await published.publication.whenSending().timeout(_timeout);
      // Tell the other side the frame height of each layer we send, so it
      // knows which height the low layer has.
      final heights = published.publication.kind == 'video'
          ? await _sentHeights(
              room.session,
              published.publication.sendEncodings.length,
            )
          : const <String, num>{};
      await room.localParticipant.setMetadata({
        _phaseKey: 'running',
        _heightsKey: heights,
      });
      _log('sending ${published.source.name}, layers $heights');

      // The other device, with a camera or microphone.
      final peer = await room.participantsChanges
          .map((list) => list.where((p) => _mediaOf(p) != null))
          .firstWhere((peers) => peers.isNotEmpty)
          .timeout(_peerTimeout)
          .then((peers) => peers.first);
      final peerHeights = await peer.changes
          .startWith(peer)
          .map((p) => p.metadata?[_heightsKey])
          .firstWhere((h) => h is Map)
          .timeout(_peerTimeout)
          .then((h) => [for (final v in (h as Map).values) v as num]);
      // After the heights: the peer announces them once its main track is
      // published (a screen may follow a microphone).
      final remote = _mediaOf(peer)!;
      _log(
        'peer ${peer.participantId}: ${remote.source.name}, '
        'simulcast ${remote.simulcast != null}, layer heights $peerHeights',
      );

      final track = await remote.trackChanges
          .startWith(remote.track)
          .firstWhere(
            (t) =>
                t != null && remote.subscriptionState == SfuTrackState.active,
          )
          .timeout(_timeout);
      final mid = remote.subscription!.mid;
      final trackId = track!.track.id;
      final isVideo = remote.kind == TrackKind.video;

      Future<_Inbound?> inbound() async =>
          _inbound(await room.session.getStats(), mid: mid, trackId: trackId);

      // Media arrives, and keeps arriving.
      final first = await _poll(
        inbound,
        (s) => s.bytes > 0 && s.units > 0,
        'media from the peer',
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      final later = (await inbound())!;
      _log('inbound: $first, then $later');
      expect(later.bytes, greaterThan(first.bytes), reason: 'bytes rise');
      expect(
        later.units,
        greaterThan(first.units),
        reason: isVideo ? 'decoded frames rise' : 'audio samples rise',
      );

      // Simulcast layer switching: low, high, low, checked against the
      // height of the peer's lowest layer. The SFU switches at a keyframe
      // of the new layer: 1 to 13 s in the first runs (see the
      // checkpoint's notes), so each wait allows [_timeout].
      if (isVideo &&
          (remote.simulcast?.rids.length ?? 0) > 1 &&
          peerHeights.isNotEmpty) {
        final lowest = peerHeights.reduce(min);
        Future<num> switchTo(
          SimulcastLayer layer,
          bool Function(num) ok,
        ) async {
          final asked = DateTime.now();
          await remote.setPreferredLayer(layer);
          final height = (await _poll(
            inbound,
            (s) => s.height > 0 && ok(s.height),
            'the frame height after asking for ${layer.name} '
            '(${_layers(remote)})',
          )).height;
          final ms = DateTime.now().difference(asked).inMilliseconds;
          _log(
            '${layer.name}: ${height}p after $ms ms; our sender: '
            '${_keyframes(await room.session.getStats())}',
          );
          return height;
        }

        _log(
          'receiving ${later.height}p (${_layers(remote)}); our sender: '
          '${_keyframes(await room.session.getStats())}',
        );
        final low = await switchTo(SimulcastLayer.low, (h) => h <= lowest);
        final high = await switchTo(SimulcastLayer.high, (h) => h > lowest);
        final back = await switchTo(SimulcastLayer.low, (h) => h <= lowest);
        expect(high, greaterThan(low));
        expect(back, lessThan(high));
      } else {
        _log('no simulcast video from the peer: layer switching not checked');
      }

      expect(room.session.failure, isNull);

      // Done: wait for the other device to finish too, or to leave (which
      // closes its `changes` stream without an event).
      await room.localParticipant.setMetadata({
        _phaseKey: 'done',
        _heightsKey: heights,
      });
      await peer.changes
          .startWith(peer)
          .firstWhere(
            (p) => !p.isPresent || p.metadata?[_phaseKey] == 'done',
            orElse: () => peer,
          )
          .timeout(_peerTimeout);
      _log('the peer is done');
      await leave();
    },
    skip: settings.skipCrossDevice,
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

void _log(String message) => debugPrint('[cross-device] $message');

/// The rids asked for, for the log.
String _layers(RemoteTrackPublication p) {
  final s = p.layerState;
  return 'rid ${s.currentRid}, target ${s.targetRid}, '
      'auto ${s.automaticRid}, preferred ${s.preferredLayer?.name}, '
      'pull ${p.subscription?.preferredRid}';
}

/// The participant's screen, else its camera, else its microphone.
RemoteTrackPublication? _mediaOf(RemoteParticipant p) =>
    p.screen ?? p.camera ?? p.microphone;

/// One `inbound-rtp` report, reduced to what the test checks.
class _Inbound {
  _Inbound(this.bytes, this.units, this.height);

  final num bytes;

  /// Decoded frames (video) or received samples (audio).
  final num units;

  /// The frame height (video), or 0.
  final num height;

  @override
  String toString() => '$bytes bytes, $units units, ${height}p';
}

/// The `inbound-rtp` report for the pull with [mid] or [trackId], if any.
_Inbound? _inbound(
  List<StatsReport> reports, {
  required String? mid,
  required String? trackId,
}) {
  for (final report in reports) {
    if (report.type != 'inbound-rtp') continue;
    final v = report.values;
    final matches =
        (mid != null && '${v['mid']}' == mid) ||
        (trackId != null && '${v['trackIdentifier']}' == trackId);
    if (!matches) continue;
    return _Inbound(
      _num(v['bytesReceived']),
      v['kind'] == 'audio'
          ? _num(v['totalSamplesReceived'])
          : _num(v['framesDecoded']),
      _num(v['frameHeight']),
    );
  }
  return null;
}

/// Keyframes encoded and keyframe requests (PLI, FIR) received, per
/// outbound video layer, for the log.
String _keyframes(List<StatsReport> reports) => [
  for (final r in reports)
    if (r.type == 'outbound-rtp' && r.values['kind'] == 'video')
      '${r.values['rid'] ?? '-'}: '
          'kf ${r.values['keyFramesEncoded']}, '
          'pli ${r.values['pliCount']}, fir ${r.values['firCount']}, '
          '${r.values['frameHeight']}p',
].join('; ');

/// The frame height of each video layer [session] sends (by rid, or `-`
/// without simulcast), once all [layers] report one or after 10 s. The
/// encoder starts with the lowest layer and adds the others as its
/// bandwidth estimate grows, so the lowest is there either way. Empty for
/// audio.
Future<Map<String, num>> _sentHeights(SfuSession session, int layers) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  var heights = <String, num>{};
  while (DateTime.now().isBefore(deadline)) {
    heights = {
      for (final r in await session.getStats())
        if (r.type == 'outbound-rtp' &&
            r.values['kind'] == 'video' &&
            _num(r.values['frameHeight']) > 0)
          '${r.values['rid'] ?? '-'}': _num(r.values['frameHeight']),
    };
    if (heights.isNotEmpty && heights.length >= layers) break;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  return heights;
}

num _num(Object? value) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

/// Polls [read] every 500 ms until it returns a value that satisfies
/// [done], for at most [_timeout].
Future<_Inbound> _poll(
  Future<_Inbound?> Function() read,
  bool Function(_Inbound) done,
  String what,
) async {
  final deadline = DateTime.now().add(_timeout);
  _Inbound? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await read();
    if (last != null && done(last)) return last;
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('Timed out waiting for $what (last: $last)');
}

extension<T> on Stream<T> {
  /// This stream, preceded by [value].
  Stream<T> startWith(T value) async* {
    yield value;
    yield* this;
  }
}
