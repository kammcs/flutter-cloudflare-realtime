// ignore_for_file: avoid_print
// Times a first call with a second device, as an app makes it: the app
// starts, shows a call screen, joins a room where another device may
// already be, publishes its camera and microphone, and shows its own and
// the other side's video. Run it on a cold app start of the device to
// measure (on macOS the slow steps happen once per process; docs/design.md
// §4.2, macOS: a slow first join), and at the same time in a browser, which
// plays the other side.
//
// The native side times every platform call with the package's platform
// call timing (CloudflareRealtime.debugPlatformCallTiming, support/
// call_timing.dart) and logs the event loop's gaps over 250 ms with the
// calls sent just before or during each (on macOS the platform thread is
// the UI thread, so a gap is a frozen app), and the slow calls.
//
// In a browser it plays the other side: it publishes its camera and
// microphone, and stays until the native side says it is done (or leaves).
//
//   CF_REALTIME_TIMING_ORDER    `together` (default: the camera and the
//                               microphone at once), `microphone-first` or
//                               `camera-first`
//   CF_REALTIME_TIMING_MIC      publish this microphone (by label) instead
//                               of the system default; the test lists the
//                               devices to find it, as a device picker would
//   CF_REALTIME_TIMING_MIC_ID   publish the microphone with this device ID,
//                               without listing the devices first, as an app
//                               does with a choice it saved earlier
//   CF_REALTIME_TIMING_CAMERA   publish this camera (by label)
//   CF_REALTIME_TIMING_PREWARM  set to 1 to call CloudflareRealtime
//                               .prewarm() at app start, and join 2 s after
//                               it
//
// Skipped unless CF_REALTIME_BROKER_URL, CF_REALTIME_BROKER_TOKEN,
// CF_REALTIME_BROKER_USER and CF_REALTIME_CROSS_DEVICE=1 are set (the dev
// server's signaling introduces the two sides; broker_settings.dart). Give
// both sides the same fresh CF_REALTIME_ROOM and different users, and start
// both from one script (docs/checkpoint.md, In a browser). The test never
// prints the settings.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';
import 'support/call_timing.dart';

const _order = String.fromEnvironment(
  'CF_REALTIME_TIMING_ORDER',
  defaultValue: 'together',
);
const _mic = String.fromEnvironment('CF_REALTIME_TIMING_MIC');
const _micId = String.fromEnvironment('CF_REALTIME_TIMING_MIC_ID');
const _camera = String.fromEnvironment('CF_REALTIME_TIMING_CAMERA');
const _prewarm = String.fromEnvironment('CF_REALTIME_TIMING_PREWARM') == '1';

/// The metadata key the native side sets to `done` when it has measured.
const _phaseKey = 'timingPhase';

final _clock = Stopwatch()..start();
CallTiming? _timing;

// print, not debugPrint: debugPrint is throttled, and the app may end
// before it has written everything.
void _log(String message) => print(
  '[publish-timing +${(_timing?.now ?? _clock.elapsed).inMilliseconds} ms] '
  '$message',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final settings = BrokerSettings.read();

  testWidgets(
    'times a first call that publishes the camera and the microphone',
    (tester) async {
      if (kIsWeb) {
        await _otherSide(settings);
      } else {
        await _measure(tester, settings);
      }
    },
    skip: settings.skipCrossDevice,
    timeout: const Timeout(Duration(minutes: 12)),
  );
}

/// The call screen: our camera and the other side's.
class _CallView extends StatelessWidget {
  const _CallView(this.room, this.camera);

