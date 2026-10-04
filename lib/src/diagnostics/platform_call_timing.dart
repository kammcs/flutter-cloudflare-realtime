import 'dart:async';
import 'dart:ui' as ui;

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The channel `flutter_webrtc` sends its method calls on.
const String flutterWebrtcMethodChannel = 'FlutterWebRTC.Method';

/// How `CloudflareRealtime.debugPlatformCallTiming` times platform calls
/// and the event loop. A debug aid: see that setter.
final class PlatformCallTimingOptions {
  /// Times the calls on [channels] (by default `flutter_webrtc`'s), reports
  /// event-loop gaps over [gapThreshold], and, with [log], prints the gaps
  /// and the calls slower than [slowCallThreshold] with `debugPrint`.
  const PlatformCallTimingOptions({
    this.channels = const {flutterWebrtcMethodChannel},
    this.gapThreshold = const Duration(milliseconds: 250),
    this.slowCallThreshold = const Duration(milliseconds: 100),
    this.log = true,
  });

  /// The platform channels whose calls are timed, or `null` for every
  /// channel the app sends on (other plugins' too, and Flutter's own, such
  /// as `flutter/platform`). Default: `flutter_webrtc`'s method channel,
  /// [flutterWebrtcMethodChannel].
  final Set<String>? channels;

  /// How late the event loop must run to count as a gap: a frozen UI on
  /// platforms whose UI thread is the platform thread (macOS, iOS,
  /// Android). Default 250 ms. The loop is checked every 20 ms, so values
  /// under about 50 ms report scheduling noise.
  final Duration gapThreshold;

  /// How long a call must take to be logged. Default 100 ms. Every call is
  /// reported on the event stream whatever its duration.
  final Duration slowCallThreshold;

  /// Whether to print the gaps and the slow calls with `debugPrint`.
  /// Default `true`.
  final bool log;
}

/// One platform call seen by the platform call timing: which method, when
/// it was sent and, if it had answered when the event was made, when it
/// answered.
///
/// Times are measured from the moment the timing was turned on. Only the
/// method's name and the keys of a map argument are kept, never the
/// arguments' values or the reply.
final class PlatformCall {
  /// Creates a call record.
  const PlatformCall({
    required this.channel,
    required this.method,
    this.argumentKeys = const [],
    required this.sentAt,
    this.answeredAt,
  });

  /// The platform channel, such as [flutterWebrtcMethodChannel].
  final String channel;

  /// The method's name (`createPeerConnection`, `getSources`, …), or
  /// `<message>` for a message that isn't a method call.
  final String method;

  /// The keys of the call's arguments when they are a map, such as
  /// `peerConnectionId`; never their values.
  final List<String> argumentKeys;

  /// When the call was sent.
  final Duration sentAt;

  /// When the platform answered, or `null` if it hadn't yet.
  final Duration? answeredAt;

  /// How long the platform took to answer, or `null` if it hadn't yet.
  Duration? get duration => answeredAt == null ? null : answeredAt! - sentAt;

  @override
  String toString() {
    final answered = answeredAt;
    final sent = sentAt.inMilliseconds;
    return answered == null
        ? '$method (sent +$sent ms, unanswered)'
        : '$method (${(answered - sentAt).inMilliseconds} ms, '
              '+$sent..+${answered.inMilliseconds} ms)';
  }
}

/// What `CloudflareRealtime.debugPlatformCallTimingEvents` reports: a
/// platform call that answered, or a gap in the event loop.
sealed class PlatformCallTimingEvent {
  const PlatformCallTimingEvent();
}

/// A timed platform call answered.
final class PlatformCallAnsweredEvent extends PlatformCallTimingEvent {
  /// Creates the event for [call].
  const PlatformCallAnsweredEvent(this.call, {required this.longestGap});

  /// The call, with its [PlatformCall.answeredAt].
  final PlatformCall call;

