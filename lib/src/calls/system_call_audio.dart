import 'dart:async';

import '../audio/audio_route.dart';
import '../audio/call_audio_backend.dart';
import 'system_call_backend.dart';

/// Call audio while a system call exists (`docs/design.md` §4.8): the
/// [CallAudioBackend] that `SystemCalls` gives `CallAudio`, so the same
/// route policy runs while CallKit or Telecom owns the audio.
///
/// - **Activation** is the system's: [activate] and [deactivate] do nothing
///   (CallKit activates the session and reports it; Telecom sets the mode
///   and holds the focus).
/// - **Routes:** on Android, Telecom's endpoints, selected with
///   `requestEndpointChange` (Core-Telecom forbids `setCommunicationDevice`
///   during a call it manages); on iOS, the platform's routes as before
///   (`AVAudioSession` overrides work during a CallKit call).
/// - **Interruptions** come from the call: on hold, or (iOS) its audio
///   deactivated while it isn't held; [resume] takes the call off hold.
/// - The base configuration (iOS) and the proximity sensor stay the
///   platform's.
///
/// Internal.
class SystemCallAudioBackend implements CallAudioBackend {
  /// Creates the backend over the platform's and the system call's
  /// backends. `callId` is the call whose endpoints are used (the current
  /// one), `isHeld` whether it is on hold; `endpointChanges` fires when its
  /// endpoints change, and `interruptions` are the call's.
  SystemCallAudioBackend({
    required CallAudioBackend platform,
    required SystemCallBackend system,
    required String? Function() callId,
    required bool Function() isHeld,
    required Stream<void> endpointChanges,
    required Stream<AudioInterruptionSignal> interruptions,
  }) : _platform = platform,
       _system = system,
       _callId = callId,
       _isHeld = isHeld,
       _endpointChanges = endpointChanges,
       _interruptions = interruptions;

  final CallAudioBackend _platform;
  final SystemCallBackend _system;
  final String? Function() _callId;
  final bool Function() _isHeld;
  final Stream<void> _endpointChanges;
  final Stream<AudioInterruptionSignal> _interruptions;

  bool get _endpoints => _system.routesThroughEndpoints;

  @override
  bool get supported => true;

  @override
  Future<void> activate() async {}

  @override
  Future<void> deactivate() async {}

  @override
  Future<void> setDefaultToSpeaker(bool speaker) =>
      _platform.setDefaultToSpeaker(speaker);

  @override
  Future<List<AudioRoute>> routes() async {
    if (!_endpoints) return _platform.routes();
    final id = _callId();
    if (id == null) return const [];
    return (await _system.endpoints(id))?.routes ?? const [];
  }

  @override
  Future<AudioRoute?> current() async {
    if (!_endpoints) return _platform.current();
    final id = _callId();
    if (id == null) return null;
    return (await _system.endpoints(id))?.current;
  }

  @override
  Future<bool> select(AudioRoute route) async {
    if (!_endpoints) return _platform.select(route);
    final id = _callId();
    if (id == null) return false;
    return _system.selectEndpoint(id, route.id);
  }

  @override
  Stream<void> get changes => _endpoints
      ? _merge(_platform.changes, _endpointChanges)
      : _platform.changes;

  @override
  Future<bool> setProximityMonitoring(bool enabled) =>
      _platform.setProximityMonitoring(enabled);

  @override
  Future<bool> resume() async {
    final id = _callId();
    if (id == null || !_isHeld()) return true;
    return _system.setHeld(id, onHold: false);
  }

  @override
  Stream<AudioInterruptionSignal> get interruptions => _interruptions;

  static Stream<void> _merge(Stream<void> a, Stream<void> b) =>
      Stream<void>.multi((listener) {
        final subscriptions = [
          a.listen(listener.add, onError: (Object _) {}),
          b.listen(listener.add, onError: (Object _) {}),
        ];
        listener.onCancel = () =>
            Future.wait([for (final s in subscriptions) s.cancel()]);
      }, isBroadcast: true);
}
