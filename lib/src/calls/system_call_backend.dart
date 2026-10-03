import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../audio/audio_route.dart';
import '../audio/call_audio_backend.dart' show audioRouteFromMap;
import '../audio/platform.dart';
import 'system_call_types.dart';

// =============================================================================
// The native contract (docs/design.md §4.8, "The native contract")
// =============================================================================
//
// Channels:
//   MethodChannel  dev.kammcs.cloudflare_realtime/system_calls
//   EventChannel   dev.kammcs.cloudflare_realtime/system_calls_events
//
// A call map (both ways; Dart sends only the first six keys):
//   {id: String (a UUID, lowercase), handle: String,
//    handleType: "generic" | "phoneNumber" | "emailAddress",
//    displayName: String?, video: bool, outgoing: bool,
//    state: "ringing" | "dialing" | "connecting" | "active" | "held" | "ended",
//    muted: bool, payload: Map<String, Object?>?}
// A route map: {id: String, kind: "speaker" | "earpiece" | "wiredHeadset" |
//   "bluetooth" | "usb" | "other", name: String} (as on call_audio).
//
// Methods (arguments → result). Errors are PlatformExceptions whose code is
// one of "filtered", "alreadyExists", "notFound", "unavailable", "failed".
//   configure          SystemCallsOptions.toMap()      → bool (supported)
//   reportIncomingCall call map                       → null
//   startOutgoingCall  call map                       → null
//   reportConnecting   {id}                           → null
//   reportConnected    {id}                           → null
//   answer             {id}                           → bool (accepted)
//   end                {id, reason}                   → bool (accepted)
//   setHeld            {id, onHold: bool}             → bool (accepted)
//   setMuted           {id, muted: bool}              → bool (accepted)
//   update             {id, displayName?, video?}     → null
//   activeCalls        null                           → List<call map>
//   endpoints          {id}                → {routes: [route], current: route?}
//                                            or null (iOS: no endpoints)
//   selectEndpoint     {id, routeId}                  → bool (accepted)
//   registerVoipPush   null                → String? (the token, hex; iOS)
//   unregisterVoipPush null                           → null
// `reason` is a SystemCallEndReason name.
//
// Events (maps with an "event" key):
//   {event: reported, call: call map}   a call the native side reported by
//                                       itself (a VoIP push, iOS)
//   {event: answered, id}
//   {event: ended, id, reason}
//   {event: held, id, onHold: bool}
//   {event: muted, id, muted: bool}
//   {event: dtmf, id, digits: String}   iOS
//   {event: audioActivated}             iOS didActivate; Android: the call
//   {event: audioDeactivated}           went active / inactive
//   {event: endpointsChanged, id}       Android: re-read `endpoints`
//   {event: voipToken, token: String?}  iOS; null when invalidated
//
// Rules:
// - answer, end, setHeld and setMuted are requests. Their outcome always
//   comes back as the event, whoever started it (the app or the system's
//   UI), once per real change.
// - Events raised while Dart doesn't listen are buffered, in order, and
//   delivered on listen. `activeCalls` is the state for an engine that
//   starts later.
// - The call registry is process-wide: every attached engine's event sink
//   gets every event (on Android a background engine, such as an FCM
//   handler's, may report the call the UI engine then answers).
// =============================================================================

/// A system call as the native code describes it. Internal.
@immutable
class SystemCallInfo {
  /// Creates a description.
  const SystemCallInfo({
    required this.id,
    required this.handle,
    this.displayName,
    this.video = false,
    this.outgoing = false,
    this.state = SystemCallState.ringing,
    this.muted = false,
    this.payload = const {},
  });

  /// The call's UUID.
  final String id;

  /// Who it is with.
  final CallHandle handle;

  /// The name the system shows.
  final String? displayName;

  /// Whether it is a video call.
  final bool video;

  /// Whether the app started it.
  final bool outgoing;

  /// Where it is.
  final SystemCallState state;

  /// Whether the system's mute is on.
  final bool muted;

  /// What the VoIP push carried beyond the call's fields (iOS).
  final Map<String, Object?> payload;

