import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/call_audio.dart';
import 'package:cloudflare_realtime/src/audio/call_audio_backend.dart';
import 'package:cloudflare_realtime/src/calls/system_call_backend.dart';
import 'package:cloudflare_realtime/src/calls/system_calls.dart'
    show isCallUuid;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_system_call_backend.dart';
import '../support/room_harness.dart';

const _id = '6f1c2b0e-8d4a-4c3e-9b7a-2f5d1e0c9a8b';
const _id2 = '0b6c1d2e-3f40-4a5b-8c6d-7e8f9a0b1c2d';
const _ada = CallHandle('ada');

const _speaker = AudioRoute(id: 'spk', kind: AudioRouteKind.speaker);
const _earpiece = AudioRoute(id: 'ear', kind: AudioRouteKind.earpiece);
const _buds = AudioRoute(
  id: 'bt-1',
  kind: AudioRouteKind.bluetooth,
  name: 'Buds',
);
// Telecom's endpoints: the same places under other IDs.
const _tSpeaker = AudioRoute(id: 'uuid-spk', kind: AudioRouteKind.speaker);
const _tEarpiece = AudioRoute(id: 'uuid-ear', kind: AudioRouteKind.earpiece);
const _tBuds = AudioRoute(
  id: 'uuid-bt',
  kind: AudioRouteKind.bluetooth,
  name: 'Buds',
);

/// A phone's call audio (the platform's backend), recording its calls.
class _Phone implements CallAudioBackend {
  List<AudioRoute> routesNow = [_speaker, _earpiece];
  AudioRoute? currentNow;
  final List<String> calls = [];
  final StreamController<void> _changes = StreamController.broadcast();
  final StreamController<AudioInterruptionSignal> _interruptions =
      StreamController.broadcast();

  void interrupt(AudioInterruptionSignal signal) => _interruptions.add(signal);

  @override
  bool get supported => true;

  @override
  Future<void> activate() async => calls.add('activate');

  @override
  Future<void> deactivate() async => calls.add('deactivate');

  @override
  Future<void> setDefaultToSpeaker(bool speaker) async =>
      calls.add('default ${speaker ? 'speaker' : 'earpiece'}');

  @override
  Future<List<AudioRoute>> routes() async => routesNow;

  @override
  Future<AudioRoute?> current() async => currentNow;

  @override
  Future<bool> select(AudioRoute route) async {
    calls.add('select ${route.id}');
    if (!routesNow.contains(route)) return false;
    currentNow = route;
    return true;
  }

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<bool> setProximityMonitoring(bool enabled) async {
    calls.add('proximity $enabled');
    return enabled;
  }

  @override
  Future<bool> resume() async {
    calls.add('resume');
    return true;
  }

  @override
  Stream<AudioInterruptionSignal> get interruptions => _interruptions.stream;
}

