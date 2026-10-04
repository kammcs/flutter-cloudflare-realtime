// ignore_for_file: avoid_print
// Times a room join and a first microphone publish through a real broker,
// and logs the event loop's gaps over 250 ms meanwhile (on macOS the
// platform thread is the UI thread, so a gap is a frozen app). Run it on a
// cold app start: the slow steps on macOS happen once per process
// (docs/design.md §4.2, macOS: a slow first join; doc/macos.md).
//
// It also times every `flutter_webrtc` method call (`FlutterWebRTC.Method`)
// and, for each gap, names the calls sent just before or during it: a call
// that blocks the platform thread shows as a gap that starts when it is
// sent and ends when it answers.
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

import 'dart:async';

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native_logs_listener.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';

import 'broker_settings.dart';

const _mic = String.fromEnvironment('CF_REALTIME_TIMING_MIC');
const _nativeLog = String.fromEnvironment('CF_REALTIME_TIMING_NATIVE_LOG');
const _prewarm = String.fromEnvironment('CF_REALTIME_TIMING_PREWARM') == '1';

final _clock = Stopwatch()..start();

// print, not debugPrint: debugPrint is throttled, and the app may end
// before it has written everything.
void _log(String message) =>
    print('[join-timing +${_clock.elapsedMilliseconds} ms] $message');

/// One `flutter_webrtc` method call: when it was sent and answered.
class _Call {
  _Call(this.method, this.sent);

  final String method;
  final int sent;
  int? answered;

  @override
  String toString() =>
      '$method +$sent..${answered == null ? '?' : '+$answered'} ms'
      '${answered == null ? '' : ' (${answered! - sent} ms)'}';
}

/// Times every message sent on `FlutterWebRTC.Method`, passing each on to
/// the platform unchanged.
List<_Call> _timeWebrtcCalls() {
  final calls = <_Call>[];
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.allMessagesHandler = (channel, handler, message) {
    final forward = handler != null
        ? handler(message)
        : messenger.delegate.send(channel, message);
    if (channel != 'FlutterWebRTC.Method' || message == null) return forward;
    final String method;
    try {
      method = const StandardMethodCodec().decodeMethodCall(message).method;
    } catch (_) {
      return forward;
    }
    final call = _Call(method, _clock.elapsedMilliseconds);
    calls.add(call);
    return forward?.whenComplete(
      () => call.answered = _clock.elapsedMilliseconds,
    );
  };
  addTearDown(() => messenger.allMessagesHandler = null);
  return calls;
}

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
      final calls = _timeWebrtcCalls();
      var last = _clock.elapsedMilliseconds;
      final gaps = <(int, int)>[];
      final ticker = Timer.periodic(const Duration(milliseconds: 20), (_) {
        final now = _clock.elapsedMilliseconds;
        if (now - last > 250) gaps.add((last, now));
        last = now;
      });
      addTearDown(ticker.cancel);

      if (_prewarm) {
        _log('prewarming');
        await CloudflareRealtime.prewarm();
        _log('prewarmed');
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      final joinStart = _clock.elapsedMilliseconds;
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
      _log(
        'event-loop gaps over 250 ms: '
        '${[for (final (from, to) in gaps) '${to - from} ms ending at +$to ms']}',
      );
      final longest = gaps
          .where((g) => g.$2 > joinStart)
          .fold(0, (m, g) => g.$2 - g.$1 > m ? g.$2 - g.$1 : m);
      _log(
        'longest event-loop gap from joining: $longest ms; '
        'join and publish took ${_clock.elapsedMilliseconds - joinStart} ms',
      );
      for (final (from, to) in gaps) {
        // The 20 ms tick: a call sent up to one tick before the gap began
        // may be the one that blocked it.
        final during = [
          for (final call in calls)
            if (call.sent >= from - 25 && call.sent <= to) call,
        ];
        _log('gap +$from..+$to ms (${to - from} ms): $during');
      }
      final slow = [
        for (final call in calls)
          if ((call.answered ?? _clock.elapsedMilliseconds) - call.sent >= 100)
            call,
      ];
      _log('flutter_webrtc calls: ${calls.length}; 100 ms or slower: $slow');
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
