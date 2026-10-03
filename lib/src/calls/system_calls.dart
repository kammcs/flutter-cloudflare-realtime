/// @docImport '../room/room.dart';
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../audio/call_audio.dart';
import '../audio/call_audio_backend.dart' show AudioInterruptionSignal;
import '../audio/call_interruption.dart';
import '../session/track_name.dart' show generateTrackName;
import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'system_call_audio.dart';
import 'system_call_backend.dart';
import 'system_call_types.dart';

/// The phone's own call UI for the app's calls: CallKit on iOS, Android's
/// Telecom (through Core-Telecom) on Android (`docs/design.md` §4.8).
///
/// With it, a call shows on the lock screen and in the system's call UI,
/// headset, car and watch buttons answer, end, hold and mute it, and the
/// system treats it like a phone call (another call holds it instead of
/// cutting it off). These are primitives: the app decides when a call
/// exists, from its own signaling or a push, and what joining it means.
///
/// ```dart
/// final calls = SystemCalls.instance;
/// await calls.configure(const SystemCallsConfig());
/// final call = await calls.reportIncomingCall(
///   handle: const CallHandle('ada'),
///   displayName: 'Ada',
///   video: true,
/// );
/// await call.stateChanges.firstWhere((s) => s == SystemCallState.active);
/// final room = await realtime.join(roomId, ...);
/// room.attachSystemCall(call); // mute in sync, leave when it ends
/// ```
///
/// Everywhere else (desktops, the web, and phones where the system refuses)
/// [supported] is `false` and the calls are kept in Dart only: every
/// request is answered with its event, so the app's call flow is the same,
/// without a system UI.
///
/// **One instance for the app**, like the system's call service.
class SystemCalls {
  SystemCalls._(this._platform);

  static SystemCalls? _instance;

  /// The app's instance.
  static SystemCalls get instance =>
      _instance ??= SystemCalls._(createSystemCallBackend());

  /// **Tests only:** forgets the instance (and its backend), so the next
  /// one is created afresh from [debugSystemCallBackendFactory].
  @visibleForTesting
  static void debugReset() {
    _instance?._dispose();
    _instance = null;
  }

  final SystemCallBackend _platform;
  SystemCallBackend? _backend;
  bool _supported = false;
  final Map<String, SystemCall> _calls = {};
  final StateStream<List<SystemCall>> _list = StateStream(const []);
  final StreamController<SystemCallEvent> _events =
      StreamController.broadcast();
  StreamSubscription<SystemCallSignal>? _signals;
  // Call audio while a system call exists (§4.8): its interruptions and
  // endpoint changes.
  final StreamController<AudioInterruptionSignal> _audioInterruptions =
      StreamController.broadcast();
  final StreamController<void> _endpointChanges = StreamController.broadcast();
  SystemCallAudioBackend? _audio;
  late final CoalescingRunner _audioRunner = CoalescingRunner(_applyAudio);
  final StateStream<String?> _voipToken = StateStream(null, distinct: true);

  /// VoIP pushes (iOS PushKit): an incoming call that wakes the app.
  late final VoipPush voipPush = VoipPush._(this);

  /// Whether the phone's own call UI shows the app's calls: `true` after
  /// [configure] on iOS and Android 8+ (with the native side present).
  bool get supported => _supported;

  /// Whether [configure] has completed.
  bool get isConfigured => _backend != null;

  /// The calls that exist now, oldest first. Ended calls are removed.
  List<SystemCall> get calls => _list.value;

  /// [calls], replaying the current list, then each change.
  Stream<List<SystemCall>> get callsChanges => _list.stream;

  /// The call with [id], if it exists.
  SystemCall? call(String id) => _calls[id.toLowerCase()];

  /// What happens to the calls, as it happens: from the app's requests and
  /// from the system's UI alike. A broadcast stream.
  Stream<SystemCallEvent> get events => _events.stream;