  /// The map sent to the native code for a new call.
  Map<String, Object?> toMap() => {
    'id': id,
    'handle': handle.value,
    'handleType': handle.type.name,
    'displayName': displayName,
    'video': video,
    'outgoing': outgoing,
  };

  @override
  String toString() =>
      'SystemCallInfo($id, $handle, ${state.name}'
      '${outgoing ? ', outgoing' : ''}${video ? ', video' : ''})';
}

/// A [SystemCallInfo] from a native call map, or `null` when malformed.
@visibleForTesting
SystemCallInfo? systemCallInfoFromMap(Map<Object?, Object?> map) {
  final id = map['id'];
  final handle = map['handle'];
  if (id is! String || id.isEmpty || handle is! String) return null;
  final payload = map['payload'];
  return SystemCallInfo(
    id: id,
    handle: CallHandle(
      handle,
      type:
          CallHandleType.values.asNameMap()[map['handleType']] ??
          CallHandleType.generic,
    ),
    displayName: map['displayName'] is String
        ? map['displayName']! as String
        : null,
    video: map['video'] == true,
    outgoing: map['outgoing'] == true,
    state:
        SystemCallState.values.asNameMap()[map['state']] ??
        SystemCallState.ringing,
    muted: map['muted'] == true,
    payload: payload is Map
        ? {
            for (final e in payload.entries)
              if (e.key is String) e.key as String: e.value,
          }
        : const {},
  );
}

/// The audio endpoints of a system call (Android Telecom). Internal.
@immutable
class SystemCallEndpoints {
  /// Creates the endpoints.
  const SystemCallEndpoints(this.routes, this.current);

  /// The endpoints the call can use.
  final List<AudioRoute> routes;

  /// The one in use.
  final AudioRoute? current;
}

/// Something the system did to a call, from the native code. Internal.
@immutable
sealed class SystemCallSignal {
  const SystemCallSignal();
}

/// The native code reported a call by itself (a VoIP push, iOS).
final class CallReportedSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallReportedSignal(this.call);

  /// The call.
  final SystemCallInfo call;
}

/// The call [id] was answered.
final class CallAnsweredSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallAnsweredSignal(this.id);

  /// The call.
  final String id;

  @override
  bool operator ==(Object other) =>
      other is CallAnsweredSignal && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

/// The call [id] ended, for [reason].
final class CallEndedSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallEndedSignal(this.id, this.reason);

  /// The call.
  final String id;

  /// Why.
  final SystemCallEndReason reason;

  @override
  bool operator ==(Object other) =>
      other is CallEndedSignal && other.id == id && other.reason == reason;

  @override
  int get hashCode => Object.hash(id, reason);
}

/// The call [id] was put on hold ([onHold]) or taken off it.
final class CallHeldSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallHeldSignal(this.id, {required this.onHold});

  /// The call.
  final String id;

  /// Whether it is on hold now.
  final bool onHold;

  @override
  bool operator ==(Object other) =>
      other is CallHeldSignal && other.id == id && other.onHold == onHold;

  @override
  int get hashCode => Object.hash(id, onHold);
}

/// The system's mute for the call [id] changed.
final class CallMutedSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallMutedSignal(this.id, {required this.muted});

  /// The call.
  final String id;

  /// Whether it is muted now.
  final bool muted;

  @override
  bool operator ==(Object other) =>
      other is CallMutedSignal && other.id == id && other.muted == muted;

  @override
  int get hashCode => Object.hash(id, muted);
}

/// The system's keypad sent [digits] for the call [id] (iOS).
final class CallDtmfSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallDtmfSignal(this.id, this.digits);

  /// The call.
  final String id;

  /// The keys pressed.
  final String digits;
}

/// The system activated ([activated]) or deactivated the call audio.
final class CallAudioSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallAudioSignal({required this.activated});

  /// Whether the audio is active now.
  final bool activated;
}

/// The audio endpoints of the call [id] changed (Android).
final class CallEndpointsSignal extends SystemCallSignal {
  /// Creates the signal.
  const CallEndpointsSignal(this.id);

