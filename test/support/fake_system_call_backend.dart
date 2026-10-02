import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/calls/system_call_backend.dart';

/// A scriptable system call service (CallKit or Telecom) for tests.
///
/// It keeps the calls it was given and, like the platforms, answers each
/// accepted request with its event ([echo]). [system] plays the system's
/// UI: answering, ending, holding or muting from the lock screen, a
/// headset or a car. [calls] records every request, as `method id args`.
class FakeSystemCallBackend implements SystemCallBackend {
  FakeSystemCallBackend({
    this.isSystem = true,
    this.routesThroughEndpoints = false,
    this.systemActivatesAudio = false,
    this.supportsVoipPush = false,
    this.configureResult = true,
  });

  @override
  bool isSystem;

  @override
  bool routesThroughEndpoints;

  @override
  bool systemActivatesAudio;

  @override
  bool supportsVoipPush;

  /// What [configure] completes with.
  bool configureResult;

  /// Whether accepted requests are answered with their events.
  bool echo = true;

  /// When set, the next report or start throws it.
  SystemCallException? refuseNext;

  /// Whether answer, end, setHeld and setMuted are refused.
  bool refuseRequests = false;

  /// The calls the system has.
  final Map<String, SystemCallInfo> active = {};

  /// Calls the system had before Dart started (a VoIP push).
  List<SystemCallInfo> preexisting = [];

  /// The requests, in order.
  final List<String> calls = [];

  /// The endpoints, per call (Android).
  List<AudioRoute> endpointsNow = const [];
  AudioRoute? currentEndpoint;

  /// The token [registerVoipPush] completes with.
  String? token;

  SystemCallsConfig? config;

  final StreamController<SystemCallSignal> _signals =
      StreamController.broadcast();

  /// The system's UI (or the platform) does something.
  void system(SystemCallSignal signal) {
    if (signal case CallEndedSignal(:final id)) active.remove(id);
    _signals.add(signal);
  }

  /// The system's endpoints change.
  void setEndpoints(List<AudioRoute> routes, AudioRoute? current, String id) {
    endpointsNow = routes;
    currentEndpoint = current;
    _signals.add(CallEndpointsSignal(id));
  }

  void _emit(SystemCallSignal signal) {
    if (echo) scheduleMicrotask(() => _signals.add(signal));
  }

  @override
  Future<bool> configure(SystemCallsConfig config) async {
    calls.add('configure');
    this.config = config;
    return configureResult;
  }

  @override
  Future<void> reportIncomingCall(SystemCallInfo call) async {
    calls.add('reportIncomingCall ${call.id}');
    _add(call);
  }

  @override
  Future<void> startOutgoingCall(SystemCallInfo call) async {
    calls.add('startOutgoingCall ${call.id}');
    _add(call);
  }

  void _add(SystemCallInfo call) {
    if (refuseNext case final error?) {
      refuseNext = null;
      throw error;
    }
    active[call.id] = call;
  }

  @override
  Future<void> reportConnecting(String id) async =>
      calls.add('reportConnecting $id');

  @override
  Future<void> reportConnected(String id) async =>
      calls.add('reportConnected $id');

  @override
  Future<bool> answer(String id) async {
    calls.add('answer $id');
    if (refuseRequests || !active.containsKey(id)) return false;
    _emit(CallAnsweredSignal(id));
    return true;
  }

  @override
  Future<bool> end(String id, SystemCallEndReason reason) async {
    calls.add('end $id ${reason.name}');
    if (refuseRequests || !active.containsKey(id)) return false;
    active.remove(id);
    _emit(CallEndedSignal(id, reason));
    return true;
  }

  @override
  Future<bool> setHeld(String id, {required bool onHold}) async {
    calls.add('setHeld $id $onHold');
    if (refuseRequests || !active.containsKey(id)) return false;
    _emit(CallHeldSignal(id, onHold: onHold));
    return true;
  }

  @override
  Future<bool> setMuted(String id, {required bool muted}) async {
    calls.add('setMuted $id $muted');
    if (refuseRequests || !active.containsKey(id)) return false;
    _emit(CallMutedSignal(id, muted: muted));
    return true;
  }

  @override
  Future<void> update(String id, {String? displayName, bool? video}) async =>
      calls.add('update $id $displayName $video');

  @override
  Future<List<SystemCallInfo>> activeCalls() async {
    for (final call in preexisting) {
      active[call.id] = call;
    }
    return preexisting;
  }

  @override
  Future<SystemCallEndpoints?> endpoints(String id) async =>
      routesThroughEndpoints
      ? SystemCallEndpoints(endpointsNow, currentEndpoint)
      : null;

  @override
  Future<bool> selectEndpoint(String id, String routeId) async {
    calls.add('selectEndpoint $id $routeId');
    final route = endpointsNow.where((r) => r.id == routeId).firstOrNull;
    if (route == null) return false;
    currentEndpoint = route;
    if (echo) scheduleMicrotask(() => _signals.add(CallEndpointsSignal(id)));
    return true;
  }

  @override
  Future<String?> registerVoipPush() async {
    calls.add('registerVoipPush');
    return token;
  }

  @override
  Future<void> unregisterVoipPush() async => calls.add('unregisterVoipPush');

  @override
  Stream<SystemCallSignal> get signals => _signals.stream;
}
