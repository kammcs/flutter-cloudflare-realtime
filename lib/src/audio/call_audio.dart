import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'audio_route.dart';
import 'call_audio_backend.dart';

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
/// Internal: the Room exposes it.
class CallAudio {
  CallAudio._(this._backend);

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

  final CallAudioBackend _backend;
  late final CoalescingRunner _runner = CoalescingRunner(_reconcile);

  /// The routes, as listed to apps (see [visibleAudioRoutes]).
  final StateStream<List<AudioRoute>> routes = StateStream(
    const [],
    equals: const ListEquality<AudioRoute>().equals,
  );

  /// The route in use, as the platform reports it.
  final StateStream<AudioRoute?> current = StateStream(null, distinct: true);

  final Set<Object> _rooms = {};
  final Set<Object> _videoRooms = {};
  bool? _forcedSpeaker;
  AudioRoute? _userChoice;
  Set<String> _known = {};
  final Map<String, int> _connectedAt = {};
  int _sequence = 0;
  bool? _defaultToSpeaker;
  StreamSubscription<void>? _changes;

  /// Whether this platform routes call audio (phones).
  bool get supported => _backend.supported;

  /// Whether the speaker is wanted when nothing is connected.
  bool get wantsSpeaker => _forcedSpeaker ?? _videoRooms.isNotEmpty;

  /// Registers [room], which has joined. [speakerphone] (the room's
  /// option), when given, forces the speaker on or off.
  Future<void> join(Object room, {bool? speakerphone}) async {
    if (!supported) return;
    final first = _rooms.isEmpty;
    _rooms.add(room);
    if (speakerphone != null) {
      _forcedSpeaker = speakerphone;
      _userChoice = null;
    }
    if (first) {
      _changes = _backend.changes.listen((_) => _runner.run());
      await _backend.activate();
    }
    await _runner.run();
  }

  /// Unregisters [room]. The last one out leaves call mode and resets the
  /// policy.
  Future<void> leave(Object room) async {
    if (!_rooms.remove(room)) return;
    _videoRooms.remove(room);
    if (_rooms.isNotEmpty) {
      await _runner.run();
      return;
    }
    await _changes?.cancel();
    _changes = null;
    _forcedSpeaker = null;
    _userChoice = null;
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
    unawaited(routes.close());
    unawaited(current.close());
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
