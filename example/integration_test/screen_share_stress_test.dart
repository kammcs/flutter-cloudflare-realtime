// ignore_for_file: avoid_print
// A desktop screen share, over and over, through a real broker: Alice shares
// her first screen, a local view renders it and Bob (a second room in the
// process) pulls and renders it, then Alice stops while frames flow, and
// every second time switches to a window (this app's own, if listed) and
// back first. It found a crash in flutter_webrtc's Darwin renderer when a
// renderer is released while frames still arrive (docs/design.md §4.3,
// Releasing a native renderer), and the app freezing while the share's
// source watcher re-scanned the sources (§10). It logs the event loop's
// gaps over 300 ms (the platform thread is the UI thread on macOS).
//
//   CF_REALTIME_STRESS_ITERATIONS    shares (default 30)
//   CF_REALTIME_STRESS_HOLD_MS       how long each share is shown (2500)
//   CF_REALTIME_STRESS_BUSY_MS       keep the UI thread busy in bursts of
//                                    this many ms for 1 s after each stop,
//                                    as a loaded machine would (off)
//   CF_REALTIME_STRESS_LONG_SECONDS  instead: one share this long, logging
//                                    decoded frames and gaps every 5 s
//
// Desktop only; needs the Screen Recording permission on macOS. Skipped
// unless CF_REALTIME_BROKER_URL is set (broker_settings.dart). Window
// titles are never logged.

import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

const _iterations = int.fromEnvironment(
  'CF_REALTIME_STRESS_ITERATIONS',
  defaultValue: 30,
);
const _longSeconds = int.fromEnvironment('CF_REALTIME_STRESS_LONG_SECONDS');
const _busyMs = int.fromEnvironment('CF_REALTIME_STRESS_BUSY_MS');
const _holdMs = int.fromEnvironment(
  'CF_REALTIME_STRESS_HOLD_MS',
  defaultValue: 2500,
);

final _clock = Stopwatch()..start();

String _now() {
  final t = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
      '${t.millisecond.toString().padLeft(3, '0')}';
}

void _log(String message) => print('[stress ${_now()}] $message');

class _Stage extends StatefulWidget {
  const _Stage({required this.controller});
  final _StageController controller;
  @override
  State<_Stage> createState() => _StageState();
}

class _StageController extends ChangeNotifier {
  LocalMediaSource? local;
  RemoteTrackPublication? remote;
  void set({LocalMediaSource? local, RemoteTrackPublication? remote}) {
    this.local = local;
    this.remote = remote;
    notifyListeners();
  }
}

