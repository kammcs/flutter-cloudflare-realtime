// Publisher-side call quality (M12, docs/design.md §6.2, §6.3), through a
// real broker and SFU. Two rooms in one process share in-memory signaling:
// Alice publishes her camera, Bob pulls it.
//
// (a) Layer pausing (turned on for Alice): Bob pulls only the low layer, so
//     Alice stops encoding a and b (outbound-rtp `active: false`,
//     framesEncoded flat). Bob then switches up to the high layer: Alice
//     resumes at once and Bob keeps decoding; whether the SFU moves him up
//     is logged. Then Bob pulls the paused high layer afresh: it resumes,
//     and Bob decodes it within [_newPullTimeout]. Windows can't pause: the
//     room reports a RoomErrorEvent and the rest runs as the baseline.
// (b) Announcement: the announced simulcast size is the captured size (the
//     sender's media-source, or on Windows, where it has no size, layer a's
//     encoded size), portrait on a phone held upright.
// (c) Codec: with RoomOptions.videoCodec H.264, Bob decodes H.264 (the
//     codec in Bob's stats), and the encoder in use is logged (hardware or
//     not). Windows never sends H.264: it sends VP8 and reports a
//     RoomErrorEvent.
//
// Skipped unless CF_REALTIME_BROKER_URL is set; see broker_settings.dart
// for the settings (including the dev server's X-Dev-User) and a command
// line. The test never prints them.

import 'dart:math' as math;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show StatsReport, getRtpSenderCapabilities;
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

const _timeout = Duration(seconds: 30);

/// How long to watch Bob switch up with `tracks/update`. The SFU switches at
/// its own pace: about 6 s (sometimes 12 s, sometimes never) in the M12
/// runs on a Pixel, even with every layer on.
const _switchTimeout = Duration(seconds: 20);

/// How long a new pull of a resumed layer may take to decode it: 1.2 to
/// 1.7 s in the M12 runs.
const _newPullTimeout = Duration(seconds: 10);

const _pauseDelay = Duration(seconds: 3);

/// `--dart-define=CF_QUALITY_PAUSING=false` runs (a) without pausing, as a
/// baseline for the switch-up time.
const _pausing = bool.fromEnvironment('CF_QUALITY_PAUSING', defaultValue: true);