  /// Sets the system's call UI up for this app, and completes with
  /// [supported]. Call it once at startup, before reporting calls; calling
  /// it again updates [config].
  ///
  /// Calls the system already has are in [calls] when it completes (and
  /// emitted as [SystemCallAddedEvent]): on iOS, a VoIP push that launched
  /// the app reports its call before Dart runs.
  Future<bool> configure([
    SystemCallsConfig config = const SystemCallsConfig(),
  ]) async {
    if (_backend != null) {
      if (_supported) await _platform.configure(config);
      return _supported;
    }
    var ok = false;
    try {
      ok = await _platform.configure(config);
    } catch (error) {
      debugPrint('cloudflare_realtime: system calls unavailable: $error');
    }
    _supported = ok && _platform.isSystem;
    final backend = _supported || !_platform.isSystem
        ? _platform
        : LocalSystemCallBackend();
    _backend = backend;
    _signals = backend.signals.listen(_onSignal, onError: (Object _) {});
    try {
      for (final info in await backend.activeCalls()) {
        // A buffered `reported` event may have added it already.
        if (info.state != SystemCallState.ended &&
            !_calls.containsKey(info.id)) {
          _added(info);
        }
      }
    } catch (error) {
      debugPrint('cloudflare_realtime: listing system calls failed: $error');
    }
    return _supported;
  }

  /// Shows an incoming call in the system's UI (the lock screen, a banner,
  /// a full-screen notification on Android), from the app's signaling or a
  /// push. Completes with the call, [SystemCallState.ringing]; answering it
  /// (here or in the system's UI) makes it [SystemCallState.active].
  ///
  /// [id] must be a UUID (one is generated when `null`); the caller's
  /// signaling usually carries it, so that both sides and a VoIP push
  /// agree. Throws a [SystemCallException] when the system refuses the call
  /// ([SystemCallErrorCode.filtered]: Do Not Disturb or the block list), and
  /// a [StateError] before [configure].
  ///
  /// On Android, call it from the foreground or from a high-priority FCM
  /// message: Android lets the call's foreground service start from the
  /// background only then.
  Future<SystemCall> reportIncomingCall({
    String? id,
    required CallHandle handle,
    String? displayName,
    bool video = false,
    Map<String, Object?> payload = const {},
  }) => _newCall(
    id: id,
    handle: handle,
    displayName: displayName,
    video: video,
    outgoing: false,
    payload: payload,
  );

  /// Tells the system the user starts a call (it shows in the system's UI
  /// and in Recents), and completes with it, [SystemCallState.dialing].
  /// Report [SystemCall.reportConnecting] and [SystemCall.reportConnected]
  /// as the other side answers.
  ///
  /// [id] as for [reportIncomingCall].
  Future<SystemCall> startOutgoingCall({
    String? id,
    required CallHandle handle,
    String? displayName,
    bool video = false,
  }) => _newCall(
    id: id,
    handle: handle,
    displayName: displayName,
    video: video,
    outgoing: true,
  );

  Future<SystemCall> _newCall({
    required String? id,
    required CallHandle handle,
    required String? displayName,
    required bool video,
    required bool outgoing,
    Map<String, Object?> payload = const {},
  }) async {
    final backend = _requireConfigured();
    final callId = (id ?? generateTrackName()).toLowerCase();
    if (!isCallUuid(callId)) {
      throw ArgumentError.value(id, 'id', 'must be a UUID');
    }
    if (_calls.containsKey(callId)) {
      throw const SystemCallException(SystemCallErrorCode.alreadyExists);
    }
    final info = SystemCallInfo(
      id: callId,
      handle: handle,
      displayName: displayName,
      video: video,
      outgoing: outgoing,
      state: outgoing ? SystemCallState.dialing : SystemCallState.ringing,
      payload: payload,
    );
    final call = SystemCall._(this, info);
    _calls[callId] = call;
    _publish();
    // The system takes the audio over before it shows the call (Android:
    // our call mode goes before Telecom sets its own).
    await _audioRunner.run();
    try {
      if (outgoing) {
        await backend.startOutgoingCall(info);
      } else {
        await backend.reportIncomingCall(info);
      }
    } catch (_) {
      if (identical(_calls[callId], call)) {
        _calls.remove(callId);
        call._end(SystemCallEndReason.failed);
        _publish();
        await _audioRunner.run();
      }
      rethrow;
    }
    _emit(SystemCallAddedEvent(call));
    return call;
  }