class _StageState extends State<_Stage> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final local = widget.controller.local;
    final remote = widget.controller.remote;
    return MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            Expanded(
              child: local == null
                  ? const ColoredBox(color: Colors.black)
                  : ParticipantVideoView.local(
                      local,
                      key: ValueKey(local),
                      fit: VideoViewFit.contain,
                    ),
            ),
            Expanded(
              child: remote == null
                  ? const ColoredBox(color: Colors.black)
                  : ParticipantVideoView.remote(
                      remote,
                      key: ValueKey(remote),
                      fit: VideoViewFit.contain,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

num _sum(List<dynamic> reports, String type, String key) {
  num total = 0;
  for (final r in reports) {
    if (r.type == type) {
      final v = r.values[key];
      total += v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
    }
  }
  return total;
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final settings = BrokerSettings.read();

  testWidgets(
    'screen share stress',
    (tester) async {
      var last = _clock.elapsedMilliseconds;
      var worst = 0;
      final stalls = <String>[];
      final ticker = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final now = _clock.elapsedMilliseconds;
        final gap = now - last;
        if (gap > worst) worst = gap;
        if (gap > 300) {
          stalls.add('$gap ms at ${_now()}');
          _log('STALL $gap ms');
        }
        last = now;
      });
      addTearDown(ticker.cancel);

      final controller = _StageController();
      await tester.pumpWidget(_Stage(controller: controller));

      final realtime = CloudflareRealtime(broker: settings.brokerOptions());
      final hub = InMemorySignalingHub();
      const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'stress-alice-$suffix',
        options: options,
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'stress-bob-$suffix',
        options: options,
      );
      addTearDown(bob.leave);

      final capturer = const FlutterWebrtcMediaBackend().desktopCapturer!;
      final sources = await capturer.getSources(
        types: {ScreenSourceType.screen, ScreenSourceType.window},
      );
      final screen = sources.firstWhere(
        (s) => s.type == ScreenSourceType.screen,
      );
      // The example app's own window, if listed (never log names).
      final windows = sources.where((s) => s.type == ScreenSourceType.window);
      final own = windows
          .where((s) => s.name.contains('cloudflare_realtime_example'))
          .firstOrNull;
      final window = own ?? windows.firstOrNull;
      _log(
        'sources: ${sources.length}, windows: ${windows.length}, '
        'window to switch to: ${own != null
            ? 'own'
            : window != null
            ? 'another'
            : 'none'}',
      );

      Future<RemoteTrackPublication> remoteScreen() async {
        final deadline = DateTime.now().add(const Duration(seconds: 30));
        while (DateTime.now().isBefore(deadline)) {
          for (final p in bob.participants) {
            final s = p.screen;
            if (s != null && s.subscriptionState == SfuTrackState.active) {
              return s;
            }
          }
          await tester.pump(const Duration(milliseconds: 100));
        }
        throw StateError('Bob never pulled the screen');
      }

      Future<void> hold(int ms) async {
        final end = DateTime.now().add(Duration(milliseconds: ms));
        while (DateTime.now().isBefore(end)) {
          await tester.pump(const Duration(milliseconds: 50));
        }
      }

      if (_longSeconds > 0) {
        final shared = await alice.localParticipant.publishScreen(
          source: screen,
        );
        final remote = await remoteScreen();
        controller.set(local: shared.mediaSource, remote: remote);
        _log('long share started');
        for (var s = 0; s < _longSeconds; s += 5) {
          await hold(5000);
          final decoded = _sum(
            await bob.session.getStats(),
            'inbound-rtp',
            'framesDecoded',
          );
          _log('t=${s + 5} s: decoded $decoded, worst gap $worst ms');
          worst = 0;
        }
        controller.set();
        await hold(500);
        await shared.unpublish();
        _log('stalls: $stalls');
        return;
      }

      for (var i = 1; i <= _iterations; i++) {
        final shared = await alice.localParticipant.publishScreen(
          source: screen,
        );
        final share = shared.mediaSource as ScreenShareSource;
        final remote = await remoteScreen();
        controller.set(local: share, remote: remote);
        await hold(_holdMs);
        final decoded = _sum(
          await bob.session.getStats(),
          'inbound-rtp',
          'framesDecoded',
        );
        if (window != null && i.isEven) {
          await share.select(window);
          await hold(_holdMs);
          await share.select(screen);
          await hold(_holdMs ~/ 2);
        }
        // Stop while frames flow; the views go with it, as in an app.
        final stop = shared.unpublish();
        controller.set();
        if (_busyMs > 0) {
          // Keep the (merged) main thread busy in bursts while the views
          // release their renderers, as a loaded machine would.
          final end = DateTime.now().add(const Duration(seconds: 1));
          while (DateTime.now().isBefore(end)) {
            final spin = Stopwatch()..start();
            while (spin.elapsedMilliseconds < _busyMs) {}
            await Future<void>.delayed(Duration.zero);
          }
        }
        await stop;
        await hold(300);
        _log(
          'iteration $i done: decoded $decoded, worst gap $worst ms, '
          'stalls so far ${stalls.length}',
        );
        worst = 0;
      }
      _log('stalls: $stalls');
    },
    skip: settings.skip || !_desktop,
    timeout: const Timeout(Duration(minutes: 30)),
  );
}

final _desktop =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);