  /// The call.
  final String id;
}

/// The VoIP push token changed (iOS); `null` when invalidated.
final class VoipTokenSignal extends SystemCallSignal {
  /// Creates the signal.
  const VoipTokenSignal(this.token);

  /// The token, hex.
  final String? token;
}

/// A [SystemCallSignal] from a native event map, or `null` for anything
/// else.
@visibleForTesting
SystemCallSignal? systemCallSignalFromMap(Map<Object?, Object?> map) {
  final id = map['id'];
  final hasId = id is String && id.isNotEmpty;
  switch (map['event']) {
    case 'reported':
      final call = map['call'];
      final info = call is Map ? systemCallInfoFromMap(call) : null;
      return info == null ? null : CallReportedSignal(info);
    case 'answered' when hasId:
      return CallAnsweredSignal(id);
    case 'ended' when hasId:
      return CallEndedSignal(
        id,
        SystemCallEndReason.values.asNameMap()[map['reason']] ??
            SystemCallEndReason.failed,
      );
    case 'held' when hasId:
      return CallHeldSignal(id, onHold: map['onHold'] == true);
    case 'muted' when hasId:
      return CallMutedSignal(id, muted: map['muted'] == true);
    case 'dtmf' when hasId && map['digits'] is String:
      return CallDtmfSignal(id, map['digits']! as String);
    case 'audioActivated':
      return const CallAudioSignal(activated: true);
    case 'audioDeactivated':
      return const CallAudioSignal(activated: false);
    case 'endpointsChanged' when hasId:
      return CallEndpointsSignal(id);
    case 'voipToken':
      final token = map['token'];
      return VoipTokenSignal(
        token is String && token.isNotEmpty ? token : null,
      );
  }
  return null;
}

/// The platform side of system calls (`docs/design.md` §4.8): CallKit and
/// PushKit on iOS, Core-Telecom on Android. It decides nothing;
/// `SystemCalls` does. See the native contract at the top of this file.
///
/// Internal.
abstract interface class SystemCallBackend {
  /// Whether a system call UI is behind this backend (`false`: desktops,
  /// the web, and phones whose native side is missing or refused).
  bool get isSystem;

  /// Whether call audio is routed through the call's endpoints while a
  /// system call exists (Android Telecom forbids `setCommunicationDevice`).
  bool get routesThroughEndpoints;

  /// Whether the system activates the call's audio session (iOS CallKit):
  /// the app must not activate it itself while a system call exists.
  bool get systemActivatesAudio;

  /// Whether VoIP pushes exist here (iOS).
  bool get supportsVoipPush;

  /// Sets the system's presentation of calls up. Completes with whether
  /// system calls work here.
  Future<bool> configure(SystemCallsOptions config);

  /// Shows [call] as an incoming call.
  Future<void> reportIncomingCall(SystemCallInfo call);

  /// Tells the system the app starts [call].
  Future<void> startOutgoingCall(SystemCallInfo call);

  /// The outgoing call [id] started connecting.
  Future<void> reportConnecting(String id);

  /// The outgoing call [id] connected (the other side answered).
  Future<void> reportConnected(String id);

  /// Asks to answer the call [id].
  Future<bool> answer(String id);

  /// Asks to end the call [id] for [reason].
  Future<bool> end(String id, SystemCallEndReason reason);

  /// Asks to put the call [id] on hold or take it off.
  Future<bool> setHeld(String id, {required bool onHold});

  /// Asks to mute or unmute the call [id] in the system's UI.
  Future<bool> setMuted(String id, {required bool muted});

  /// Changes what the system shows for the call [id].
  Future<void> update(String id, {String? displayName, bool? video});

  /// The calls the system has now.
  Future<List<SystemCallInfo>> activeCalls();

  /// The audio endpoints of the call [id], or `null` without endpoints.
  Future<SystemCallEndpoints?> endpoints(String id);

  /// Asks for the endpoint [routeId] for the call [id].
  Future<bool> selectEndpoint(String id, String routeId);