  SystemCallBackend _requireConfigured() {
    final backend = _backend;
    if (backend == null) {
      throw StateError('Call SystemCalls.configure() first.');
    }
    return backend;
  }

  /// The call the audio follows: the newest one not on hold.
  SystemCall? get _current =>
      _calls.values.lastWhereOrNull((c) => c.state != SystemCallState.held) ??
      _calls.values.lastOrNull;

  SystemCall _added(SystemCallInfo info) {
    final call = SystemCall._(this, info);
    _calls[info.id] = call;
    _publish();
    unawaited(_audioRunner.run());
    _emit(SystemCallAddedEvent(call));
    return call;
  }

  void _onSignal(SystemCallSignal signal) {
    switch (signal) {
      case CallReportedSignal(:final call):
        if (!_calls.containsKey(call.id)) _added(call);
      case CallAnsweredSignal(:final id):
        final call = _calls[id];
        if (call == null || call.state != SystemCallState.ringing) return;
        call._state.set(SystemCallState.active);
        _emit(SystemCallAnsweredEvent(call));
      case CallEndedSignal(:final id, :final reason):
        _ended(id, reason);
      case CallHeldSignal(:final id, :final onHold):
        final call = _calls[id];
        if (call == null) return;
        final was = call.state;
        if (onHold == (was == SystemCallState.held)) return;
        if (was == SystemCallState.ringing) return;
        call._state.set(onHold ? SystemCallState.held : SystemCallState.active);
        _emit(SystemCallHeldEvent(call, onHold: onHold));
        if (onHold &&
            !_calls.values.any((c) => c.state == SystemCallState.active)) {
          _audioInterruptions.add(
            const AudioInterruptionSignal.began(CallInterruptionReason.held),
          );
        } else if (!onHold) {
          _audioInterruptions.add(const AudioInterruptionSignal.ended());
        }
      case CallMutedSignal(:final id, :final muted):
        final call = _calls[id];
        if (call == null || call.muted == muted) return;
        call._muted.set(muted);
        _emit(SystemCallMutedEvent(call, muted: muted));
      case CallDtmfSignal(:final id, :final digits):
        if (_calls[id] case final call?) {
          _emit(SystemCallDtmfEvent(call, digits));
        }
      case CallAudioSignal(:final activated):
        final call = _current;
        if (call == null) return;
        _emit(
          activated
              ? SystemCallAudioActivatedEvent(call)
              : SystemCallAudioDeactivatedEvent(call),
        );
        // A deactivation without a hold (iOS) leaves the call silent too.
        final held = _calls.values.any((c) => c.state == SystemCallState.held);
        if (activated) {
          _audioInterruptions.add(const AudioInterruptionSignal.ended());
        } else if (!held && call.state == SystemCallState.active) {
          _audioInterruptions.add(
            const AudioInterruptionSignal.began(CallInterruptionReason.unknown),
          );
        }
      case CallEndpointsSignal():
        _endpointChanges.add(null);
      case VoipTokenSignal(:final token):
        _voipToken.set(token);
    }
  }

  void _ended(String id, SystemCallEndReason reason) {
    final call = _calls.remove(id);
    if (call == null) return;
    call._end(reason);
    _publish();
    unawaited(_audioRunner.run());
    _emit(SystemCallEndedEvent(call, reason));
  }

  void _publish() {
    if (!_list.isClosed) _list.set(List.unmodifiable(_calls.values));
  }

