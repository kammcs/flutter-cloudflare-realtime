import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;

import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'audio_route.dart';
import 'call_audio_backend.dart';
import 'call_interruption.dart';

/// Thrown by `Room.selectAudioRoute` when the platform refuses the route,
/// for example one that has just disconnected.
class AudioRouteUnavailableException implements Exception {
  /// Creates the exception.
  const AudioRouteUnavailableException(this.route);

  /// The route that was asked for.
  final AudioRoute route;

  @override
  String toString() => 'AudioRouteUnavailableException($route)';
}

/// Call audio routing on phones, for the whole app (`docs/design.md` §4.6).
///
/// The route belongs to the device, not to a room, so rooms register
/// while joined and share one policy:
///
/// 1. a route the user picked ([select]) sticks, until a new headset
///    arrives or the route disappears;
/// 2. otherwise a headset that has just connected;
/// 3. otherwise the current route if it is external (one the user chose
///    elsewhere, such as Apple's route picker);
/// 4. otherwise the most recently connected headset;
/// 5. otherwise the speaker when a room has video (or the speaker is
///    forced), else the earpiece.
///
/// The current route is always read back from the platform.
///
/// While a **system call** exists (CallKit or Core-Telecom,
/// `docs/design.md` §4.8), the system owns the audio session and, on
/// Android, the routing: `SystemCalls` hands call audio a backend for it
/// ([useSystemCall]), and the same policy runs on the system's routes.
///
/// It also follows **interruptions** (a phone call, another app's audio)
/// and drives the **proximity sensor** (`docs/design.md` §4.7):
///
/// - [interruption] is set while the platform has taken the call's audio
///   away. When the platform gives it back, or when the app returns to the
///   foreground (the platform doesn't always say), the call takes its audio
///   back ([resume]) and the route is chosen again.
/// - the proximity sensor is on while the route is the earpiece and no room
///   has video, unless a room turned it off.
///
/// Internal: the Room exposes it.
class CallAudio {
  CallAudio._(this._platform);

  static CallAudio? _instance;

  /// The app's instance.
  static CallAudio get instance =>
      _instance ??= CallAudio._(createCallAudioBackend());

  /// **Tests only:** forgets the instance (and its backend), so the next
  /// one is created afresh from [debugCallAudioBackendFactory].
  @visibleForTesting
  static void debugReset() {
    _instance?._dispose();
    _instance = null;
  }

  final CallAudioBackend _platform;
  // A system call's backend (§4.8), while one exists.
  CallAudioBackend? _system;
  CallAudioBackend get _backend => _system ?? _platform;
  late final CoalescingRunner _runner = CoalescingRunner(_reconcile);

  /// The routes, as listed to apps (see [visibleAudioRoutes]).
  final StateStream<List<AudioRoute>> routes = StateStream(
    const [],
    equals: const ListEquality<AudioRoute>().equals,
  );

  /// The route in use, as the platform reports it.
  final StateStream<AudioRoute?> current = StateStream(null, distinct: true);

  /// Why the call's audio is interrupted now, or `null` when it isn't.
  final StateStream<CallInterruptionReason?> interruption = StateStream(
    null,
    distinct: true,
  );

  /// Whether the proximity sensor is on (as the platform confirmed).
  final StateStream<bool> proximity = StateStream(false, distinct: true);

  final Set<Object> _rooms = {};
  final Set<Object> _videoRooms = {};
  // Rooms that turned the proximity sensor off (RoomOptions.proximitySensor).
  final Set<Object> _noProximity = {};
  bool _proximityAsked = false;
  bool? _forcedSpeaker;
  AudioRoute? _userChoice;
  // A user's choice from before the backend changed, matched by kind (and
  // name) on the new backend's first listing: the route IDs differ.
  AudioRoute? _carriedChoice;
  Set<String> _known = {};
  final Map<String, int> _connectedAt = {};
  int _sequence = 0;
  bool? _defaultToSpeaker;
  StreamSubscription<void>? _changes;
  StreamSubscription<AudioInterruptionSignal>? _interruptions;
  StreamSubscription<AppLifecycleState>? _lifecycle;