  /// The longest event-loop gap (over the threshold) between the call's
  /// sending and its answer, or [Duration.zero]. A call about as long as
  /// its gap blocked the event loop: on macOS, iOS and Android, the
  /// platform plugin answered it on the UI thread.
  final Duration longestGap;
}

/// The event loop ran late by more than the threshold: on platforms whose
/// UI thread is the platform thread, the app froze for [duration].
///
/// The calls that may have caused it are in [sent] (a call that blocks the
/// platform thread is sent just before the gap begins and answers when it
/// ends) and [pending]. A gap with neither came from something else on that
/// thread: the app's own Dart code, an untimed channel, or native work the
/// Dart side never asked for.
final class EventLoopGapEvent extends PlatformCallTimingEvent {
  /// Creates a gap event.
  const EventLoopGapEvent({
    required this.start,
    required this.end,
    this.sent = const [],
    this.pending = const [],
  });

  /// When the event loop last ran before the gap.
  final Duration start;

  /// When it ran again.
  final Duration end;

  /// How long the event loop didn't run.
  Duration get duration => end - start;

  /// The timed calls sent from just before the gap began (two checks of
  /// the event loop, 40 ms) until it ended: the likely cause.
  final List<PlatformCall> sent;

  /// The timed calls sent earlier and not yet answered when the gap
  /// began. A call answered asynchronously on another thread doesn't
  /// block, so a long one is listed in every gap during it.
  final List<PlatformCall> pending;
}

/// A binding that times platform calls: `WidgetsFlutterBinding`, whose
/// binary messenger reports each message it sends to
/// `CloudflareRealtime.debugPlatformCallTiming`.
///
/// Flutter creates the messenger once, with the binding, and every platform
/// channel (`flutter_webrtc`'s included) sends through it; so to time the
/// calls an app makes through `flutter_webrtc` directly, as well as the
/// package's, create this binding before any other, first thing in `main`:
///
/// ```dart
/// void main() {
///   PlatformCallTimingBinding.ensureInitialized();
///   CloudflareRealtime.debugPlatformCallTiming =
///       const PlatformCallTimingOptions();
///   runApp(const MyApp());
/// }
/// ```
///
/// While the timing is off (`debugPlatformCallTiming` is `null`, the
/// default), the messenger only passes each message on. An app with its
/// own binding class overrides `createBinaryMessenger` to return
/// [wrapMessenger] of the default instead. A test binding has a messenger
/// of its own: forward its messages through [wrapMessenger] (see the
/// example's `join_timing_test.dart`).
final class PlatformCallTimingBinding extends WidgetsFlutterBinding {
  PlatformCallTimingBinding._();

  /// Creates this binding if no binding exists yet, and returns the
  /// binding. If another binding was created first, its messenger can't be
  /// wrapped any more: the timing then reports event-loop gaps without
  /// naming calls, and says so in the log.
  static WidgetsBinding ensureInitialized() {
    if (!_bindingExists()) PlatformCallTimingBinding._();
    return WidgetsBinding.instance;
  }

  static bool _bindingExists() {
    try {
      WidgetsBinding.instance;
      return true;
    } on Object {
      return false;
    }
  }

  /// Returns a messenger that sends through [messenger] and reports each
  /// message to the platform call timing while it is on.
  static BinaryMessenger wrapMessenger(BinaryMessenger messenger) {
    PlatformCallTimer.messengerWrapped = true;
    return _TimingMessenger(messenger);
  }

  @override
  BinaryMessenger createBinaryMessenger() =>
      wrapMessenger(super.createBinaryMessenger());
}

class _TimingMessenger extends BinaryMessenger {
  const _TimingMessenger(this._inner);

  final BinaryMessenger _inner;

  @override
  Future<ByteData?>? send(String channel, ByteData? message) =>
      PlatformCallTimer.send(channel, message, _inner.send);

  @override
  void setMessageHandler(String channel, MessageHandler? handler) =>
      _inner.setMessageHandler(channel, handler);

