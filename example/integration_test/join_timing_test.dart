// ignore_for_file: avoid_print
// Times a room join and a first microphone publish through a real broker,
// and logs the event loop's gaps over 250 ms meanwhile (on macOS the
// platform thread is the UI thread, so a gap is a frozen app). Run it on a
// cold app start: the slow steps on macOS happen once per process
// (docs/design.md §4.2, macOS: a slow first join; doc/macos.md).
//
// It also times every platform call with the package's platform call
// timing (CloudflareRealtime.debugPlatformCallTiming, support/
// call_timing.dart) and, for each gap, names the calls sent just before or
// during it: a call that blocks the platform thread shows as a gap that
// starts when it is sent and ends when it answers.
//
//   CF_REALTIME_TIMING_MIC         publish this microphone (by label)
//                                  instead of the first in priority order
//   CF_REALTIME_TIMING_NATIVE_LOG  also log flutter_webrtc's native audio
//                                  lines at this severity (`info`)
//   CF_REALTIME_TIMING_PREWARM     set to 1 to call
//                                  CloudflareRealtime.prewarm() first, and
//                                  join 2 s after it
//
// Skipped unless CF_REALTIME_BROKER_URL is set (broker_settings.dart).

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native_logs_listener.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';

import 'broker_settings.dart';
import 'support/call_timing.dart';

const _mic = String.fromEnvironment('CF_REALTIME_TIMING_MIC');
const _nativeLog = String.fromEnvironment('CF_REALTIME_TIMING_NATIVE_LOG');
const _prewarm = String.fromEnvironment('CF_REALTIME_TIMING_PREWARM') == '1';

late CallTiming _timing;

// print, not debugPrint: debugPrint is throttled, and the app may end
// before it has written everything.
void _log(String message) =>
    print('[join-timing +${_timing.now.inMilliseconds} ms] $message');

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
      _timing = CallTiming.start();

      if (_prewarm) {
        _log('prewarming');
        await CloudflareRealtime.prewarm();
        _log('prewarmed');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final joinStart = _timing.now;
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
      // Let the last gap's report arrive.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      _log(
        'longest event-loop gap from joining: '
        '${_timing.longestGap(from: joinStart).inMilliseconds} ms; '
        'join and publish took '
        '${(_timing.now - joinStart).inMilliseconds} ms',
      );
      _timing.describeGaps().forEach(_log);
      final calls = _timing.calls
          .where((c) => c.channel == flutterWebrtcMethodChannel)
          .length;
      _log(
        'flutter_webrtc calls: $calls; 100 ms or slower: '
        '${_timing.slowCalls()}',
      );
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