  /// Registers for VoIP pushes; completes with the token if known.
  Future<String?> registerVoipPush();

  /// Unregisters from VoIP pushes.
  Future<void> unregisterVoipPush();

  /// What the system did.
  Stream<SystemCallSignal> get signals;
}

/// Creates a [SystemCallBackend]; the platform's by default.
typedef SystemCallBackendFactory = SystemCallBackend Function();

/// **Tests only:** replaces the platform backend. Reset it to `null`
/// afterwards, with `SystemCalls.debugReset`.
@visibleForTesting
SystemCallBackendFactory? debugSystemCallBackendFactory;

/// Creates the backend for this platform (or
/// [debugSystemCallBackendFactory]'s).
SystemCallBackend createSystemCallBackend() =>
    (debugSystemCallBackendFactory ?? _platformBackend)();

SystemCallBackend _platformBackend() =>
    isPhone ? MethodChannelSystemCallBackend() : LocalSystemCallBackend();

/// Desktops, the web, and phones without the native side: no system UI.
///
/// It still keeps the calls and answers every request with its event, so
/// an app's call flow (report, answer, hold, mute, end) behaves the same
/// as on phones, only without the system's call UI.
class LocalSystemCallBackend implements SystemCallBackend {
  /// Creates the backend.
  LocalSystemCallBackend();

  final Map<String, SystemCallInfo> _calls = {};
  final StreamController<SystemCallSignal> _signals =
      StreamController.broadcast();

  @override
  bool get isSystem => false;

  @override
  bool get routesThroughEndpoints => false;

  @override
  bool get systemActivatesAudio => false;

  @override
  bool get supportsVoipPush => false;

  @override
  Future<bool> configure(SystemCallsOptions config) async => false;

  @override
  Future<void> reportIncomingCall(SystemCallInfo call) async => _add(call);

  @override
  Future<void> startOutgoingCall(SystemCallInfo call) async => _add(call);

  void _add(SystemCallInfo call) {
    if (_calls.containsKey(call.id)) {
      throw const SystemCallException(SystemCallErrorCode.alreadyExists);
    }
    _calls[call.id] = call;
  }

  @override
  Future<void> reportConnecting(String id) async => _require(id);

  @override
  Future<void> reportConnected(String id) async => _require(id);

  @override
  Future<bool> answer(String id) async {
    if (!_calls.containsKey(id)) return false;
    _emit(CallAnsweredSignal(id));
    return true;
  }

  @override
  Future<bool> end(String id, SystemCallEndReason reason) async {
    if (_calls.remove(id) == null) return false;
    _emit(CallEndedSignal(id, reason));
    return true;
  }

  @override
  Future<bool> setHeld(String id, {required bool onHold}) async {
    if (!_calls.containsKey(id)) return false;
    _emit(CallHeldSignal(id, onHold: onHold));
    return true;
  }

  @override
  Future<bool> setMuted(String id, {required bool muted}) async {
    if (!_calls.containsKey(id)) return false;
    _emit(CallMutedSignal(id, muted: muted));
    return true;
  }

  @override
  Future<void> update(String id, {String? displayName, bool? video}) async =>
      _require(id);

  @override
  Future<List<SystemCallInfo>> activeCalls() async => const [];

  @override
  Future<SystemCallEndpoints?> endpoints(String id) async => null;

  @override
  Future<bool> selectEndpoint(String id, String routeId) async => false;

  @override
  Future<String?> registerVoipPush() async => null;

  @override
  Future<void> unregisterVoipPush() async {}

  @override
  Stream<SystemCallSignal> get signals => _signals.stream;

  void _require(String id) {
    if (!_calls.containsKey(id)) {
      throw const SystemCallException(SystemCallErrorCode.notFound);
    }
  }

  // Asynchronously, like the platforms' events.
  void _emit(SystemCallSignal signal) =>
      scheduleMicrotask(() => _signals.add(signal));
}

/// The phones' backend: this package's native code (CallKit and PushKit on
/// iOS, Core-Telecom on Android), over the channels in the contract above.
class MethodChannelSystemCallBackend implements SystemCallBackend {
  /// Creates the backend.
  MethodChannelSystemCallBackend();

