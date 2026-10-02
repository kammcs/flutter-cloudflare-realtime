import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        AppleAudioCategory,
        AppleAudioCategoryOption,
        AppleAudioConfiguration,
        AppleAudioMode,
        Helper;

import '../reconnect/app_lifecycle_source.dart';
import 'audio_route.dart';
import 'call_interruption.dart';
import 'platform.dart';

/// The platform side of call audio routing (`docs/design.md` §4.6): lists
/// the routes, reports the current one, selects one. It decides nothing;
/// [CallAudio] does.
///
/// Internal. A CallKit or Core-Telecom backend can replace the platform's.
abstract interface class CallAudioBackend {
  /// Whether this platform routes call audio (phones).
  bool get supported;

  /// Puts the device in call mode, while a call has audio.
  Future<void> activate();

  /// Leaves call mode.
  Future<void> deactivate();

  /// Sets what the platform falls back to when nothing is selected: the
  /// speaker ([speaker]) or the earpiece. Only iOS has such a base (its
  /// session's voice or video chat mode).
  Future<void> setDefaultToSpeaker(bool speaker);

  /// The routes now.
  Future<List<AudioRoute>> routes();

  /// The route in use, if the platform says.
  Future<AudioRoute?> current();

  /// Asks for [route]. Completes with whether the platform accepted the
  /// request; [changes] reports when it takes effect.
  Future<bool> select(AudioRoute route);

  /// Fires when the routes or the current route may have changed.
  Stream<void> get changes;

  /// Turns the proximity sensor on ([enabled]) or off: while it is on, the
  /// screen goes dark near the ear (`docs/design.md` §4.7). Completes with
  /// whether it is on; `false` on a device without a sensor.
  Future<bool> setProximityMonitoring(bool enabled);

  /// Takes the call's audio back after an interruption: iOS activates the
  /// audio session again, Android requests the audio focus and the call
  /// mode. Completes with whether the call has its audio again; `false`
  /// while something with priority (a phone call) still holds it.
  Future<bool> resume();

  /// Interruptions of the call's audio, as the platform reports them.
  Stream<AudioInterruptionSignal> get interruptions;
}

/// An interruption of the call's audio beginning or ending, from the
/// platform (`docs/design.md` §4.7).
@immutable
class AudioInterruptionSignal {
  /// Something took the call's audio away, for [reason].
  const AudioInterruptionSignal.began(CallInterruptionReason this.reason)
    : began = true;

  /// The platform gave the audio back.
  const AudioInterruptionSignal.ended() : began = false, reason = null;

  /// Whether the interruption began (else it ended).
  final bool began;

  /// Why, when it began.
  final CallInterruptionReason? reason;

  @override
  bool operator ==(Object other) =>
      other is AudioInterruptionSignal &&
      other.began == began &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(began, reason);

  @override
  String toString() => began
      ? 'AudioInterruptionSignal.began(${reason?.name})'
      : 'AudioInterruptionSignal.ended()';
}

/// An [AudioInterruptionSignal] from the native code's event map
/// (`{event: interruption, type: began|ended, reason}`), or `null` for
/// anything else.
@visibleForTesting
AudioInterruptionSignal? audioInterruptionFromMap(Map<Object?, Object?> map) {
  if (map['event'] != 'interruption') return null;
  return switch (map['type']) {
    'began' => AudioInterruptionSignal.began(
      CallInterruptionReason.values.asNameMap()[map['reason']] ??
          CallInterruptionReason.unknown,
    ),
    'ended' => const AudioInterruptionSignal.ended(),
    _ => null,
  };
}

/// Creates a [CallAudioBackend]; the platform's by default.
typedef CallAudioBackendFactory = CallAudioBackend Function();

/// **Tests only:** replaces the platform backend. Reset it to `null`
/// afterwards, with `debugResetCallAudio`.
@visibleForTesting
CallAudioBackendFactory? debugCallAudioBackendFactory;

/// Creates the backend for this platform (or [debugCallAudioBackendFactory]'s).
CallAudioBackend createCallAudioBackend() =>
    (debugCallAudioBackendFactory ?? _platformBackend)();

/// **Tests only:** replaces the app lifecycle that call audio and the
/// background service follow (an interrupted call takes its audio back when
/// the app returns to the foreground). Reset it to `null` afterwards.
@visibleForTesting
AppLifecycleSource? debugCallLifecycleSource;

/// The app lifecycle call audio and the background service follow.
AppLifecycleSource callLifecycleSource() =>
    debugCallLifecycleSource ?? const FlutterAppLifecycleSource();