  /// Whether this platform routes call audio (phones).
  bool get supported => _platform.supported;

  /// Whether a system call's backend routes call audio now (§4.8).
  bool get usesSystemCall => _system != null;

  /// The platform's backend, which a system call's backend builds on.
  CallAudioBackend get platformBackend => _platform;

  /// Whether the speaker is wanted when nothing is connected.
  bool get wantsSpeaker => _forcedSpeaker ?? _videoRooms.isNotEmpty;

  /// Whether a room turned the proximity sensor off, or a room has video.
  bool get _proximityAllowed => _noProximity.isEmpty && _videoRooms.isEmpty;

  /// Registers [room], which has joined. [speakerphone] (the room's
  /// option), when given, forces the speaker on or off. With
  /// [proximitySensor] `false`, the proximity sensor stays off while the
  /// room is joined.
  Future<void> join(
    Object room, {
    bool? speakerphone,
    bool proximitySensor = true,
  }) async {
    if (!supported) return;
    final first = _rooms.isEmpty;
    _rooms.add(room);
    if (!proximitySensor) _noProximity.add(room);
    if (speakerphone != null) {
      _forcedSpeaker = speakerphone;
      _userChoice = null;
    }
    if (first) {
      _listenToBackend();
      _lifecycle = callLifecycleSource().states.listen(
        _onLifecycle,
        onError: (Object _) {},
      );
      await _backend.activate();
    }
    await _runner.run();
  }

  void _listenToBackend() {
    _changes = _backend.changes.listen((_) => _runner.run());
    _interruptions = _backend.interruptions.listen(
      _onInterruption,
      onError: (Object _) {},
    );
  }

  Future<void> _stopListeningToBackend() async {
    await _changes?.cancel();
    _changes = null;
    await _interruptions?.cancel();
    _interruptions = null;
  }

  /// Hands call audio to a system call's [backend] (CallKit or Telecom,
  /// `docs/design.md` §4.8), or back to the platform's with `null`.
  ///
  /// With rooms joined, the old backend leaves call mode first (Telecom and
  /// CallKit own the mode, the focus and the session), the new one is
  /// followed, and the route is chosen again on the new backend's routes; a
  /// route the user picked carries over by kind. An interruption is taken
  /// back on the new backend: whoever owns the audio now decides.
  Future<void> useSystemCall(CallAudioBackend? backend) async {
    if (!supported || identical(backend, _system)) return;
    final joined = _rooms.isNotEmpty;
    if (joined) {
      await _stopListeningToBackend();
      try {
        await _backend.deactivate();
      } catch (error) {
        debugPrint('cloudflare_realtime: leaving call mode failed: $error');
      }
    }
    _carriedChoice = _userChoice ?? _carriedChoice;
    _userChoice = null;
    _system = backend;
    _known = {};
    _connectedAt.clear();
    _defaultToSpeaker = null;
    if (!joined) return;
    _listenToBackend();
    try {
      await _backend.activate();
    } catch (error) {
      debugPrint('cloudflare_realtime: entering call mode failed: $error');
    }
    if (interruption.value != null) {
      await _resume();
    } else {
      await _runner.run();
    }
  }

  /// Unregisters [room]. The last one out leaves call mode and resets the
  /// policy.
  Future<void> leave(Object room) async {
    if (!_rooms.remove(room)) return;
    _videoRooms.remove(room);
    _noProximity.remove(room);
    if (_rooms.isNotEmpty) {
      await _runner.run();
      return;
    }
    await _stopListeningToBackend();
    await _lifecycle?.cancel();
    _lifecycle = null;
    interruption.set(null);
    await _updateProximity();
    _forcedSpeaker = null;
    _userChoice = null;
    _carriedChoice = null;
    _known = {};
    _connectedAt.clear();
    _defaultToSpeaker = null;
    await _backend.deactivate();
  }

