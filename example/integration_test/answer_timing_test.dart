// ignore_for_file: avoid_print
// Times answering a call on a cold app start: a caller, in another process
// or on another device, is already in the room sending its microphone; this
// side joins, pulls it and publishes its own microphone, the way a
// consuming app answers a call. join_timing_test.dart joins an empty room,
// so it never pulls a track while the first audio description is applied;
// this test does (docs/design.md §4.2, macOS: a slow first join).
//
// It times every platform call on every channel with the package's
// platform call timing (support/call_timing.dart), logs the event loop's
// gaps over 100 ms with the calls behind each, and, like an app's call
// screen, watches the room's stats, the caller's speaking state and the
// device list while it runs.
//
//   CF_REALTIME_TIMING_ROLE  `caller`: join, send the microphone and stay
//                            until the callee has come and gone (or
//                            4 minutes). Otherwise this side answers.
//
// Both sides use the dev server's signaling: give them the same
// CF_REALTIME_ROOM (fresh for each run) and different users. Skipped unless
// CF_REALTIME_BROKER_URL, CF_REALTIME_BROKER_TOKEN and
// CF_REALTIME_BROKER_USER are set (broker_settings.dart).

import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';
import 'support/call_timing.dart';

const _caller = String.fromEnvironment('CF_REALTIME_TIMING_ROLE') == 'caller';

final _clock = Stopwatch()..start();

void _log(String message) =>
    print('[answer-timing +${_clock.elapsed.inMilliseconds} ms] $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final settings = BrokerSettings.read();

  testWidgets(
    _caller ? 'calls and waits for the answer' : 'times answering a call',
    (tester) async {
      final timing = _caller
          ? null
          : CallTiming.start(
              options: const PlatformCallTimingOptions(
                channels: null,
                gapThreshold: Duration(milliseconds: 100),
                log: false,
              ),
            );
      final dev = settings.devServer();
      final realtime = CloudflareRealtime(broker: dev.brokerOptions());
      final signaling = dev.createSignaling();
      final joinStart = timing?.now ?? Duration.zero;
      _log('joining');
      final room = await realtime.join(
        settings.room,
        signaling: signaling,
        participantId: '${dev.userName}:${_clock.elapsedMicroseconds}',
        options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
      );
      addTearDown(() async {
        await room.leave();
        await signaling.dispose();
      });
      _log('joined; session ${room.session.connectionState.name}');

      if (_caller) {
        final published = await room.localParticipant.publishMicrophone();
        await published.publication.whenSending().timeout(
          const Duration(seconds: 60),
        );
        _log('caller sending; waiting for the answer');
        await room.participantsChanges
            .firstWhere((p) => p.isNotEmpty)
            .timeout(const Duration(minutes: 4));
        _log('answered');
        await room.participantsChanges
            .firstWhere((p) => p.isEmpty)
            .timeout(const Duration(minutes: 2));
        _log('callee left');
        return;
      }

      // What a call screen watches.
      final watching = <StreamSubscription<Object?>>[];
      watching
        ..add(room.statsChanges.listen((_) {}))
        ..add(
          room.participantsChanges.listen((participants) {
            for (final p in participants) {
              watching.add(p.speakingChanges.listen((_) {}));
            }
          }),
        );
      final devices = MediaDeviceList();
      watching.add(devices.devicesChanges.listen((_) {}));
      addTearDown(() async {
        for (final s in watching) {
          await s.cancel();
        }
        await devices.dispose();
      });

      final caller = await room.participantsChanges
          .map((p) => p.where((r) => r.microphone != null).firstOrNull)
          .firstWhere((r) => r != null)
          .timeout(const Duration(minutes: 4));
      _log('caller present');
      final published = await room.localParticipant.publishMicrophone();
      _log('published');
      await published.publication.whenSending().timeout(
        const Duration(seconds: 60),
      );
      _log('sending audio');
      final microphone = caller!.microphone!;
      await room.statsChanges
          .firstWhere((s) => (s.remote[microphone.id]?.bytesReceived ?? 0) > 0)
          .timeout(const Duration(seconds: 60));
      _log('receiving the caller');
      // Let later work (re-selections, stats) show, then report.
      await Future<void>.delayed(const Duration(seconds: 5));
      final t = timing!;
      _log(
        'longest event-loop gap from joining: '
        '${t.longestGap(from: joinStart).inMilliseconds} ms; '
        'answer to receiving took ${(t.now - joinStart).inMilliseconds} ms',
      );
      t.describeGaps(from: joinStart).forEach(_log);
      _log(
        'calls 100 ms or slower (any channel): '
        '${t.slowCalls(channel: null)}',
      );
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 7)),
  );
}
