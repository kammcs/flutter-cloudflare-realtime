// Turns on the package's platform call timing
// (CloudflareRealtime.debugPlatformCallTiming) in an integration test, and
// collects what it reports.
//
// An app creates PlatformCallTimingBinding first thing in main(); a test
// has the integration test binding instead, whose messenger can't be
// replaced. So this sends every message the test binding would pass to the
// platform through PlatformCallTimingBinding.wrapMessenger instead, which
// times it.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// The calls and gaps reported since [CallTiming.start].
class CallTiming {
  CallTiming._();

  /// Every call that answered.
  final List<PlatformCall> calls = [];

  /// Every event-loop gap.
  final List<EventLoopGapEvent> gaps = [];

  final _clock = Stopwatch();

  /// The time on the timing's clock (since [start]).
  Duration get now => _clock.elapsed;

  /// Starts timing with [options] (default: every channel, no log) until
  /// the test ends.
  static CallTiming start({
    PlatformCallTimingOptions options = const PlatformCallTimingOptions(
      channels: null,
      log: false,
    ),
  }) {
    final timing = CallTiming._();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final timed = PlatformCallTimingBinding.wrapMessenger(messenger.delegate);
    messenger.allMessagesHandler = (channel, handler, message) =>
        handler != null ? handler(message) : timed.send(channel, message);
    final subscription = CloudflareRealtime.debugPlatformCallTimingEvents
        .listen((event) {
          switch (event) {
            case PlatformCallAnsweredEvent(:final call):
              timing.calls.add(call);
            case EventLoopGapEvent():
              timing.gaps.add(event);
          }
        });
    CloudflareRealtime.debugPlatformCallTiming = options;
    timing._clock.start();
    addTearDown(() {
      CloudflareRealtime.debugPlatformCallTiming = null;
      messenger.allMessagesHandler = null;
      return subscription.cancel();
    });
    return timing;
  }

  /// The gaps that ended after [from], one line each, with the calls
  /// sent then and the calls pending.
  List<String> describeGaps({Duration from = Duration.zero}) => [
    for (final gap in gaps)
      if (gap.end > from)
        'gap +${gap.start.inMilliseconds}..+${gap.end.inMilliseconds} ms '
            '(${gap.duration.inMilliseconds} ms): sent ${gap.sent}'
            '${gap.pending.isEmpty ? '' : '; pending ${gap.pending}'}',
  ];

  /// The longest gap that ended after [from].
  Duration longestGap({Duration from = Duration.zero}) => gaps
      .where((g) => g.end > from)
      .fold(Duration.zero, (m, g) => g.duration > m ? g.duration : m);

  /// The calls on [channel] (default: `flutter_webrtc`'s) that took at
  /// least [threshold].
  List<PlatformCall> slowCalls({
    Duration threshold = const Duration(milliseconds: 100),
    String? channel = flutterWebrtcMethodChannel,
  }) => [
    for (final call in calls)
      if ((channel == null || call.channel == channel) &&
          call.duration! >= threshold)
        call,
  ];
}