/// Windows neither pauses layers nor sends H.264 (docs/design.md §6, §6.2).
final bool _windows =
    !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  Future<(Room, Room)> joinBoth(RoomOptions aliceOptions) async {
    // Ask for the camera before joining (a first-run prompt can outlast the
    // SFU's patience with an unconnected session).
    final permission = CameraSource();
    await permission.enable();
    await permission.dispose();

    final realtime = CloudflareRealtime(broker: settings.brokerOptions());
    final hub = InMemorySignalingHub();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final alice = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: 'quality-alice-$suffix',
      options: aliceOptions,
    );
    addTearDown(alice.leave);
    final bob = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: 'quality-bob-$suffix',
    );
    addTearDown(bob.leave);
    return (alice, bob);
  }

  testWidgets(
    'pauses unpulled layers, resumes them, and announces the captured size',
    (tester) async {
      final (alice, bob) = await joinBoth(
        const RoomOptions(
          layerPausing: LayerPausingOptions(
            enabled: _pausing,
            pauseDelay: _pauseDelay,
          ),
        ),
      );
      final errors = <RoomErrorEvent>[];
      final events = alice.events.listen((e) {
        if (e is RoomErrorEvent) errors.add(e);
      });
      addTearDown(events.cancel);
      final published = await alice.localParticipant.publishCamera();
      // Windows can't pause (flutter_webrtc ignores encoding changes there):
      // the room says so, and the rest runs as the baseline.
      final pausing = _pausing && !_windows;
      if (_pausing && _windows) {
        expect(errors.map((e) => e.operation), contains('layerPausing'));
        _log('Windows: no layer pausing (${errors.first.error})');
      }
      await published.publication.whenSending().timeout(_timeout);
      final cam = await _remoteCamera(bob, alice);

      // (b) The announced size is what the camera captures.
      final source = await _poll(
        () async => _mediaSource(await alice.session.getStats()),
        (s) => s.$1 > 0,
        'the camera\'s media-source size',
      );
      final announced = await _poll(
        () async => published.simulcast,
        (s) => s!.width == source.$1 && s.height == source.$2,
        'the announced size to match ${source.$1}x${source.$2} '
        '(announced ${published.simulcast})',
      );
      _log(
        'captured ${source.$1}x${source.$2} (${source.$3}), announced '
        '${announced!.width}x${announced.height} '
        '(the camera reported ${published.mediaSource.track?.track.getSettings()['width']}x'
        '${published.mediaSource.track?.track.getSettings()['height']})',
      );
      await _poll(
        () async => cam.simulcast,
        (s) => s == announced,
        'Bob to see the announced size',
      );

      // (a) Bob pulls only the low layer.
      await cam.setPreferredLayer(SimulcastLayer.low);
      await cam.subscribe();
      await _poll(
        () async => _inbound(await bob.session.getStats(), cam),
        (s) => s.framesDecoded > 0,
        'Bob decoding the low layer',
      );
      if (pausing) {
        final watch = Stopwatch()..start();
        await _poll(
          () async => published.pausedLayers,
          (p) => setEquals(p, {'a', 'b'}),
          'Alice pausing a and b',
        );
        _log('a and b paused after ${watch.elapsedMilliseconds} ms');
        final before = _outbound(await alice.session.getStats());
        await Future<void>.delayed(const Duration(seconds: 2));
        final after = _outbound(await alice.session.getStats());
        _log('paused: $after');
        for (final rid in ['a', 'b']) {
          final layer = after[rid]!;
          expect(
            layer.active == false ||
                layer.framesEncoded == before[rid]!.framesEncoded,
            isTrue,
            reason: '$rid should be paused: $layer',
          );
        }
        expect(
          after['c']!.framesEncoded,
          greaterThan(before['c']!.framesEncoded),
          reason: 'c keeps sending',
        );
      } else {
        // The same time on c, every layer on: the baseline to compare with.
        await Future<void>.delayed(_pauseDelay + const Duration(seconds: 2));
      }

      // Bob decodes something bigger than Alice's b layer: her a layer.
      Future<_Video?> high() async {
        final inbound = _inbound(await bob.session.getStats(), cam);
        final b = _outbound(await alice.session.getStats())['b'];
        if (b == null || b.longSide == 0) return null;
        return inbound.longSide > b.longSide ? inbound : null;
      }

      // Bob switches up (tracks/update): Alice resumes at once, and Bob
      // keeps decoding. Whether the SFU moves him up to a is logged, not
      // asserted: in the M12 runs it often kept him on b (docs/design.md
      // §6.2), which is why pausing is off by default.
      var asked = Stopwatch()..start();
      await cam.setPreferredLayer(SimulcastLayer.high);
      await _poll(
        () async => published.pausedLayers,
        (p) => p.isEmpty,
        'Alice resuming',
      );
      final resumedMs = asked.elapsedMilliseconds;
      final decoded = _inbound(await bob.session.getStats(), cam).framesDecoded;
      _Video? switched;
      while (asked.elapsed < _switchTimeout && switched == null) {
        switched = await high();
        if (switched == null) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
      final now = _inbound(await bob.session.getStats(), cam);
      _log(
        'switch up: resumed after $resumedMs ms; Bob '
        '${switched == null ? 'still on ${now.width}x${now.height} after ${asked.elapsedMilliseconds} ms' : 'decodes ${switched.width}x${switched.height} after ${asked.elapsedMilliseconds} ms'}; '
        '${_keyframes(await alice.session.getStats())}',
      );
      expect(now.framesDecoded, greaterThan(decoded), reason: 'no freeze');

      // A new pull of a paused layer: Bob goes back to low (Alice pauses
      // again), then pulls afresh at high. The layer resumes and Bob decodes
      // it within [_newPullTimeout].
      await cam.setPreferredLayer(SimulcastLayer.low);
      if (pausing) {
        await _poll(
          () async => published.pausedLayers,
          (p) => setEquals(p, {'a', 'b'}),
          'Alice pausing a and b again',
        );
      }
      await cam.unsubscribe();
      await _poll(
        () async => cam.subscription,
        (s) => s == null,
        'Bob\'s pull to close',
      );
      asked = Stopwatch()..start();
      await cam.setPreferredLayer(SimulcastLayer.high);
      await cam.subscribe();
      final fresh = await _poll(
        high,
        (s) => s != null,
        'Bob decoding the resumed a layer on a new pull',
        timeout: _newPullTimeout,
        every: const Duration(milliseconds: 100),
      );
      _log(
        'new pull at a: Bob decodes ${fresh!.width}x${fresh.height} after '
        '${asked.elapsedMilliseconds} ms',
      );
      expect(alice.session.failure, isNull);
      expect(bob.session.failure, isNull);
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  for (final videoCodec in _codecs) {
    testWidgets(
      'sends ${videoCodec.name} when the room asks for it',
      (tester) => _codecTest(joinBoth, videoCodec),
      skip: settings.skip,
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}

/// The codecs (c): `CF_QUALITY_CODECS`, comma-separated names of
/// [VideoCodec] (default `h264`).
final List<VideoCodec> _codecs = [
  for (final name in const String.fromEnvironment(
    'CF_QUALITY_CODECS',
    defaultValue: 'h264',
  ).split(','))
    VideoCodec.values.byName(name.trim()),
];

Future<void> _codecTest(
  Future<(Room, Room)> Function(RoomOptions) joinBoth,
  VideoCodec videoCodec,
) async {
  final capabilities = await getRtpSenderCapabilities('video');
  final encoders = {
    for (final c in capabilities.codecs ?? const []) c.mimeType,
  };
  _log('video encoders: $encoders');
  final (alice, bob) = await joinBoth(RoomOptions(videoCodec: videoCodec));
  final errors = <RoomErrorEvent>[];
  final events = alice.events.listen((e) {
    if (e is RoomErrorEvent) errors.add(e);
  });
  addTearDown(events.cancel);
  final published = await alice.localParticipant.publishCamera();
  // Windows never sends H.264 (flutter-webrtc #982): VP8 instead, reported
  // as a RoomErrorEvent (docs/design.md §6, Codec).
  final noH264 = videoCodec == VideoCodec.h264 && _windows;
  if (noH264) {
    expect(published.videoCodec, VideoCodec.vp8);
    expect(errors.map((e) => e.operation), contains('videoCodec'));
    _log('Windows: asked for H.264, sends VP8 (${errors.first.error})');
  } else {
    expect(published.videoCodec, videoCodec);
  }
  await published.publication.whenSending().timeout(_timeout);
  final cam = await _remoteCamera(bob, alice);
  await cam.setPreferredLayer(SimulcastLayer.high);
  await cam.subscribe();

  final first = await _poll(
    () async => _inbound(await bob.session.getStats(), cam),
    (s) => s.framesDecoded > 0,
    'Bob decoding',
  );
  await Future<void>.delayed(const Duration(seconds: 3));
  final reports = await bob.session.getStats();
  final later = _inbound(reports, cam);
  expect(later.framesDecoded, greaterThan(first.framesDecoded));
  final codec = _codecOf(reports, later.codecId);
  final sent = await alice.session.getStats();
  _log(
    'Bob decodes $codec with ${later.decoder} at '
    '${later.width}x${later.height}; Alice encodes with '
    '${_outbound(sent).values.map((o) => '${o.rid}: ${o.encoder} '
        '${o.width}x${o.height} ${o.framesEncoded} frames').join('; ')}',
  );
  // A platform without the encoder falls back to VP8.
  final expected =
      !noH264 &&
          encoders.any(
            (m) => m.toLowerCase() == videoCodec.mimeType.toLowerCase(),
          )
      ? videoCodec.mimeType
      : 'video/VP8';
  expect(codec?.toLowerCase(), expected.toLowerCase());
}

void _log(String message) => debugPrint('[publish-quality] $message');

/// Alice's camera as Bob sees it.
Future<RemoteTrackPublication> _remoteCamera(Room bob, Room alice) => _poll(
  () async {
    for (final p in bob.participants) {
      if (p.sessionId == alice.session.sessionId && p.camera != null) {
        return p.camera;
      }
    }
    return null;
  },
  (c) => c != null,
  'Bob to see Alice\'s camera',
).then((c) => c!);

class _Video {
  _Video({
    this.rid,
    this.width = 0,
    this.height = 0,
    this.framesEncoded = 0,
    this.framesDecoded = 0,
    this.active,
    this.encoder,
    this.decoder,
    this.codecId,
  });

  final String? rid;
  final int width;
  final int height;
  final int framesEncoded;
  final int framesDecoded;
  final bool? active;
  final String? encoder;
  final String? decoder;
  final String? codecId;

  int get longSide => math.max(width, height);

  @override
  String toString() =>
      '${rid ?? '-'}: ${width}x$height, active $active, '
      'encoded $framesEncoded, decoded $framesDecoded';
}

int _int(Object? v) =>
    (v is num ? v : num.tryParse('${v ?? ''}'))?.toInt() ?? 0;

/// Bob's inbound-rtp report for [cam]'s pull.
_Video _inbound(List<StatsReport> reports, RemoteTrackPublication cam) {
  final mid = cam.subscription?.mid;
  for (final r in reports) {
    final v = r.values;
    if (r.type != 'inbound-rtp' || '${v['mid']}' != mid) continue;
    return _Video(
      width: _int(v['frameWidth']),
      height: _int(v['frameHeight']),
      framesDecoded: _int(v['framesDecoded']),
      decoder: v['decoderImplementation'] as String?,
      codecId: v['codecId'] as String?,
    );
  }
  return _Video();
}

/// Alice's outbound video layers by rid.
Map<String, _Video> _outbound(List<StatsReport> reports) => {
  for (final r in reports)
    if (r.type == 'outbound-rtp' && r.values['kind'] == 'video')
      '${r.values['rid'] ?? '-'}': _Video(
        rid: r.values['rid'] as String?,
        width: _int(r.values['frameWidth']),
        height: _int(r.values['frameHeight']),
        framesEncoded: _int(r.values['framesEncoded']),
        active: r.values['active'] as bool?,
        encoder: r.values['encoderImplementation'] as String?,
      ),
};

/// The size of the (first) video media-source, or where its report has no
/// size (Windows), what the full-size layer `a` encodes, and which of the
/// two it is.
(int, int, String) _mediaSource(List<StatsReport> reports) {
  for (final r in reports) {
    if (r.type == 'media-source' && r.values['kind'] == 'video') {
      final width = _int(r.values['width']);
      if (width > 0) return (width, _int(r.values['height']), 'media-source');
    }
  }
  final a = _outbound(reports)['a'];
  if (a != null && a.active != false && a.width > 0) {
    return (a.width, a.height, 'layer a (no size in the media-source)');
  }
  return (0, 0, 'none');
}

String? _codecOf(List<StatsReport> reports, String? codecId) {
  for (final r in reports) {
    if (r.type == 'codec' && r.id == codecId) {
      return r.values['mimeType'] as String?;
    }
  }
  return null;
}

/// Keyframes encoded and keyframe requests per layer, for the log.
String _keyframes(List<StatsReport> reports) => [
  for (final r in reports)
    if (r.type == 'outbound-rtp' && r.values['kind'] == 'video')
      '${r.values['rid']}: kf ${r.values['keyFramesEncoded']} '
          'pli ${r.values['pliCount']} fir ${r.values['firCount']}',
].join('; ');

/// Polls [read] until [done], for at most [timeout].
Future<T> _poll<T>(
  Future<T> Function() read,
  bool Function(T) done,
  String what, {
  Duration timeout = _timeout,
  Duration every = const Duration(milliseconds: 250),
}) async {
  final deadline = DateTime.now().add(timeout);
  T? last;
  while (DateTime.now().isBefore(deadline)) {
    last = await read();
    if (done(last as T)) return last;
    await Future<void>.delayed(every);
  }
  fail('Timed out waiting for $what (last: $last)');
}
