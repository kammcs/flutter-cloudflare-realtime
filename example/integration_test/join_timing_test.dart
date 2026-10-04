// ignore_for_file: avoid_print
// Times a room join and a first microphone publish through a real broker,
// and logs the event loop's gaps over 250 ms meanwhile (on macOS the
// platform thread is the UI thread, so a gap is a frozen app). Run it on a
// cold app start: the slow steps on macOS happen once per process
// (docs/design.md §4.2, macOS: a slow first join; doc/macos.md).
//
//   CF_REALTIME_TIMING_MIC         publish this microphone (by label)
//                                  instead of the first in priority order
//   CF_REALTIME_TIMING_NATIVE_LOG  also log flutter_webrtc's native audio
//                                  lines at this severity (`info`)
//
// Skipped unless CF_REALTIME_BROKER_URL is set (broker_settings.dart).

import 'dart:async';

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native_logs_listener.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';

import 'broker_settings.dart';

const _mic = String.fromEnvironment('CF_REALTIME_TIMING_MIC');
const _nativeLog = String.fromEnvironment('CF_REALTIME_TIMING_NATIVE_LOG');

final _clock = Stopwatch()..start();

// print, not debugPrint: debugPrint is throttled, and the app may end
// before it has written everything.
void _log(String message) =>
    print('[join-timing +${_clock.elapsedMilliseconds} ms] $message');

class _NativeAudioLines extends LogOutput {
  @override
  void output(OutputEvent event) {
    for (final line in event.lines) {
      if (line.contains('audio_engine_device')) _log('native: $line');
    }
  }
}

class _Everything extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final settings = BrokerSettings.read();

  testWidgets(
    'times a join and a first microphone publish',
    (tester) async {
      if (_nativeLog.isNotEmpty) {
        NativeLogsListener.instance.setLogger(
          Logger(
            output: _NativeAudioLines(),
            filter: _Everything(),
            printer: SimplePrinter(),
          ),
          _nativeLog,
        );
        addTearDown(
          () => NativeLogsListener.instance.setLogger(Logger(), 'none'),
        );
      }
      var last = _clock.elapsedMilliseconds;
      final gaps = <String>[];
      final ticker = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final now = _clock.elapsedMilliseconds;
        if (now - last > 250) gaps.add('${now - last} ms ending at +$now ms');
        last = now;
      });
      addTearDown(ticker.cancel);

      _log('joining');
      final realtime = CloudflareRealtime(broker: settings.brokerOptions());
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(InMemorySignalingHub()),
        participantId: 'timing-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(alice.leave);
      _log('joined; session ${alice.session.connectionState.name}');

      MediaDevice? device;
      if (_mic.isNotEmpty) {
        final devices = await const FlutterWebrtcMediaBackend()
            .enumerateDevices();
        device = devices.firstWhere(
          (d) => d.kind == MediaDeviceKind.audioInput && d.label == _mic,
        );
        _log('microphone listed');
      }
      final published = await alice.localParticipant.publishMicrophone(
        device: device,
      );
      _log('published');
      await published.publication.whenSending().timeout(
        const Duration(seconds: 60),
      );
      _log('sending audio');
      await alice.session.connectionStateChanges
          .firstWhere((s) => s == SfuConnectionState.connected)
          .timeout(const Duration(seconds: 60));
      _log('session connected');
      _log('event-loop gaps over 250 ms: $gaps');
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