  @override
  // The interface still declares it; pass it on like any other method.
  // ignore: deprecated_member_use
  Future<void> handlePlatformMessage(
    String channel,
    ByteData? data,
    ui.PlatformMessageResponseCallback? callback,
  ) =>
      // ignore: deprecated_member_use
      _inner.handlePlatformMessage(channel, data, callback);
}

class _Call {
  _Call(this.channel, this.method, this.argumentKeys, this.sentAt);

  final String channel;
  final String method;
  final List<String> argumentKeys;
  final Duration sentAt;
  Duration? answeredAt;

  PlatformCall snapshot() => PlatformCall(
    channel: channel,
    method: method,
    argumentKeys: argumentKeys,
    sentAt: sentAt,
    answeredAt: answeredAt,
  );
}

/// The platform call timing behind `CloudflareRealtime
/// .debugPlatformCallTiming`: times the calls a [PlatformCallTimingBinding]
/// messenger reports, and checks the event loop every [tick] for gaps.
///
/// Off by default, and then free: no timer runs, and a wrapped messenger
/// only checks [options] before passing a message on.
///
/// Internal: not exported from the package barrel.
abstract final class PlatformCallTimer {
  /// How often the event loop is checked while the timing is on.
  static const Duration tick = Duration(milliseconds: 20);

  /// How long answered calls and gaps are kept, to report the gaps that
  /// overlapped a call and the calls in flight during a gap.
  static const Duration _keep = Duration(seconds: 120);

  static PlatformCallTimingOptions? _options;
  static Stopwatch? _clock;
  static Timer? _ticker;
  static Duration _lastTick = Duration.zero;
  static int _generation = 0;
  static final List<_Call> _calls = [];
  static final List<(Duration, Duration)> _gaps = [];
  static final StreamController<PlatformCallTimingEvent> _events =
      StreamController.broadcast();

  /// Whether a messenger has been wrapped ([PlatformCallTimingBinding]),
  /// so that calls can be timed at all.
  static bool messengerWrapped = false;

  /// The options while the timing is on, else `null`.
  static PlatformCallTimingOptions? get options => _options;

  static set options(PlatformCallTimingOptions? value) {
    final wasOn = _options != null;
    _options = value;
    if (value == null) {
      if (wasOn) _stop();
      return;
    }
    if (wasOn) return;
    _generation++;
    _clock = clock.stopwatch()..start();
    _lastTick = Duration.zero;
    _ticker = Timer.periodic(tick, (_) => _onTick());
    if (value.log) {
      debugPrint(
        'cloudflare_realtime: platform call timing on '
        '(${value.channels == null ? 'every channel' : value.channels!.join(', ')}; '
        'gaps over ${value.gapThreshold.inMilliseconds} ms)',
      );
      if (!messengerWrapped) {
        debugPrint(
          'cloudflare_realtime: platform calls aren\'t timed, only event-loop '
          'gaps: call PlatformCallTimingBinding.ensureInitialized() first '
          'thing in main()',
        );
      }
    }
  }

  /// The timed calls and the gaps, while the timing is on.
  static Stream<PlatformCallTimingEvent> get events => _events.stream;

  static void _stop() {
    _ticker?.cancel();
    _ticker = null;
    _clock = null;
    _calls.clear();
    _gaps.clear();
    _generation++;
  }

  static Duration get _now => _clock!.elapsed;

  /// Sends [message] on [channel] through [forward], timing it if the
  /// timing is on and [channel] is one of its channels.
  static Future<ByteData?>? send(
    String channel,
    ByteData? message,
    Future<ByteData?>? Function(String channel, ByteData? message) forward,
  ) {
    final options = _options;
    if (options == null ||
        message == null ||
        !(options.channels?.contains(channel) ?? true)) {
      return forward(channel, message);
    }
    final (method, keys) = _describe(message);
    final call = _Call(channel, method, keys, _now);
    final generation = _generation;
    _calls.add(call);
    final Future<ByteData?>? reply;
    try {
      reply = forward(channel, message);
    } catch (_) {
      _answered(call, generation);
      rethrow;
    }
    if (reply == null) {
      _answered(call, generation);
      return null;
    }
    return reply.whenComplete(() => _answered(call, generation));
  }