  void _emit(SystemCallEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  // While a system call exists, call audio follows it (§4.8): the system
  // owns the session, the routes on Android, and the interruptions.
  Future<void> _applyAudio() async {
    final backend = _backend;
    if (backend == null || !backend.isSystem) return;
    final audio = CallAudio.instance;
    if (!audio.supported) return;
    final want = _calls.isNotEmpty;
    if (want == (_audio != null)) return;
    final next = want
        ? SystemCallAudioBackend(
            platform: audio.platformBackend,
            system: backend,
            callId: () => _current?.id,
            isHeld: () => _current?.state == SystemCallState.held,
            endpointChanges: _endpointChanges.stream,
            interruptions: _audioInterruptions.stream,
          )
        : null;
    _audio = next;
    try {
      await audio.useSystemCall(next);
    } catch (error) {
      debugPrint('cloudflare_realtime: handing call audio over failed: $error');
    }
  }

  void _dispose() {
    unawaited(_signals?.cancel());
    unawaited(_events.close());
    unawaited(_list.close());
    unawaited(_audioInterruptions.close());
    unawaited(_endpointChanges.close());
    unawaited(_voipToken.close());
    for (final call in _calls.values) {
      call._dispose();
    }
    _calls.clear();
  }
}

/// Whether [id] is a UUID, as the platforms need a call's ID to be.
@visibleForTesting
bool isCallUuid(String id) => _uuid.hasMatch(id);

final RegExp _uuid = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
  r'[0-9a-fA-F]{12}$',
);

/// One call in the system's call UI (`docs/design.md` §4.8), from
/// [SystemCalls.reportIncomingCall], [SystemCalls.startOutgoingCall], or a
/// VoIP push.
///
/// Its methods are **requests**: they complete once the system accepted
/// them, and [state], [muted] and [SystemCalls.events] change when the
/// system confirms, the same way as when the user acts in the system's UI.
/// [Room.attachSystemCall] keeps a room's microphone and this call's mute
/// in step.
class SystemCall {
  SystemCall._(this._calls, SystemCallInfo info)
    : id = info.id,
      handle = info.handle,
      outgoing = info.outgoing,
      payload = Map.unmodifiable(info.payload),
      _displayName = info.displayName,
      _video = info.video,
      _state = StateStream(info.state, distinct: true),
      _muted = StateStream(info.muted, distinct: true);

  final SystemCalls _calls;

  /// The call's ID: a UUID, lowercase.
  final String id;

  /// Who the call is with.
  final CallHandle handle;

  /// Whether the app started the call.
  final bool outgoing;

  /// What the VoIP push carried beyond the call's own fields (iOS), for the
  /// app to find the room; empty otherwise.
  final Map<String, Object?> payload;

  String? _displayName;
  bool _video;
  final StateStream<SystemCallState> _state;
  final StateStream<bool> _muted;
  SystemCallEndReason? _endReason;
  final Completer<SystemCallEndReason> _ended = Completer();

  /// The name the system shows.
  String? get displayName => _displayName;

  /// Whether the system shows it as a video call.
  bool get video => _video;

  /// Where the call is now.
  SystemCallState get state => _state.value;

  /// [state], replaying the current value, then each change. Completes
  /// after the call ends.
  Stream<SystemCallState> get stateChanges => _state.stream;

  /// Whether the system's mute is on for the call.
  bool get muted => _muted.value;

  /// [muted], replaying the current value, then each change.
  Stream<bool> get mutedChanges => _muted.stream;

  /// Whether the call is over.
  bool get isEnded => state == SystemCallState.ended;

  /// Why the call ended, once it has.
  SystemCallEndReason? get endReason => _endReason;

  /// Completes with [endReason] when the call ends.
  Future<SystemCallEndReason> get whenEnded => _ended.future;

  SystemCallBackend get _backend => _calls._requireConfigured();

  /// Answers this incoming call, as if the user tapped Answer in the
  /// system's UI. Throws a [StateError] unless it is ringing, and a
  /// [SystemCallException] if the system refuses.
  Future<void> answer() async {
    if (outgoing || state != SystemCallState.ringing) {
      throw StateError('Only a ringing incoming call can be answered.');
    }
    if (!await _backend.answer(id)) {
      throw const SystemCallException(SystemCallErrorCode.unavailable);
    }
  }