  /// [room] has video now (a camera or screen, sent or received). A room
  /// stays a video room until it leaves: the audio doesn't move back to the
  /// earpiece by itself.
  void videoStarted(Object room) {
    if (_rooms.contains(room) && _videoRooms.add(room)) {
      unawaited(_runner.run());
    }
  }

  /// Routes call audio to [route], until a new headset arrives or the route
  /// disappears.
  Future<void> select(AudioRoute route) async {
    _requireSupported();
    _userChoice = route;
    await _setBaseFor(route);
    if (!await _backend.select(route)) {
      _userChoice = null;
      unawaited(_runner.run());
      throw AudioRouteUnavailableException(route);
    }
    await _runner.run();
  }

  /// The speaker ([on]) or the earpiece, either way after a connected
  /// headset; clears a route the user picked.
  Future<void> setSpeakerphone(bool on) async {
    _requireSupported();
    _forcedSpeaker = on;
    _userChoice = null;
    await _runner.run();
  }

  /// Takes the call's audio back after an interruption that the platform
  /// didn't end by itself (Android: another app kept the audio focus).
  /// Completes with whether the call has its audio; `true` when it wasn't
  /// interrupted, and on platforms without interruptions.
  Future<bool> resume() async {
    if (!supported || interruption.value == null) return true;
    return _resume();
  }

  void _onInterruption(AudioInterruptionSignal signal) {
    if (_rooms.isEmpty) return;
    if (signal.began) {
      interruption.set(signal.reason ?? CallInterruptionReason.unknown);
    } else if (interruption.value != null) {
      // On iOS WebRTC re-activates the session after any interruption,
      // even one the system says not to resume, so the call takes its
      // audio back either way, the same on both phones.
      unawaited(_resume());
    }
  }

  // Back in the foreground: the platform doesn't always end an
  // interruption (iOS may not post the end; Android doesn't give the focus
  // back after a permanent loss), so the call takes its audio back then.
  void _onLifecycle(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && interruption.value != null) {
      unawaited(_resume());
    }
  }

  Future<bool> _resume() async {
    try {
      if (!await _backend.resume()) return false;
    } catch (error) {
      debugPrint('cloudflare_realtime: resuming call audio failed: $error');
      return false;
    }
    if (_rooms.isEmpty) return false;
    interruption.set(null);
    // The platform may have moved the audio meanwhile.
    await _runner.run();
    return true;
  }

  // The screen goes dark near the ear only when the phone is held there:
  // the earpiece, no video, and no room that turned it off.
  Future<void> _updateProximity() async {
    final want =
        _rooms.isNotEmpty &&
        _proximityAllowed &&
        current.value?.kind == AudioRouteKind.earpiece;
    if (want == _proximityAsked) return;
    _proximityAsked = want;
    try {
      final on = await _backend.setProximityMonitoring(want);
      if (!proximity.isClosed) proximity.set(on && want);
    } catch (error) {
      debugPrint('cloudflare_realtime: proximity sensor failed: $error');
      if (!proximity.isClosed) proximity.set(false);
    }
  }

  void _requireSupported() {
    if (!supported) {
      throw UnsupportedError(
        'Only phones route call audio; choose an output device instead.',
      );
    }
  }

  Future<void> _reconcile() async {
    if (_rooms.isEmpty) return;
    try {
      final visible = visibleAudioRoutes(await _backend.routes());
      if (_carriedChoice case final carried? when visible.isNotEmpty) {
        _carriedChoice = null;
        _userChoice ??= sameAudioRoute(visible, carried);
      }
      final ids = {for (final r in visible) r.id};
      final arrived = [
        for (final r in visible)
          if (r.kind.isExternal && !_known.contains(r.id)) r,
      ];
      for (final r in arrived) {
        _connectedAt[r.id] = ++_sequence;
      }
      // The first listing isn't an arrival: those were connected already.
      final firstListing = _known.isEmpty;
      final newHeadset = firstListing ? null : arrived.lastOrNull;
      if (newHeadset != null) _userChoice = null;
      if (_userChoice case final choice? when !ids.contains(choice.id)) {
        _userChoice = null;
      }
      _known = ids;
      routes.set(visible);

      final now = await _backend.current();
      final target = chooseAudioRoute(
        visible,
        current: now,
        userChoice: _userChoice,
        newHeadset: newHeadset,
        connectedAt: _connectedAt,
        wantSpeaker: wantsSpeaker,
      );
      await _setBaseFor(target);
      if (target != null && now?.id != target.id) {
        await _backend.select(target);
        current.set(await _backend.current());
      } else {
        current.set(now);
      }
      await _updateProximity();
    } catch (error, stack) {
      // Routing must never break a call; the next change tries again.
      debugPrint('cloudflare_realtime: call audio routing failed: $error');
      debugPrintStack(stackTrace: stack, maxFrames: 5);
    }
  }

  // iOS falls back to its base configuration's route (the speaker in video
  // chat, the receiver in voice chat) whenever the speaker override is
  // cleared, which is how the receiver and headsets are chosen. So the base
  // follows the route being chosen; for headsets, the call's default.
  Future<void> _setBaseFor(AudioRoute? target) async {
    final speaker = switch (target?.kind) {
      AudioRouteKind.speaker => true,
      AudioRouteKind.earpiece => false,
      _ => wantsSpeaker,
    };
    if (_defaultToSpeaker == speaker) return;
    _defaultToSpeaker = speaker;
    await _backend.setDefaultToSpeaker(speaker);
  }

  void _dispose() {
    unawaited(_changes?.cancel());
    unawaited(_interruptions?.cancel());
    unawaited(_lifecycle?.cancel());
    unawaited(routes.close());
    unawaited(current.close());
    unawaited(interruption.close());
    unawaited(proximity.close());
  }
}