  final ValueListenable<Room?> room;
  final ValueListenable<LocalMediaSource?> camera;

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ValueListenableBuilder(
        valueListenable: room,
        builder: (context, room, _) => room == null
            ? const Center(child: Text('Joining…'))
            : StreamBuilder(
                stream: room.participantsChanges,
                initialData: room.participants,
                builder: (context, snapshot) => Wrap(
                  children: [
                    SizedBox(
                      width: 320,
                      height: 180,
                      child: ValueListenableBuilder(
                        valueListenable: camera,
                        builder: (context, source, _) => source == null
                            ? const ColoredBox(color: Colors.black)
                            : ParticipantVideoView.local(source),
                      ),
                    ),
                    for (final p
                        in snapshot.data ?? const <RemoteParticipant>[])
                      if (p.camera case final camera?)
                        SizedBox(
                          width: 320,
                          height: 180,
                          child: ParticipantVideoView.remote(camera),
                        ),
                  ],
                ),
              ),
      ),
    ),
  );
}

Future<void> _measure(WidgetTester tester, BrokerSettings settings) async {
  final timing = _timing = CallTiming.start();
  _log('app started; order $_order, prewarm $_prewarm');
  final room = ValueNotifier<Room?>(null);
  final camera = ValueNotifier<LocalMediaSource?>(null);
  await tester.pumpWidget(_CallView(room, camera));

  if (_prewarm) {
    _log('prewarming');
    await CloudflareRealtime.prewarm();
    _log('prewarmed');
    await Future<void>.delayed(const Duration(seconds: 2));
  }

  final dev = settings.devServer();
  final realtime = CloudflareRealtime(broker: dev.brokerOptions());
  final signaling = dev.createSignaling();
  final joinStart = timing.now;
  _log('joining');
  final joined = await realtime.join(
    settings.room,
    signaling: signaling,
    participantId: '${dev.userName}:${DateTime.now().microsecondsSinceEpoch}',
    metadata: const {_phaseKey: 'running'},
    options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
  );
  var left = false;
  Future<void> leave() async {
    if (left) return;
    left = true;
    await joined.leave();
    await signaling.dispose();
  }

  addTearDown(leave);
  room.value = joined;
  _log('joined; ${joined.participants.length} other participant(s)');

  Future<MediaDevice?> device(MediaDeviceKind kind, String label) async {
    if (label.isEmpty) return null;
    final devices = await const FlutterWebrtcMediaBackend().enumerateDevices();
    final matching = [
      for (final d in devices)
        if (d.kind == kind && d.label == label) d,
    ];
    _log('listed: $label as ${[for (final d in matching) d.deviceId]}');
    // The device itself rather than the system default's entry, which
    // has the same label.
    return matching.firstWhere(
      (d) => d.deviceId != 'default',
      orElse: () => matching.first,
    );
  }

  Future<LocalMediaPublication> publishMicrophone() async {
    final chosen = _micId.isNotEmpty
        ? MediaDevice(
            deviceId: _micId,
            kind: MediaDeviceKind.audioInput,
            label: _mic.isEmpty ? _micId : _mic,
          )
        : await device(MediaDeviceKind.audioInput, _mic);
    _log('publishing the microphone');
    final published = await joined.localParticipant.publishMicrophone(
      device: chosen,
    );
    _log('microphone published');
    await published.publication.whenSending().timeout(
      const Duration(seconds: 90),
    );
    _log('microphone sending');
    return published;
  }

  Future<LocalMediaPublication> publishCamera() async {
    final chosen = await device(MediaDeviceKind.videoInput, _camera);
    _log('publishing the camera');
    final published = await joined.localParticipant.publishCamera(
      device: chosen,
    );
    camera.value = published.mediaSource;
    final source = published.mediaSource;
    _log(
      'camera published'
      '${source is CameraSource ? ' (${source.activeDevice?.label})' : ''}',
    );
    await published.publication.whenSending().timeout(
      const Duration(seconds: 90),
    );
    _log('camera sending');
    return published;
  }

  switch (_order) {
    case 'microphone-first':
      await publishMicrophone();
      await publishCamera();
    case 'camera-first':
      await publishCamera();
      await publishMicrophone();
    default:
      await Future.wait([publishCamera(), publishMicrophone()]);
  }
  final published = timing.now;

  try {
    // The other side's camera and microphone, pulled and shown.
    final peer = await joined.participantsChanges
        .map((list) => list.where((p) => p.camera != null))
        .firstWhere((peers) => peers.isNotEmpty)
        .timeout(const Duration(minutes: 8))
        .then((peers) => peers.first);
    _log('the other side is here: ${peer.participantId}');
    final remoteCamera = peer.camera!;
    await remoteCamera.trackChanges
        .firstWhere(
          (t) =>
              t != null &&
              remoteCamera.subscriptionState == SfuTrackState.active,
        )
        .timeout(const Duration(seconds: 60));
    _log('the other side\'s camera is pulled');
    // Watch for a while with everything running: stats, speakers, video.
    await Future<void>.delayed(const Duration(seconds: 10));
    _log('done watching');
  } finally {
    // Also when the other side never came: the publish was measured.
    await _report(timing, joinStart: joinStart, published: published);
    await joined.localParticipant.setMetadata({_phaseKey: 'done'});
    await Future<void>.delayed(const Duration(seconds: 2));
  }
  await leave();
}