  /// Ends the call. [reason] defaults to [SystemCallEndReason.declined] for
  /// a ringing incoming call and [SystemCallEndReason.local] otherwise;
  /// pass [SystemCallEndReason.remoteEnded] when the other side hung up
  /// (the app's signaling says), [SystemCallEndReason.unanswered] when a
  /// ringing call timed out, and so on. Does nothing once it ended.
  Future<void> end([SystemCallEndReason? reason]) async {
    if (isEnded) return;
    final why =
        reason ??
        (!outgoing && state == SystemCallState.ringing
            ? SystemCallEndReason.declined
            : SystemCallEndReason.local);
    var accepted = false;
    try {
      accepted = await _backend.end(id, why);
    } on SystemCallException catch (e) {
      if (e.code != SystemCallErrorCode.notFound) rethrow;
    }
    // The system no longer has it: it is over here too.
    if (!accepted) _calls._ended(id, why);
  }

  /// Puts the call on hold ([onHold]) or takes it off. While a system call
  /// is held, a room's audio is silent ([CallInterruptionReason.held]).
  Future<void> setHeld(bool onHold) async {
    if (state != SystemCallState.active && state != SystemCallState.held) {
      throw StateError('Only an active call can be held.');
    }
    if (!await _backend.setHeld(id, onHold: onHold)) {
      throw const SystemCallException(SystemCallErrorCode.unavailable);
    }
  }

  /// Turns the system's mute on ([muted]) or off for the call.
  /// [Room.attachSystemCall] does this for a room's microphone.
  Future<void> setMuted(bool muted) async {
    _checkNotEnded();
    if (!await _backend.setMuted(id, muted: muted)) {
      throw const SystemCallException(SystemCallErrorCode.unavailable);
    }
  }

  /// This outgoing call started connecting (the app is reaching the other
  /// side). iOS shows "connecting" and starts the call's timer later.
  Future<void> reportConnecting() async {
    if (!outgoing || state != SystemCallState.dialing) {
      throw StateError('Only a dialing outgoing call can connect.');
    }
    await _backend.reportConnecting(id);
    _state.set(SystemCallState.connecting);
  }

  /// This outgoing call connected: the other side answered.
  Future<void> reportConnected() async {
    if (!outgoing ||
        (state != SystemCallState.dialing &&
            state != SystemCallState.connecting)) {
      throw StateError('Only a dialing outgoing call can connect.');
    }
    await _backend.reportConnected(id);
    if (!isEnded) _state.set(SystemCallState.active);
  }

  /// Changes what the system shows: the name, or whether it is a video
  /// call (a voice call that gained video). On Android a call's name and
  /// type are fixed when it is reported, so this only changes iOS.
  Future<void> update({String? displayName, bool? video}) async {
    _checkNotEnded();
    await _backend.update(id, displayName: displayName, video: video);
    if (displayName != null) _displayName = displayName;
    if (video != null) _video = video;
  }

  void _checkNotEnded() {
    if (isEnded) throw StateError('The call $id has ended.');
  }

  void _end(SystemCallEndReason reason) {
    if (isEnded) return;
    _endReason = reason;
    _state.set(SystemCallState.ended);
    if (!_ended.isCompleted) _ended.complete(reason);
    _dispose();
  }

  void _dispose() {
    unawaited(_state.close());
    unawaited(_muted.close());
  }

  @override
  String toString() =>
      'SystemCall($id, ${handle.value}, ${state.name}'
      '${outgoing ? ', outgoing' : ''}${video ? ', video' : ''}'
      '${muted ? ', muted' : ''})';
}

/// VoIP pushes (iOS PushKit, `docs/design.md` §4.8): pushes that wake the
/// app for an incoming call.
///
/// The package reports the pushed call to CallKit natively, before Dart
/// runs (iOS terminates an app that doesn't), so the push's payload must
/// carry the call: `id` (a UUID), `handle`, and optionally `handleType`,
/// `displayName` and `video`; everything else is the call's
/// [SystemCall.payload]. The call then arrives as a [SystemCallAddedEvent]
/// (or in [SystemCalls.calls] after [SystemCalls.configure]).
///
/// Android has no VoIP pushes: a high-priority FCM message wakes the app,
/// which calls [SystemCalls.reportIncomingCall]. Sending pushes is the
/// app's server's job.
class VoipPush {
  VoipPush._(this._calls);