Future<void> _settle() => pumpEventQueue(times: 30);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeSystemCallBackend system;

  setUp(() {
    system = FakeSystemCallBackend();
    debugSystemCallBackendFactory = () => system;
    SystemCalls.debugReset();
  });

  tearDown(() {
    SystemCalls.debugReset();
    debugSystemCallBackendFactory = null;
    CallAudio.debugReset();
    debugCallAudioBackendFactory = null;
  });

  SystemCalls calls() => SystemCalls.instance;

  group('the native contract', () {
    test('event maps', () {
      expect(
        systemCallSignalFromMap({'event': 'answered', 'id': _id}),
        const CallAnsweredSignal(_id),
      );
      expect(
        systemCallSignalFromMap({
          'event': 'ended',
          'id': _id,
          'reason': 'remoteEnded',
        }),
        const CallEndedSignal(_id, SystemCallEndReason.remoteEnded),
      );
      expect(
        systemCallSignalFromMap({'event': 'ended', 'id': _id, 'reason': '?'}),
        const CallEndedSignal(_id, SystemCallEndReason.failed),
      );
      expect(
        systemCallSignalFromMap({'event': 'held', 'id': _id, 'onHold': true}),
        const CallHeldSignal(_id, onHold: true),
      );
      expect(
        systemCallSignalFromMap({'event': 'muted', 'id': _id, 'muted': false}),
        const CallMutedSignal(_id, muted: false),
      );
      final dtmf = systemCallSignalFromMap({
        'event': 'dtmf',
        'id': _id,
        'digits': '12#',
      });
      expect(
        dtmf,
        isA<CallDtmfSignal>().having((s) => s.digits, 'digits', '12#'),
      );
      expect(
        systemCallSignalFromMap({'event': 'audioActivated'}),
        isA<CallAudioSignal>().having((s) => s.activated, 'activated', true),
      );
      expect(
        systemCallSignalFromMap({'event': 'audioDeactivated'}),
        isA<CallAudioSignal>().having((s) => s.activated, 'activated', false),
      );
      expect(
        systemCallSignalFromMap({'event': 'endpointsChanged', 'id': _id}),
        isA<CallEndpointsSignal>(),
      );
      expect(
        systemCallSignalFromMap({'event': 'voipToken', 'token': 'ab12'}),
        isA<VoipTokenSignal>().having((s) => s.token, 'token', 'ab12'),
      );
      expect(
        systemCallSignalFromMap({'event': 'voipToken', 'token': null}),
        isA<VoipTokenSignal>().having((s) => s.token, 'token', isNull),
      );
      final reported = systemCallSignalFromMap({
        'event': 'reported',
        'call': {
          'id': _id,
          'handle': '+15550100',
          'handleType': 'phoneNumber',
          'displayName': 'Ada',
          'video': true,
          'state': 'ringing',
          'payload': {'room': 'r1', 7: 'dropped'},
        },
      });
      expect(reported, isA<CallReportedSignal>());
      final info = (reported! as CallReportedSignal).call;
      expect(info.handle, const CallHandle.phoneNumber('+15550100'));
      expect(info.displayName, 'Ada');
      expect(info.video, isTrue);
      expect(info.outgoing, isFalse);
      expect(info.payload, {'room': 'r1'});

      // Malformed or unknown: ignored.
      expect(systemCallSignalFromMap({'event': 'answered'}), isNull);
      expect(systemCallSignalFromMap({'event': 'nope', 'id': _id}), isNull);
      expect(
        systemCallSignalFromMap({
          'event': 'reported',
          'call': {'handle': 'x'},
        }),
        isNull,
      );
    });

    test('the call map and the configuration map', () {
      const info = SystemCallInfo(
        id: _id,
        handle: CallHandle.emailAddress('ada@example.com'),
        displayName: 'Ada',
        video: true,
        outgoing: true,
      );
      expect(info.toMap(), {
        'id': _id,
        'handle': 'ada@example.com',
        'handleType': 'emailAddress',
        'displayName': 'Ada',
        'video': true,
        'outgoing': true,
      });
      expect(const SystemCallsOptions(ringtoneSound: 'ring.caf').toMap(), {
        'supportsVideo': true,
        'maximumCalls': 1,
        'supportsHolding': true,
        'supportsDtmf': false,
        'includesCallsInRecents': true,
        'iconTemplateImageName': null,
        'ringtoneSound': 'ring.caf',
      });
    });

    test('platform errors map to SystemCallException codes', () {
      expect(
        systemCallExceptionFrom(PlatformException(code: 'filtered')).code,
        SystemCallErrorCode.filtered,
      );
      expect(
        systemCallExceptionFrom(PlatformException(code: 'weird')).code,
        SystemCallErrorCode.failed,
      );
    });

    group('over the channels', () {
      const methods = MethodChannel(
        'dev.kammcs.cloudflare_realtime/system_calls',
      );
      const events = EventChannel(
        'dev.kammcs.cloudflare_realtime/system_calls_events',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      tearDown(() {
        messenger.setMockMethodCallHandler(methods, null);
        messenger.setMockStreamHandler(events, null);
      });

      test('without the native side, configure says unsupported', () async {
        expect(
          await MethodChannelSystemCallBackend().configure(
            const SystemCallsOptions(),
          ),
          isFalse,
        );
      });

      test('methods, arguments and results', () async {
        final seen = <MethodCall>[];
        messenger.setMockMethodCallHandler(methods, (call) async {
          seen.add(call);
          return switch (call.method) {
            'configure' || 'answer' || 'end' => true,
            'setHeld' || 'setMuted' || 'selectEndpoint' => true,
            'activeCalls' => [
              {'id': _id, 'handle': 'ada', 'state': 'active', 'muted': true},
            ],
            'endpoints' => {
              'routes': [
                {'id': 'u1', 'kind': 'speaker', 'name': ''},
                {'id': 'u2', 'kind': 'bluetooth', 'name': 'Buds'},
              ],
              'current': {'id': 'u2', 'kind': 'bluetooth', 'name': 'Buds'},
            },
            'registerVoipPush' => 'cafe',
            'reportIncomingCall' => throw PlatformException(
              code: 'filtered',
              message: 'Do Not Disturb',
            ),
            _ => null,
          };
        });
        final backend = MethodChannelSystemCallBackend();
        expect(await backend.configure(const SystemCallsOptions()), isTrue);
        await expectLater(
          backend.reportIncomingCall(
            const SystemCallInfo(id: _id, handle: _ada),
          ),
          throwsA(
            isA<SystemCallException>()
                .having((e) => e.code, 'code', SystemCallErrorCode.filtered)
                .having((e) => e.message, 'message', 'Do Not Disturb'),
          ),
        );
        await backend.startOutgoingCall(
          const SystemCallInfo(id: _id, handle: _ada, outgoing: true),
        );
        await backend.reportConnecting(_id);
        await backend.reportConnected(_id);
        expect(await backend.answer(_id), isTrue);
        expect(await backend.end(_id, SystemCallEndReason.declined), isTrue);
        expect(await backend.setHeld(_id, onHold: true), isTrue);
        expect(await backend.setMuted(_id, muted: true), isTrue);
        await backend.update(_id, video: true);
        final active = await backend.activeCalls();
        expect(active.single.state, SystemCallState.active);
        expect(active.single.muted, isTrue);
        final endpoints = (await backend.endpoints(_id))!;
        expect(endpoints.routes.map((r) => r.id), ['u1', 'u2']);
        expect(endpoints.current?.name, 'Buds');
        expect(await backend.selectEndpoint(_id, 'u1'), isTrue);
        expect(await backend.registerVoipPush(), 'cafe');
        await backend.unregisterVoipPush();

        expect(
          [for (final c in seen) c.method],
          [
            'configure',
            'reportIncomingCall',
            'startOutgoingCall',
            'reportConnecting',
            'reportConnected',
            'answer',
            'end',
            'setHeld',
            'setMuted',
            'update',
            'activeCalls',
            'endpoints',
            'selectEndpoint',
            'registerVoipPush',
            'unregisterVoipPush',
          ],
        );
        Map<Object?, Object?> args(String method) =>
            seen.firstWhere((c) => c.method == method).arguments as Map;
        expect(args('configure')['supportsVideo'], isTrue);
        expect(args('startOutgoingCall')['outgoing'], isTrue);
        expect(args('end'), {'id': _id, 'reason': 'declined'});
        expect(args('setHeld'), {'id': _id, 'onHold': true});
        expect(args('setMuted'), {'id': _id, 'muted': true});
        expect(args('update'), {'id': _id, 'video': true});
        expect(args('selectEndpoint'), {'id': _id, 'routeId': 'u1'});
      });

      test('events', () async {
        messenger.setMockStreamHandler(
          events,
          MockStreamHandler.inline(
            onListen: (arguments, sink) {
              sink.success({'event': 'answered', 'id': _id});
              sink.success('noise');
              sink.success({'event': 'muted', 'id': _id, 'muted': true});
            },
          ),
        );
        final signals = await MethodChannelSystemCallBackend().signals
            .take(2)
            .toList();
        expect(signals, [
          const CallAnsweredSignal(_id),
          const CallMutedSignal(_id, muted: true),
        ]);
      });
    });
  });

  group('SystemCalls', () {
    test('reporting needs configure first', () async {
      expect(() => calls().reportIncomingCall(handle: _ada), throwsStateError);
    });

    test('an incoming call: ringing, answered from the system, held, muted, '
        'ended', () async {
      expect(await calls().configure(), isTrue);
      expect(calls().isSupported, isTrue);
      final events = <SystemCallEvent>[];
      calls().events.listen(events.add);

      final call = await calls().reportIncomingCall(
        id: _id.toUpperCase(),
        handle: _ada,
        displayName: 'Ada',
        video: true,
      );
      expect(call.id, _id, reason: 'IDs are lowercase');
      expect(call.state, SystemCallState.ringing);
      expect(calls().calls, [call]);
      expect(calls().call(_id.toUpperCase()), call);
      expect(system.calls, ['configure', 'reportIncomingCall $_id']);

      system.system(const CallAnsweredSignal(_id)); // the lock screen
      await _settle();
      expect(call.state, SystemCallState.active);

      await call.setHeld(true);
      await _settle();
      expect(call.state, SystemCallState.held);
      system.system(const CallHeldSignal(_id, onHold: false));
      await _settle();
      expect(call.state, SystemCallState.active);

      system.system(const CallMutedSignal(_id, muted: true));
      system.system(const CallDtmfSignal(_id, '5'));
      await _settle();
      expect(call.isMuted, isTrue);

      system.system(
        const CallEndedSignal(_id, SystemCallEndReason.remoteEnded),
      );
      await _settle();
      expect(call.state, SystemCallState.ended);
      expect(call.endReason, SystemCallEndReason.remoteEnded);
      expect(await call.whenEnded, SystemCallEndReason.remoteEnded);
      expect(calls().calls, isEmpty);
      expect(call.end, returnsNormally, reason: 'ending twice does nothing');

      expect(events.map((e) => e.runtimeType), [
        SystemCallAddedEvent,
        SystemCallAnsweredEvent,
        SystemCallHeldEvent,
        SystemCallHeldEvent,
        SystemCallMutedEvent,
        SystemCallDtmfEvent,
        SystemCallEndedEvent,
      ]);
      expect((events[5] as SystemCallDtmfEvent).digits, '5');
    });

    test('requests are confirmed by events: answer, mute, end', () async {
      await calls().configure();
      final call = await calls().reportIncomingCall(handle: _ada);
      expect(isCallUuid(call.id), isTrue, reason: 'a generated UUID');
      await call.answer();
      expect(call.state, SystemCallState.ringing, reason: 'not confirmed yet');
      await _settle();
      expect(call.state, SystemCallState.active);
      expect(() => call.answer(), throwsStateError);

      await call.setMuted(true);
      await _settle();
      expect(call.isMuted, isTrue);

      await call.end();
      await _settle();
      expect(system.calls.last, 'end ${call.id} local');
      expect(call.endReason, SystemCallEndReason.local);
    });

    test('declining a ringing call; refused requests throw', () async {
      await calls().configure();
      final call = await calls().reportIncomingCall(handle: _ada);
      system.refuseRequests = true;
      await expectLater(
        call.answer(),
        throwsA(
          isA<SystemCallException>().having(
            (e) => e.code,
            'code',
            SystemCallErrorCode.unavailable,
          ),
        ),
      );
      // The system refusing an end means it no longer has the call.
      await call.end();
      expect(system.calls.last, 'end ${call.id} declined');
      expect(call.state, SystemCallState.ended);
      expect(call.endReason, SystemCallEndReason.declined);
    });

    test('a ringing call the system ends keeps the system\'s reason: '
        'declined only when declined', () async {
      await calls().configure();
      final ended = <SystemCallEndedEvent>[];
      final sub = calls().events.listen((e) {
        if (e is SystemCallEndedEvent) ended.add(e);
      });
      addTearDown(sub.cancel);

      // The user's Decline in the system's UI (Telecom's reject, CallKit's
      // end action).
      final declined = await calls().reportIncomingCall(id: _id, handle: _ada);
      system.system(const CallEndedSignal(_id, SystemCallEndReason.declined));
      await _settle();
      expect(declined.endReason, SystemCallEndReason.declined);

      // The system ending it without anyone declining (Telecom making room
      // for an emergency call): failed, not reclassified as a decline
      // because it was ringing.
      final dropped = await calls().reportIncomingCall(id: _id2, handle: _ada);
      expect(dropped.state, SystemCallState.ringing);
      system.system(const CallEndedSignal(_id2, SystemCallEndReason.failed));
      await _settle();
      expect(dropped.state, SystemCallState.ended);
      expect(dropped.endReason, SystemCallEndReason.failed);
      expect(await dropped.whenEnded, SystemCallEndReason.failed);
      expect(system.calls.where((c) => c.startsWith('end')), isEmpty);
      expect(ended.map((e) => (e.call.id, e.reason)), [
        (_id, SystemCallEndReason.declined),
        (_id2, SystemCallEndReason.failed),
      ]);
    });

    test('an outgoing call: dialing, connecting, connected', () async {
      await calls().configure();
      final call = await calls().startOutgoingCall(
        id: _id,
        handle: _ada,
        video: true,
      );
      expect(call.isOutgoing, isTrue);
      expect(call.state, SystemCallState.dialing);
      await call.reportConnecting();
      expect(call.state, SystemCallState.connecting);
      await call.reportConnected();
      expect(call.state, SystemCallState.active);
      expect(() => call.reportConnected(), throwsStateError);
      await call.update(displayName: 'Ada L.', video: false);
      expect(call.displayName, 'Ada L.');
      expect(call.isVideo, isFalse);
      expect(system.calls, [
        'configure',
        'startOutgoingCall $_id',
        'reportConnecting $_id',
        'reportConnected $_id',
        'update $_id Ada L. false',
      ]);
    });

    test('IDs: a UUID, once', () async {
      await calls().configure();
      expect(
        () => calls().reportIncomingCall(id: 'room-1', handle: _ada),
        throwsArgumentError,
      );
      await calls().reportIncomingCall(id: _id, handle: _ada);
      await expectLater(
        calls().reportIncomingCall(id: _id, handle: _ada),
        throwsA(
          isA<SystemCallException>().having(
            (e) => e.code,
            'code',
            SystemCallErrorCode.alreadyExists,
          ),
        ),
      );
    });

    test('a refused report throws and leaves no call', () async {
      await calls().configure();
      final events = <SystemCallEvent>[];
      calls().events.listen(events.add);
      system.refuseNext = const SystemCallException(
        SystemCallErrorCode.filtered,
      );
      await expectLater(
        calls().reportIncomingCall(handle: _ada),
        throwsA(isA<SystemCallException>()),
      );
      await _settle();
      expect(calls().calls, isEmpty);
      expect(events, isEmpty);
    });

    test('calls the system already has (a VoIP push that launched the app) '
        'are there after configure, and pushed calls arrive', () async {
      system.preexisting = [
        const SystemCallInfo(
          id: _id,
          handle: _ada,
          state: SystemCallState.active,
          payload: {'room': 'r1'},
        ),
      ];
      final events = <SystemCallEvent>[];
      calls().events.listen(events.add);
      await calls().configure();
      final restored = calls().call(_id)!;
      expect(restored.state, SystemCallState.active);
      expect(restored.payload, {'room': 'r1'});

      system.system(
        const CallReportedSignal(SystemCallInfo(id: _id2, handle: _ada)),
      );
      // The same call again (a buffered event after activeCalls): once.
      system.system(
        const CallReportedSignal(SystemCallInfo(id: _id, handle: _ada)),
      );
      await _settle();
      expect(calls().calls.map((c) => c.id), [_id, _id2]);
      expect(calls().call(_id), same(restored));
      expect(events.whereType<SystemCallAddedEvent>(), hasLength(2));
    });

    test('a VoIP cancel push (iOS) ends the pushed call with its reason; '
        'one for a call Dart never had changes nothing', () async {
      final events = <SystemCallEvent>[];
      calls().events.listen(events.add);
      await calls().configure();
      // As the native side buffers them before Dart listens: the call, then
      // its cancel.
      system
        ..system(
          const CallReportedSignal(SystemCallInfo(id: _id, handle: _ada)),
        )
        ..system(
          const CallEndedSignal(_id, SystemCallEndReason.answeredElsewhere),
        )
        ..system(const CallEndedSignal(_id2, SystemCallEndReason.remoteEnded));
      await _settle();
      expect(events.map((e) => e.runtimeType), [
        SystemCallAddedEvent,
        SystemCallEndedEvent,
      ]);
      final ended = events.last as SystemCallEndedEvent;
      expect(ended.call.id, _id);
      expect(ended.reason, SystemCallEndReason.answeredElsewhere);
      expect(ended.call.endReason, SystemCallEndReason.answeredElsewhere);
      expect(calls().calls, isEmpty);
    });

    test(
      'a refused or missing native side: the calls are kept in Dart',
      () async {
        system.configureResult = false;
        expect(await calls().configure(), isFalse);
        expect(calls().isSupported, isFalse);
        expect(calls().voipPush.isSupported, isFalse);
        final call = await calls().reportIncomingCall(handle: _ada);
        await call.answer();
        await call.setMuted(true);
        await _settle();
        expect(call.state, SystemCallState.active);
        expect(call.isMuted, isTrue);
        await call.end();
        await _settle();
        expect(call.endReason, SystemCallEndReason.local);
        expect(system.calls, ['configure'], reason: 'nothing reached it');
        expect(await calls().voipPush.register(), isNull);
      },
    );

    test('desktops and the web: the same flow without a system UI', () async {
      debugSystemCallBackendFactory = LocalSystemCallBackend.new;
      SystemCalls.debugReset();
      expect(await calls().configure(), isFalse);
      final call = await calls().startOutgoingCall(handle: _ada);
      await call.reportConnected();
      await call.setHeld(true);
      await _settle();
      expect(call.state, SystemCallState.held);
      await call.end(SystemCallEndReason.remoteEnded);
      await _settle();
      expect(call.endReason, SystemCallEndReason.remoteEnded);
    });

    test('VoIP push: register, the token and its changes', () async {
      system
        ..supportsVoipPush = true
        ..token = 'beef';
      await calls().configure();
      expect(calls().voipPush.isSupported, isTrue);
      expect(await calls().voipPush.register(), 'beef');
      expect(calls().voipPush.token, 'beef');
      system.system(const VoipTokenSignal('f00d'));
      await _settle();
      expect(calls().voipPush.token, 'f00d');
      system.system(const VoipTokenSignal(null));
      await _settle();
      expect(calls().voipPush.token, isNull);
      await calls().voipPush.unregister();
      expect(system.calls, contains('unregisterVoipPush'));
    });
  });

  group('call audio while a system call exists', () {
    late _Phone phone;
    final room = Object();

    setUp(() async {
      phone = _Phone();
      debugCallAudioBackendFactory = () => phone;
      CallAudio.debugReset();
      await CallAudio.instance.join(room);
      phone.calls.clear();
    });

    tearDown(() => CallAudio.instance.leave(room));

    test('Android: Telecom owns the mode and the routes; the user\'s choice '
        'carries over by kind; back to the platform after the call', () async {
      system.routesThroughEndpoints = true;
      system.endpointsNow = [_tSpeaker, _tEarpiece];
      system.currentEndpoint = _tEarpiece;
      final audio = CallAudio.instance;
      await audio.select(_speaker);
      expect(audio.current.value, _speaker);
      phone.calls.clear();

      await calls().configure();
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await _settle();
      expect(audio.usesSystemCall, isTrue);
      expect(phone.calls.first, 'deactivate', reason: 'Telecom sets the mode');
      expect(phone.calls, isNot(contains('activate')));
      expect(audio.routes.value, [_tSpeaker, _tEarpiece]);
      expect(audio.current.value, _tSpeaker, reason: 'the choice carried');
      expect(system.calls, contains('selectEndpoint $_id uuid-spk'));
      expect(phone.calls.where((c) => c.startsWith('select')), isEmpty);

      // A headset connects: Telecom lists it, and the new headset wins.
      system.setEndpoints([_tSpeaker, _tEarpiece, _tBuds], _tSpeaker, _id);
      await _settle();
      expect(audio.current.value, _tBuds);

      await audio.select(_tSpeaker);
      expect(system.calls.last, 'selectEndpoint $_id uuid-spk');
      expect(audio.current.value, _tSpeaker);

      phone.calls.clear();
      await call.end();
      await _settle();
      expect(audio.usesSystemCall, isFalse);
      expect(phone.calls, contains('activate'));
      expect(audio.routes.value, [_speaker, _earpiece]);
    });

    test('iOS: CallKit activates the session; routes stay the '
        "platform's", () async {
      system.systemActivatesAudio = true;
      phone.routesNow = [_speaker, _earpiece, _buds];
      await calls().configure();
      await calls().startOutgoingCall(id: _id, handle: _ada);
      await _settle();
      final audio = CallAudio.instance;
      expect(audio.usesSystemCall, isTrue);
      expect(audio.routes.value, [_speaker, _buds]);
      await audio.select(_speaker);
      expect(phone.calls, contains('select spk'));
      expect(
        system.calls.where((c) => c.startsWith('selectEndpoint')),
        isEmpty,
      );
    });

    test('a hold interrupts the call; resume() takes it off hold', () async {
      await calls().configure();
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await call.answer();
      await _settle();
      final audio = CallAudio.instance;

      system.system(const CallHeldSignal(_id, onHold: true)); // another call
      await _settle();
      expect(audio.interruption.value, CallInterruptionReason.held);

      expect(await audio.resume(), isTrue);
      expect(system.calls.last, 'setHeld $_id false');
      await _settle();
      expect(call.state, SystemCallState.active);
      expect(audio.interruption.value, isNull);
      expect(
        phone.calls,
        isNot(contains('resume')),
        reason: "the platform's session isn't touched",
      );
    });

    test('iOS: audio deactivated without a hold interrupts; activated '
        'resumes', () async {
      system.systemActivatesAudio = true;
      await calls().configure();
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      final events = <SystemCallEvent>[];
      calls().events.listen(events.add);
      await call.answer();
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      expect(CallAudio.instance.interruption.value, isNull);

      system.system(const CallAudioSignal(activated: false));
      await _settle();
      expect(
        CallAudio.instance.interruption.value,
        CallInterruptionReason.unknown,
      );
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      expect(CallAudio.instance.interruption.value, isNull);
      expect(events.map((e) => e.runtimeType), [
        SystemCallAnsweredEvent,
        SystemCallAudioActivatedEvent,
        SystemCallAudioDeactivatedEvent,
        SystemCallAudioActivatedEvent,
      ]);
    });

    test("iOS: a quick hold's deactivation, arriving after the unhold, "
        "doesn't interrupt the call again", () async {
      system.systemActivatesAudio = true;
      await calls().configure();
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await call.answer();
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      final audio = CallAudio.instance;
      final changes = <CallInterruptionReason?>[];
      final sub = audio.interruption.stream.listen(changes.add);
      addTearDown(sub.cancel);

      // As on an iPhone: CallKit deactivates the session ~0.5 s after the
      // hold, so a quick unhold comes first.
      system.system(const CallHeldSignal(_id, onHold: true));
      await _settle();
      expect(audio.interruption.value, CallInterruptionReason.held);
      system.system(const CallHeldSignal(_id, onHold: false));
      await _settle();
      expect(audio.interruption.value, isNull);
      system.system(const CallAudioSignal(activated: false));
      await _settle();
      expect(audio.interruption.value, isNull, reason: "the hold's");
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      expect(audio.interruption.value, isNull);
      expect(changes, [null, CallInterruptionReason.held, null]);

      // The hold's deactivation came: a later one interrupts again.
      system.system(const CallAudioSignal(activated: false));
      await _settle();
      expect(audio.interruption.value, CallInterruptionReason.unknown);
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      expect(audio.interruption.value, isNull);
    });

    test('a hold whose deactivation came in time owes nothing', () async {
      system.systemActivatesAudio = true;
      await calls().configure();
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await call.answer();
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      final audio = CallAudio.instance;

      system.system(const CallHeldSignal(_id, onHold: true));
      system.system(const CallAudioSignal(activated: false));
      await _settle();
      expect(audio.interruption.value, CallInterruptionReason.held);
      system.system(const CallHeldSignal(_id, onHold: false));
      system.system(const CallAudioSignal(activated: true));
      await _settle();
      expect(audio.interruption.value, isNull);

      system.system(const CallAudioSignal(activated: false));
      await _settle();
      expect(audio.interruption.value, CallInterruptionReason.unknown);
    });

    test('an interruption from before the call is taken back by the '
        'call', () async {
      phone.interrupt(
        const AudioInterruptionSignal.began(CallInterruptionReason.otherAudio),
      );
      await _settle();
      expect(CallAudio.instance.interruption.value, isNotNull);
      await calls().configure();
      await calls().reportIncomingCall(id: _id, handle: _ada);
      await _settle();
      expect(CallAudio.instance.interruption.value, isNull);
    });

    test('without a system UI, call audio stays the platform\'s', () async {
      system.configureResult = false;
      await calls().configure();
      await calls().reportIncomingCall(id: _id, handle: _ada);
      await _settle();
      expect(CallAudio.instance.usesSystemCall, isFalse);
    });
  });

  group('the Room', () {
    late RoomHarness h;

    setUp(() async {
      h = RoomHarness();
      await calls().configure();
    });

    test('the system mute button and the microphone stay in step', () async {
      final alice = await h.join('alice');
      final mic = await alice.localParticipant.publishMicrophone();
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await call.answer();
      await _settle();
      alice.attachSystemCall(call);
      expect(alice.systemCall, call);
      await _settle();
      expect(system.calls.where((c) => c.startsWith('setMuted')), isEmpty);

      // The lock screen mutes, then unmutes.
      system.system(const CallMutedSignal(_id, muted: true));
      await _settle();
      expect(mic.isMuted, isTrue);
      expect(system.calls.where((c) => c.startsWith('setMuted')), isEmpty);
      system.system(const CallMutedSignal(_id, muted: false));
      await _settle();
      expect(mic.isMuted, isFalse);

      // The app mutes: the system's button follows, nothing loops.
      await mic.mute();
      await _settle();
      expect(system.calls.last, 'setMuted $_id true');
      expect(call.isMuted, isTrue);
      expect(mic.isMuted, isTrue);

      // Quick toggles end where the app left them.
      await mic.unmute();
      await mic.mute();
      await mic.unmute();
      await _settle();
      expect(mic.isMuted, isFalse);
      expect(call.isMuted, isFalse);

      await alice.leave();
    });

    test('muting wins at attach and when a microphone is published', () async {
      final alice = await h.join('alice');
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await call.answer();
      system.system(const CallMutedSignal(_id, muted: true));
      await _settle();
      alice.attachSystemCall(call);
      final mic = await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(mic.isMuted, isTrue, reason: 'the system was muted');
      await alice.leave();

      final bob = await h.join('bob');
      final bobMic = await bob.localParticipant.publishMicrophone(muted: true);
      final call2 = await calls().reportIncomingCall(id: _id2, handle: _ada);
      await call2.answer();
      await _settle();
      bob.attachSystemCall(call2);
      await _settle();
      expect(system.calls.last, 'setMuted $_id2 true');
      expect(call2.isMuted, isTrue);
      expect(bobMic.isMuted, isTrue);
      await bob.leave();
    });

    test('the call ending leaves the room; leaving ends the call', () async {
      final alice = await h.join('alice');
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      await call.answer();
      await _settle();
      alice.attachSystemCall(call);
      system.system(const CallEndedSignal(_id, SystemCallEndReason.local));
      await _settle();
      expect(alice.hasLeft, isTrue);

      final bob = await h.join('bob');
      final call2 = await calls().reportIncomingCall(id: _id2, handle: _ada);
      await call2.answer();
      await _settle();
      bob.attachSystemCall(call2);
      await bob.leave();
      await _settle();
      expect(system.calls, contains('end $_id2 local'));
      expect(call2.isEnded, isTrue);
    });

    test('leaveWhenEnded and endWhenLeft off; detach; an ended call can\'t '
        'be attached', () async {
      final alice = await h.join('alice');
      final call = await calls().reportIncomingCall(id: _id, handle: _ada);
      alice.attachSystemCall(call, leaveWhenEnded: false, endWhenLeft: false);
      await call.end();
      await _settle();
      expect(alice.hasLeft, isFalse);
      expect(() => alice.attachSystemCall(call), throwsStateError);

      final call2 = await calls().reportIncomingCall(id: _id2, handle: _ada);
      alice.attachSystemCall(call2);
      alice.detachSystemCall();
      expect(alice.systemCall, isNull);
      await alice.leave();
      await _settle();
      expect(call2.isEnded, isFalse);
      expect(() => alice.attachSystemCall(call2), throwsStateError);
      await call2.end();
    });
  });
}