  /// The method's name and its argument keys; never the values.
  static (String, List<String>) _describe(ByteData message) {
    for (final codec in const [StandardMethodCodec(), JSONMethodCodec()]) {
      try {
        final call = codec.decodeMethodCall(message);
        final arguments = call.arguments;
        return (
          call.method,
          arguments is Map
              ? [for (final key in arguments.keys) '$key']
              : const <String>[],
        );
      } on Object {
        // Not this codec's: try the next.
      }
    }
    return ('<message>', const []);
  }

  static void _answered(_Call call, int generation) {
    final options = _options;
    if (options == null || generation != _generation) return;
    final now = _now;
    call.answeredAt = now;
    var longest = Duration.zero;
    for (final (start, end) in _gaps) {
      if (end > call.sentAt && start < now && end - start > longest) {
        longest = end - start;
      }
    }
    // A gap that is still running: the reply arrived before the late tick.
    final running = now - _lastTick;
    if (running > options.gapThreshold && running > longest) {
      longest = running;
    }
    final event = PlatformCallAnsweredEvent(
      call.snapshot(),
      longestGap: longest,
    );
    _events.add(event);
    if (options.log && now - call.sentAt >= options.slowCallThreshold) {
      debugPrint(
        'cloudflare_realtime: ${_name(call.channel, call.method)} took '
        '${(now - call.sentAt).inMilliseconds} ms '
        '(+${call.sentAt.inMilliseconds} ms)'
        '${longest > Duration.zero ? '; the event loop stopped for ${longest.inMilliseconds} ms meanwhile' : ''}',
      );
    }
  }

  static void _onTick() {
    final options = _options;
    if (options == null) return;
    final now = _now;
    final start = _lastTick;
    _lastTick = now;
    final generation = _generation;
    if (now - start > options.gapThreshold) {
      _gaps.add((start, now));
      // Report on the next check, so that the replies processed right
      // after the gap have their answer time.
      Timer(tick, () => _reportGap(start, now, generation));
    }
    _gaps.removeWhere((gap) => now - gap.$2 > _keep);
    _calls.removeWhere(
      (call) => call.answeredAt != null && now - call.answeredAt! > _keep,
    );
  }

  static void _reportGap(Duration start, Duration end, int generation) {
    final options = _options;
    if (options == null || generation != _generation) return;
    // A call sent up to two checks before the gap began may have caused it.
    final from = start - tick * 2;
    final sent = <PlatformCall>[];
    final pending = <PlatformCall>[];
    for (final call in _calls) {
      if (call.sentAt > end) continue;
      if (call.sentAt >= from) {
        sent.add(call.snapshot());
      } else if (call.answeredAt == null || call.answeredAt! > start) {
        pending.add(call.snapshot());
      }
    }
    _events.add(
      EventLoopGapEvent(start: start, end: end, sent: sent, pending: pending),
    );
    if (options.log) {
      String names(List<PlatformCall> calls) => calls
          .map(
            (c) =>
                '${_name(c.channel, c.method)}'
                '(${c.duration == null ? 'unanswered' : '${c.duration!.inMilliseconds} ms'})',
          )
          .join(', ');
      debugPrint(
        'cloudflare_realtime: event loop stopped for '
        '${(end - start).inMilliseconds} ms '
        '(+${start.inMilliseconds}..+${end.inMilliseconds} ms); '
        'sent then: ${sent.isEmpty ? 'no timed call' : names(sent)}'
        '${pending.isEmpty ? '' : '; pending: ${names(pending)}'}',
      );
    }
  }

  static String _name(String channel, String method) =>
      channel == flutterWebrtcMethodChannel ? method : '$channel $method';

  /// Turns the timing off and forgets the wrapped messenger, for tests.
  @visibleForTesting
  static void reset() {
    options = null;
    messengerWrapped = false;
  }
}