CallAudioBackend _platformBackend() => isPhone
    ? MethodChannelCallAudioBackend()
    : const UnsupportedCallAudioBackend();

/// Desktops and browsers: no call audio routing (they choose an output
/// device instead).
class UnsupportedCallAudioBackend implements CallAudioBackend {
  /// Creates the backend.
  const UnsupportedCallAudioBackend();

  @override
  bool get supported => false;

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> setDefaultToSpeaker(bool speaker) async {}

  @override
  Future<List<AudioRoute>> routes() async => const [];

  @override
  Future<AudioRoute?> current() async => null;

  @override
  Future<bool> select(AudioRoute route) async => false;

  @override
  Stream<void> get changes => const Stream.empty();

  @override
  Future<bool> setProximityMonitoring(bool enabled) async => false;

  @override
  Future<bool> resume() async => true;

  @override
  Stream<AudioInterruptionSignal> get interruptions => const Stream.empty();
}

/// The phones' backend: this package's native code on Android and iOS.
class MethodChannelCallAudioBackend implements CallAudioBackend {
  /// Creates the backend.
  MethodChannelCallAudioBackend();

  static const _methods = MethodChannel(
    'dev.kammcs.cloudflare_realtime/call_audio',
  );
  static const _events = EventChannel(
    'dev.kammcs.cloudflare_realtime/call_audio_events',
  );

  @override
  bool get supported => true;

  @override
  Future<void> activate() => _methods.invokeMethod<void>('activate');

  @override
  Future<void> deactivate() => _methods.invokeMethod<void>('deactivate');

  @override
  Future<void> setDefaultToSpeaker(bool speaker) async {
    // iOS: WebRTC applies its base configuration again whenever it starts
    // audio, so the base must say speaker or earpiece; flutter_webrtc,
    // which keeps managing the iOS session, sets it.
    if (isIOS) await Helper.setAppleAudioConfiguration(appleCallAudio(speaker));
  }

  @override
  Future<List<AudioRoute>> routes() async {
    final list = await _methods.invokeListMethod<Object?>('routes') ?? [];
    return [
      for (final entry in list)
        if (entry is Map) ?audioRouteFromMap(entry),
    ];
  }

  @override
  Future<AudioRoute?> current() async {
    final map = await _methods.invokeMapMethod<Object?, Object?>('current');
    return map == null ? null : audioRouteFromMap(map);
  }

  @override
  Future<bool> select(AudioRoute route) async =>
      await _methods.invokeMethod<bool>('select', {'id': route.id}) ?? false;

  // One native stream: "changed" strings for routes, maps for
  // interruptions.
  late final Stream<Object?> _all = _events
      .receiveBroadcastStream()
      .asBroadcastStream();

  @override
  late final Stream<void> changes = _all
      .where((event) => event is! Map)
      .map((_) {});

  @override
  Future<bool> setProximityMonitoring(bool enabled) async =>
      await _methods.invokeMethod<bool>('proximity', {'enabled': enabled}) ??
      false;

  @override
  Future<bool> resume() async =>
      await _methods.invokeMethod<bool>('resume') ?? false;

  @override
  late final Stream<AudioInterruptionSignal> interruptions = _all
      .map((event) => event is Map ? audioInterruptionFromMap(event) : null)
      .where((signal) => signal != null)
      .cast<AudioInterruptionSignal>();
}

/// An [AudioRoute] from the native code's map, or `null` for a kind this
/// package doesn't know. Also reads the system calls' endpoints (§4.8).
AudioRoute? audioRouteFromMap(Map<Object?, Object?> map) {
  final id = map['id'];
  final kind = AudioRouteKind.values.asNameMap()[map['kind']];
  if (id is! String || id.isEmpty || kind == null) return null;
  final name = map['name'];
  return AudioRoute(id: id, kind: kind, name: name is String ? name : '');
}

/// The iOS audio session for a call: play and record, Bluetooth and
/// AirPlay allowed, and with [speaker] the video-chat mode with "default to
/// speaker" (a wired or Bluetooth headset still wins), else voice chat on
/// the receiver.
AppleAudioConfiguration appleCallAudio(bool speaker) => AppleAudioConfiguration(
  appleAudioCategory: AppleAudioCategory.playAndRecord,
  appleAudioCategoryOptions: {
    AppleAudioCategoryOption.allowBluetooth,
    AppleAudioCategoryOption.allowBluetoothA2DP,
    AppleAudioCategoryOption.allowAirPlay,
    if (speaker) AppleAudioCategoryOption.defaultToSpeaker,
  },
  appleAudioMode: speaker ? AppleAudioMode.videoChat : AppleAudioMode.voiceChat,
);