/// The routes as listed to apps: what the platform will honour.
///
/// Neither phone reaches the earpiece while a Bluetooth headset is
/// connected, so the earpiece isn't listed then.
@visibleForTesting
List<AudioRoute> visibleAudioRoutes(List<AudioRoute> routes) {
  final bluetooth = routes.any((r) => r.kind == AudioRouteKind.bluetooth);
  final seen = <String>{};
  return List.unmodifiable([
    for (final r in routes)
      if (!(bluetooth && r.kind == AudioRouteKind.earpiece) && seen.add(r.id))
        r,
  ]);
}

/// The route among [routes] that is the same place as [route], from another
/// backend (whose IDs differ): the same kind, and the same name when both
/// have one; `null` when there is none.
@visibleForTesting
AudioRoute? sameAudioRoute(List<AudioRoute> routes, AudioRoute route) {
  final kind = routes.where((r) => r.kind == route.kind).toList();
  return kind.firstWhereOrNull(
        (r) => r.name.isNotEmpty && r.name == route.name,
      ) ??
      kind.firstOrNull;
}

/// The route the policy wants among [routes] (see [CallAudio]), or `null`
/// when there is none.
@visibleForTesting
AudioRoute? chooseAudioRoute(
  List<AudioRoute> routes, {
  required AudioRoute? current,
  required AudioRoute? userChoice,
  required AudioRoute? newHeadset,
  required Map<String, int> connectedAt,
  required bool wantSpeaker,
}) {
  if (routes.isEmpty) return null;
  AudioRoute? listed(AudioRoute? r) =>
      r == null ? null : routes.firstWhereOrNull((x) => x.id == r.id);
  if (listed(userChoice) case final choice?) return choice;
  if (listed(newHeadset) case final headset?) return headset;
  if (listed(current) case final now? when now.kind.isExternal) return now;
  final external = routes.where((r) => r.kind.isExternal).toList()
    ..sort(
      (a, b) => (connectedAt[b.id] ?? 0).compareTo(connectedAt[a.id] ?? 0),
    );
  if (external.isNotEmpty) return external.first;
  final speaker = routes.firstWhereOrNull(
    (r) => r.kind == AudioRouteKind.speaker,
  );
  final earpiece = routes.firstWhereOrNull(
    (r) => r.kind == AudioRouteKind.earpiece,
  );
  return wantSpeaker ? (speaker ?? earpiece) : (earpiece ?? speaker);
}
