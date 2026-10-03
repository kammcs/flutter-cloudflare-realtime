import 'dart:async';

import 'package:flutter/foundation.dart';

import '../audio/call_audio.dart';
import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'screen_awake_backend.dart';

/// Keeps the screen on (no dimming, no lock) during calls, for the whole
/// app (`docs/design.md` §4.7, Keeping the screen on).
///
/// The screen belongs to the device, not to a room, so rooms register
/// while joined and say whether they want the screen kept on
/// (`RoomOptions.keepScreenAwake`: by default while video is live). The
/// screen is kept on while **any** room wants it, and **the proximity
/// sensor wins**: while it is on (a voice call on the earpiece, §4.7) the
/// screen is left to it, so it goes dark at the ear.
///
/// [held] is what the platform confirmed. The last room leaving lets the
/// screen sleep again.
///
/// Internal: the Room exposes it.
class ScreenAwake {
  /// Creates the manager on [backend], gated by [proximity] (the proximity
  /// sensor being on). The app's instance is [instance]; tests may create
  /// their own.
  @visibleForTesting
  ScreenAwake(this._backend, {required StateStream<bool> Function() proximity})
    : _proximitySource = proximity;

  static ScreenAwake? _instance;

  /// The app's instance, gated by `CallAudio`'s proximity sensor.
  static ScreenAwake get instance => _instance ??= ScreenAwake(
    createScreenAwakeBackend(),
    proximity: () => CallAudio.instance.proximity,
  );

  /// **Tests only:** forgets the instance (and its backend), so the next
  /// one is created afresh from [debugScreenAwakeBackendFactory].
  @visibleForTesting
  static void debugReset() {
    _instance?.dispose();
    _instance = null;
  }

  final ScreenAwakeBackend _backend;
  final StateStream<bool> Function() _proximitySource;
  late final CoalescingRunner _runner = CoalescingRunner(_apply);

  // Every registered room, and whether it wants the screen kept on.
  final Map<Object, bool> _rooms = {};
  StateStream<bool>? _proximity;
  StreamSubscription<bool>? _proximityChanges;
  StreamSubscription<bool>? _platformChanges;
  // What the platform was last asked for.
  bool _asked = false;
  bool _disposed = false;

  /// Whether this platform can keep the screen on (all but Linux; in
  /// browsers, those with the Screen Wake Lock API).
  bool get supported => _backend.supported;

  /// Whether the screen is kept on now, as the platform confirmed.
  final StateStream<bool> held = StateStream(false, distinct: true);

  /// Whether the proximity sensor is on now (it then owns the screen).
  bool get _proximityOn => _proximity?.value ?? false;

  /// Whether the screen should be kept on now.
  @visibleForTesting
  bool get wanted => _rooms.values.any((w) => w) && !_proximityOn;

  /// Registers [room] (if it isn't yet) and records whether it wants the
  /// screen kept on ([wanted]).
  void update(Object room, {required bool wanted}) {
    if (_disposed || !supported) return;
    final first = _rooms.isEmpty;
    if (_rooms[room] == wanted && !first) return;
    _rooms[room] = wanted;
    if (first) _listen();
    unawaited(_runner.run());
  }

  /// Unregisters [room]. The last one out lets the screen sleep.
  Future<void> leave(Object room) async {
    if (_rooms.remove(room) == null) return;
    if (_rooms.isEmpty) await _stopListening();
    await _runner.run();
  }

  void _listen() {
    try {
      final proximity = _proximitySource();
      _proximity = proximity;
      _proximityChanges = proximity.stream.listen(
        (_) => _runner.run(),
        onError: (Object _) {},
      );
    } catch (error) {
      debugPrint('cloudflare_realtime: proximity state unavailable: $error');
    }
    _platformChanges = _backend.changes.listen(_onPlatformChange);
  }

  Future<void> _stopListening() async {
    await _proximityChanges?.cancel();
    _proximityChanges = null;
    _proximity = null;
    await _platformChanges?.cancel();
    _platformChanges = null;
  }

  // The web's lock released with a hidden tab, or taken again.
  void _onPlatformChange(bool on) {
    if (_disposed) return;
    held.set(_asked && on);
  }

  Future<void> _apply() async {
    if (_disposed) return;
    final want = wanted;
    if (want == _asked) return;
    _asked = want;
    bool on;
    try {
      on = await _backend.setKeepAwake(want);
    } catch (error) {
      debugPrint('cloudflare_realtime: keeping the screen on failed: $error');
      on = false;
    }
    if (!_disposed) held.set(want && on);
  }

  /// Lets the screen sleep and stops listening.
  @visibleForTesting
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _rooms.clear();
    if (_asked) {
      _asked = false;
      unawaited(
        _backend.setKeepAwake(false).then<void>((_) {}, onError: (_) {}),
      );
    }
    unawaited(_stopListening());
    unawaited(held.close());
  }
}