  final SystemCalls _calls;

  /// Whether VoIP pushes work here: iOS with system calls supported
  /// ([SystemCalls.supported]).
  bool get supported =>
      _calls._supported && (_calls._backend?.supportsVoipPush ?? false);

  /// The device's VoIP push token (hex), for the app's server, or `null`
  /// before it arrives or after it was invalidated.
  String? get token => _calls._voipToken.value;

  /// [token], replaying the current value, then each change.
  Stream<String?> get tokenChanges => _calls._voipToken.stream;

  /// Registers for VoIP pushes, and completes with the token when it is
  /// already known (else it arrives on [tokenChanges]). Remembered across
  /// launches: from then on the package listens for pushes as soon as the
  /// app starts, before Dart. Does nothing (and completes with `null`)
  /// where VoIP pushes aren't [supported].
  Future<String?> register() async {
    if (!supported) return null;
    final token = await _calls._backend!.registerVoipPush();
    if (token != null && !_calls._voipToken.isClosed) {
      _calls._voipToken.set(token);
    }
    return token ?? this.token;
  }

  /// Stops listening for VoIP pushes, now and at later launches.
  Future<void> unregister() async {
    if (!supported) return;
    await _calls._backend!.unregisterVoipPush();
    if (!_calls._voipToken.isClosed) _calls._voipToken.set(null);
  }
}

/// Something that happened to a [SystemCall] (`docs/design.md` §4.8), in
/// [SystemCalls.events]. Requests from the app and actions in the system's
/// UI produce the same events.
@immutable
sealed class SystemCallEvent {
  const SystemCallEvent(this.call);

  /// The call.
  final SystemCall call;
}

/// A call exists: reported by the app, or by the package for a VoIP push.
final class SystemCallAddedEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallAddedEvent(super.call);

  @override
  String toString() => 'SystemCallAddedEvent($call)';
}

/// An incoming call was answered, here or in the system's UI. The app
/// joins the call's room now.
final class SystemCallAnsweredEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallAnsweredEvent(super.call);

  @override
  String toString() => 'SystemCallAnsweredEvent($call)';
}

/// A call ended, for [reason].
final class SystemCallEndedEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallEndedEvent(super.call, this.reason);

  /// Why.
  final SystemCallEndReason reason;

  @override
  String toString() => 'SystemCallEndedEvent($call, ${reason.name})';
}

/// A call was put on hold ([onHold]) or taken off it.
final class SystemCallHeldEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallHeldEvent(super.call, {required this.onHold});

  /// Whether it is on hold now.
  final bool onHold;

  @override
  String toString() => 'SystemCallHeldEvent($call, onHold: $onHold)';
}

/// The system's mute for a call changed.
final class SystemCallMutedEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallMutedEvent(super.call, {required this.muted});

  /// Whether it is muted now.
  final bool muted;

  @override
  String toString() => 'SystemCallMutedEvent($call, muted: $muted)';
}

/// The system's keypad sent [digits] (iOS, with
/// [SystemCallsConfig.supportsDtmf]).
final class SystemCallDtmfEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallDtmfEvent(super.call, this.digits);

  /// The keys pressed.
  final String digits;

  @override
  String toString() => 'SystemCallDtmfEvent($call, $digits)';
}

/// The system activated the call's audio (iOS: CallKit's `didActivate`;
/// Android: the call went active). Media flows from now on.
final class SystemCallAudioActivatedEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallAudioActivatedEvent(super.call);

  @override
  String toString() => 'SystemCallAudioActivatedEvent($call)';
}

/// The system deactivated the call's audio (iOS: CallKit's
/// `didDeactivate`; Android: the call went inactive).
final class SystemCallAudioDeactivatedEvent extends SystemCallEvent {
  /// Creates the event.
  const SystemCallAudioDeactivatedEvent(super.call);

  @override
  String toString() => 'SystemCallAudioDeactivatedEvent($call)';
}