Future<void> _report(
  CallTiming timing, {
  required Duration joinStart,
  required Duration published,
}) async {
  final end = timing.now;
  await Future<void>.delayed(const Duration(milliseconds: 100));
  _log(
    'join to both sending: ${(published - joinStart).inMilliseconds} ms; '
    'longest event-loop gap from joining: '
    '${timing.longestGap(from: joinStart).inMilliseconds} ms; '
    'from app start: ${timing.longestGap().inMilliseconds} ms',
  );
  timing.describeGaps().forEach(_log);
  _log('slow calls (100 ms or more, every channel):');
  for (final call in timing.slowCalls(channel: null)) {
    _log('  ${call.channel} $call ${call.argumentKeys}');
  }
  final byMethod = <String, List<Duration>>{};
  for (final call in timing.calls) {
    if (call.channel != flutterWebrtcMethodChannel) continue;
    (byMethod[call.method] ??= []).add(call.duration!);
  }
  _log('flutter_webrtc calls by method (count, total, longest):');
  for (final MapEntry(key: method, value: durations) in byMethod.entries) {
    final total = durations.fold(Duration.zero, (a, b) => a + b);
    final longest = durations.reduce((a, b) => a > b ? a : b);
    _log(
      '  $method: ${durations.length}, ${total.inMilliseconds} ms, '
      '${longest.inMilliseconds} ms',
    );
  }
  _log('measured until +${end.inMilliseconds} ms');
}

/// The other side, in a browser: publishes its camera and microphone and
/// stays until the native side is done.
Future<void> _otherSide(BrokerSettings settings) async {
  final dev = settings.devServer();
  final realtime = CloudflareRealtime(broker: dev.brokerOptions());
  final signaling = dev.createSignaling();
  final room = await realtime.join(
    settings.room,
    signaling: signaling,
    participantId: '${dev.userName}:${DateTime.now().microsecondsSinceEpoch}',
    options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
  );
  addTearDown(() async {
    await room.leave();
    await signaling.dispose();
  });
  _log('the other side joined');
  await Future.wait([
    room.localParticipant.publishCamera(),
    room.localParticipant.publishMicrophone(),
  ]);
  _log('the other side is publishing');
  // Until the measured side is done (it may drop out of the signaling for
  // a moment meanwhile, so leaving doesn't count).
  var present = '';
  await room.participantsChanges
      .firstWhere((list) {
        final ids = ([
          for (final p in list) p.participantId,
        ]..sort()).join(', ');
        if (ids != present) {
          _log('participants: [$ids]');
          present = ids;
        }
        return list.any((p) => p.metadata?[_phaseKey] == 'done');
      })
      .timeout(const Duration(minutes: 10));
  _log('the measured side is done');
}