  static const _methods = MethodChannel(
    'dev.kammcs.cloudflare_realtime/system_calls',
  );
  static const _events = EventChannel(
    'dev.kammcs.cloudflare_realtime/system_calls_events',
  );

  @override
  bool get isSystem => true;

  @override
  bool get routesThroughEndpoints => isAndroid;

  @override
  bool get systemActivatesAudio => isIOS;

  @override
  bool get supportsVoipPush => isIOS;

  @override
  Future<bool> configure(SystemCallsOptions config) async {
    try {
      return await _methods.invokeMethod<bool>('configure', config.toMap()) ??
          false;
    } on MissingPluginException {
      // The native side isn't there (yet): no system calls.
      return false;
    }
  }

  @override
  Future<void> reportIncomingCall(SystemCallInfo call) =>
      _call<void>('reportIncomingCall', call.toMap());

  @override
  Future<void> startOutgoingCall(SystemCallInfo call) =>
      _call<void>('startOutgoingCall', call.toMap());

  @override
  Future<void> reportConnecting(String id) =>
      _call<void>('reportConnecting', {'id': id});

  @override
  Future<void> reportConnected(String id) =>
      _call<void>('reportConnected', {'id': id});

  @override
  Future<bool> answer(String id) async =>
      await _call<bool>('answer', {'id': id}) ?? false;

  @override
  Future<bool> end(String id, SystemCallEndReason reason) async =>
      await _call<bool>('end', {'id': id, 'reason': reason.name}) ?? false;

  @override
  Future<bool> setHeld(String id, {required bool onHold}) async =>
      await _call<bool>('setHeld', {'id': id, 'onHold': onHold}) ?? false;

  @override
  Future<bool> setMuted(String id, {required bool muted}) async =>
      await _call<bool>('setMuted', {'id': id, 'muted': muted}) ?? false;

  @override
  Future<void> update(String id, {String? displayName, bool? video}) =>
      _call<void>('update', {
        'id': id,
        'displayName': ?displayName,
        'video': ?video,
      });

  @override
  Future<List<SystemCallInfo>> activeCalls() async {
    final list = await _call<List<Object?>>('activeCalls') ?? const [];
    return [
      for (final entry in list)
        if (entry is Map) ?systemCallInfoFromMap(entry),
    ];
  }

  @override
  Future<SystemCallEndpoints?> endpoints(String id) async {
    final map = await _call<Map<Object?, Object?>>('endpoints', {'id': id});
    if (map == null) return null;
    final routes = map['routes'];
    final current = map['current'];
    return SystemCallEndpoints([
      if (routes is List)
        for (final r in routes)
          if (r is Map) ?audioRouteFromMap(r),
    ], current is Map ? audioRouteFromMap(current) : null);
  }

  @override
  Future<bool> selectEndpoint(String id, String routeId) async =>
      await _call<bool>('selectEndpoint', {'id': id, 'routeId': routeId}) ??
      false;

  @override
  Future<String?> registerVoipPush() => _call<String>('registerVoipPush');

  @override
  Future<void> unregisterVoipPush() => _call<void>('unregisterVoipPush');

  @override
  late final Stream<SystemCallSignal> signals = _events
      .receiveBroadcastStream()
      .map((event) => event is Map ? systemCallSignalFromMap(event) : null)
      .where((signal) => signal != null)
      .cast<SystemCallSignal>()
      .asBroadcastStream();

  static Future<T?> _call<T>(String method, [Object? arguments]) async {
    try {
      return await _methods.invokeMethod<T>(method, arguments);
    } on PlatformException catch (e) {
      throw systemCallExceptionFrom(e);
    }
  }
}

/// A [SystemCallException] for the native code's [PlatformException].
@visibleForTesting
SystemCallException systemCallExceptionFrom(PlatformException e) =>
    SystemCallException(
      SystemCallErrorCode.values.asNameMap()[e.code] ??
          SystemCallErrorCode.failed,
      e.message,
    );
