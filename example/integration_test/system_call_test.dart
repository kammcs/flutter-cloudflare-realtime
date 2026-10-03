// System calls (docs/design.md §4.8) on phones, through a real broker:
// Android's Telecom (Core-Telecom) and iOS's CallKit, the same Dart. Two
// rooms in one process share in-memory signaling: Alice is the user of the
// system call and publishes her microphone, Bob pulls it.
//
// 1. An outgoing call: started, reported connecting and connected
//    (active), attached to Alice's room. The system's mute and the
//    microphone publication stay in step both ways: SystemCall.setMuted
//    (CallKit's mute action; on Android the global microphone mute) mutes
//    the publication, the publication's mute updates the call; on Android
//    the test also flips the global microphone mute behind the package's
//    back, as Telecom, a car or a watch would. Holding interrupts the
//    room's audio (CallInterruptionReason.held) and unholding resumes it,
//    with audio both ways again: a quick hold (on iOS CallKit's session
//    deactivation then arrives after the unhold) and a hold of 4 s.
//    On Android the routes are Telecom's endpoints (UUID IDs): the speaker
//    and the earpiece are selected through them. Ending the call leaves the
//    room and, on Android, stops the foreground service.
// 2. An incoming call: reported (ringing), answered in code rather than in
//    the system's UI (answered event, active), then the same room checks,
//    and ended by leaving the room.
//
// 3. Android: the call notification (the incoming one has a full-screen
//    intent, Answer and Decline; the ongoing one Hang up), pressed through
//    its own PendingIntents as a tap would: Answer answers (through the
//    app's activity), Hang up and Decline end the call.
// 4. Android, with the driver: Telecom ending a ringing call, through the
//    example's companion InCallService (debug builds; the driver allows
//    its app op): a reject, as a watch's Decline, is `declined`; a
//    disconnect, the path Telecom takes to make room for an emergency call
//    or a phone call, is `failed`.
// 5. Android, with the driver: an incoming call reported while the app is
//    in the background (as an FCM handler would) still rings with its
//    full-screen notification.
//
// Where the platforms differ, so do the expectations: the native
// `endpoints` method is Android's (null on iOS), and the foreground service
// is Android's. Answering from the lock screen, the notification's Answer
// and Decline, the system's own mute button, and a real phone call holding
// the call need a person (docs/checkpoint.md).
//
// On Android, system_call_test_driver.sh runs it and prints what Telecom
// and the service look like at each "CHECK TELECOM" in the log:
//
//   ANDROID_SERIAL=<android-id> integration_test/system_call_test_driver.sh \
//     --dart-define=CF_REALTIME_BROKER_URL=http://<dev server>:8787 \
//     --dart-define=CF_REALTIME_BROKER_TOKEN=<dev token> \
//     --dart-define=CF_REALTIME_BROKER_USER=it-android
//
// `flutter test integration_test/system_call_test.dart` alone works too.
// Skipped unless CF_REALTIME_BROKER_URL is set (see broker_settings.dart),
// and on desktops and the web. The test never prints the settings.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

const _timeout = Duration(seconds: 30);
const _callService = 'dev.kammcs.cloudflare_realtime.CallService';
const _support = MethodChannel('example/test_support');
const _native = MethodChannel('dev.kammcs.cloudflare_realtime/system_calls');
// Set by system_call_test_driver.sh, which presses Home and comes back.
const _driven = String.fromEnvironment('CF_REALTIME_SYSTEM_CALL_DRIVER');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();
  final android = !kIsWeb && Platform.isAndroid;
  final ios = !kIsWeb && Platform.isIOS;
  final phone = android || ios;
  final calls = SystemCalls.instance;

  /// Asks for the microphone before joining: the SFU drops a session left
  /// unused while a first-run prompt waits.
  Future<void> permissions() async {
    final mic = MicrophoneSource();
    await mic.enable();
    await mic.dispose();
  }

  /// Alice and Bob in one room; Bob pulls everything.
  Future<(Room, Room)> join(String test) async {
    final realtime = CloudflareRealtime(broker: settings.brokerOptions());
    final hub = InMemorySignalingHub();
    const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final alice = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: '$test-alice-$suffix',
      options: options,
    );
    addTearDown(() async {
      if (!alice.hasLeft) await alice.leave();
    });
    final bob = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: '$test-bob-$suffix',
      options: options,
    );
    addTearDown(bob.leave);
    return (alice, bob);
  }

  Future<void> configure() async {
    expect(await calls.configure(), isTrue, reason: 'system calls supported');
    expect(calls.isSupported, isTrue);
    addTearDown(() async {
      for (final call in calls.calls) {
        await call.end();
      }
    });
  }

  /// The checks a joined room with its system call goes through: mute in
  /// step both ways, hold and unhold, the routes.
  Future<void> inCall(SystemCall call, Room alice, Room bob) async {
    final events = _EventQueue(alice.events);
    addTearDown(events.cancel);
    alice.attachSystemCall(call);
    final mic = await alice.localParticipant.publishMicrophone();
    await mic.publication.whenSending().timeout(_timeout);
    expect(call.isMuted, isFalse);
    expect(mic.isMuted, isFalse);
    await _rising(alice, bob, 'in the call');
    if (android) await _checkTelecom('active');

    // The system's mute mutes the publication...
    await call.setMuted(true);
    await _until(() => mic.isMuted, 'the system mute mutes the microphone');
    expect(call.isMuted, isTrue);
    await call.setMuted(false);
    await _until(() => !mic.isMuted, 'the system unmute unmutes it');
    expect(call.isMuted, isFalse);
    // ...and the publication's mute the system's.
    await mic.setMuted(true);
    await _until(() => call.isMuted, "muting the microphone mutes the call");
    await mic.setMuted(false);
    await _until(() => !call.isMuted, 'and unmuting it unmutes the call');
    if (android) {
      // Telecom (a car, a watch) mutes the global microphone.
      expect(
        await _support.invokeMethod<bool>('setMicrophoneMute', {'muted': true}),
        isTrue,
      );
      await _until(() => call.isMuted, "Telecom's mute reaches the call");
      await _until(() => mic.isMuted, 'and the microphone');
      await _support.invokeMethod<bool>('setMicrophoneMute', {'muted': false});
      await _until(() => !call.isMuted, "Telecom's unmute reaches the call");
      await _until(() => !mic.isMuted, 'and the microphone');
    }
    _log('mute in step both ways');
    await _rising(alice, bob, 'after the mutes');

    // Hold: the room's audio is interrupted, then resumed. First a quick
    // hold (on iOS, CallKit's deactivation of the session then arrives
    // after the unhold), then one of a few seconds, as a person would.
    for (final (name, holdFor) in [
      ('quick hold', Duration.zero),
      ('hold of 4 s', const Duration(seconds: 4)),
    ]) {
      await call.setHeld(true);
      await _until(
        () => call.state == SystemCallState.held,
        '$name: the call is held',
      );
      final interrupted = await events.next<RoomAudioInterruptedEvent>();
      expect(interrupted.reason, CallInterruptionReason.held);
      expect(alice.audioInterruption, CallInterruptionReason.held);
      if (android && holdFor == Duration.zero) await _checkTelecom('held');
      await Future<void>.delayed(holdFor);
      expect(alice.audioInterruption, CallInterruptionReason.held);
      await call.setHeld(false);
      await _until(
        () => call.state == SystemCallState.active,
        '$name: the call is active again',
      );
      final resumed = await events.next<RoomAudioResumedEvent>();
      expect(resumed.reason, CallInterruptionReason.held);
      expect(alice.audioInterruption, isNull);
      _log('$name: held and resumed');
      await _rising(alice, bob, 'after the $name');
      // Late events from the hold (iOS: the session's deactivation and
      // activation) don't interrupt the room again.
      expect(alice.audioInterruption, isNull, reason: 'after the $name');
    }

    // The routes: Telecom's endpoints on Android, the platform's on iOS.
    final endpoints = await _native.invokeMapMethod<String, Object?>(
      'endpoints',
      {'id': call.id},
    );
    if (android) {
      expect(endpoints, isNotNull);
      final routes = endpoints!['routes']! as List;
      _log('endpoints: ${routes.length}, current ${endpoints['current']}');
      expect(routes, isNotEmpty);
      for (final route in routes) {
        expect((route as Map)['id'], matches(_uuid), reason: 'a Telecom UUID');
      }
    } else {
      expect(endpoints, isNull, reason: 'iOS has no endpoints');
    }
    await _until(() => alice.audioRoutes.isNotEmpty, 'the routes are listed');
    _log(
      'routes: ${alice.audioRoutes.map((r) => r.kind.name)}, '
      'current ${alice.audioRoute?.kind.name}',
    );
    if (android) {
      for (final route in alice.audioRoutes) {
        expect(route.id, matches(_uuid), reason: 'routes are endpoints');
      }
    }
    for (final kind in [AudioRouteKind.speaker, AudioRouteKind.earpiece]) {
      final route = alice.audioRoutes.where((r) => r.kind == kind).firstOrNull;
      if (route == null) {
        // The earpiece isn't listed while a headset is connected.
        _log('no ${kind.name} listed (a headset is connected?)');
        continue;
      }
      await alice.selectAudioRoute(route);
      await _until(
        () => alice.audioRoute?.kind == kind,
        'the ${kind.name} is selected',
      );
      _log('selected the ${kind.name}');
      if (android) {
        final now = await _native.invokeMapMethod<String, Object?>(
          'endpoints',
          {'id': call.id},
        );
        expect((now!['current']! as Map)['kind'], kind.name);
      }
    }
    await _rising(alice, bob, 'after the route changes');
  }

  testWidgets(
    'an outgoing system call: connect, mute, hold, routes, end',
    (tester) async {
      await permissions();
      await configure();

      final call = await calls.startOutgoingCall(
        handle: const CallHandle('integration-test'),
        displayName: 'Integration test',
      );
      expect(call.isOutgoing, isTrue);
      expect(call.state, SystemCallState.dialing);
      expect(calls.calls, contains(call));
      final listed = await _native.invokeListMethod<Map<Object?, Object?>>(
        'activeCalls',
      );
      expect(listed!.map((c) => c['id']), contains(call.id));
      if (android) {
        await _eventually(
          () async => (await _foregroundServices()).contains(_callService),
          'the call service runs for the system call',
        );
        await _checkTelecom('dialing');
      }
      await call.reportConnecting();
      expect(call.state, SystemCallState.connecting);
      await call.reportConnected();
      expect(call.state, SystemCallState.active);

      final (alice, bob) = await join('system-out');
      await inCall(call, alice, bob);

      // Ending the call leaves the room.
      await call.end();
      expect(await call.whenEnded.timeout(_timeout), SystemCallEndReason.local);
      expect(call.state, SystemCallState.ended);
      await _until(() => alice.hasLeft, 'the room leaves with the call');
      expect(calls.calls, isEmpty);
      if (android) {
        // Bob publishes nothing: no service is left.
        await _eventually(
          () async => !(await _foregroundServices()).contains(_callService),
          'the call service stops',
        );
        await _checkTelecom('ended');
      }
      expect(await _native.invokeListMethod<Object?>('activeCalls'), isEmpty);
    },
    skip: settings.skip || !phone,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets(
    'an incoming system call answered in code',
    (tester) async {
      await permissions();
      await configure();
      final events = <SystemCallEvent>[];
      final sub = calls.events.listen(events.add);
      addTearDown(sub.cancel);

      final call = await calls.reportIncomingCall(
        handle: const CallHandle('integration-test'),
        displayName: 'Integration test',
        payload: {'room': settings.room},
      );
      expect(call.isOutgoing, isFalse);
      expect(call.state, SystemCallState.ringing);
      if (android) {
        await _eventually(
          () async => (await _foregroundServices()).contains(_callService),
          'the call service runs while it rings',
        );
        await _checkTelecom('ringing');
      }

      await call.answer();
      await _until(
        () => call.state == SystemCallState.active,
        'the answered call is active',
      );
      expect(events.whereType<SystemCallAnsweredEvent>(), hasLength(1));
      // A second answer is refused: it isn't ringing any more.
      await expectLater(call.answer(), throwsStateError);

      final (alice, bob) = await join('system-in');
      await inCall(call, alice, bob);

      // Leaving the room ends the call.
      await alice.leave();
      expect(await call.whenEnded.timeout(_timeout), SystemCallEndReason.local);
      expect(events.whereType<SystemCallEndedEvent>().map((e) => e.reason), [
        SystemCallEndReason.local,
      ]);
      expect(calls.calls, isEmpty);
      if (android) {
        await _eventually(
          () async => !(await _foregroundServices()).contains(_callService),
          'the call service stops',
        );
        await _checkTelecom('ended');
      }
    },
    skip: settings.skip || !phone,
    timeout: const Timeout(Duration(minutes: 4)),
  );

  testWidgets('an incoming system call declined while ringing', (tester) async {
    await configure();
    final call = await calls.reportIncomingCall(
      handle: const CallHandle.emailAddress('caller@example.com'),
      video: true,
    );
    expect(call.state, SystemCallState.ringing);
    await call.end();
    expect(
      await call.whenEnded.timeout(_timeout),
      SystemCallEndReason.declined,
    );
    expect(calls.calls, isEmpty);
    if (android) {
      await _eventually(
        () async => !(await _foregroundServices()).contains(_callService),
        'the call service stops',
      );
    }
  }, skip: settings.skip || !phone);

  testWidgets("the call notification's Answer, Hang up and Decline (Android)", (
    tester,
  ) async {
    await configure();
    final events = <SystemCallEvent>[];
    final sub = calls.events.listen(events.add);
    addTearDown(sub.cancel);

    // Answer, then Hang up, in the notification.
    var call = await calls.reportIncomingCall(
      handle: const CallHandle('integration-test'),
      displayName: 'Notification test',
    );
    await _eventually(
      () async => (await _callNotifications()).isNotEmpty,
      'the incoming call notification is posted',
    );
    final incoming = (await _callNotifications()).single;
    _log('incoming notification: $incoming');
    expect(incoming['channel'], 'cloudflare_realtime_incoming_call');
    expect(incoming['title'], 'Notification test');
    expect(incoming['fullScreen'], isTrue);
    expect(incoming['answer'], isTrue);
    expect(incoming['decline'], isTrue);
    expect(await _notificationAction('answer'), isTrue);
    await _until(
      () => call.state == SystemCallState.active,
      "the notification's Answer answers",
    );
    expect(events.whereType<SystemCallAnsweredEvent>(), hasLength(1));
    await _eventually(() async {
      final shown = await _callNotifications();
      return shown.length == 1 && shown.single['hangUp'] == true;
    }, 'the ongoing notification has Hang up');
    _log('ongoing notification: ${(await _callNotifications()).single}');
    expect(await _notificationAction('hangUp'), isTrue);
    expect(await call.whenEnded.timeout(_timeout), SystemCallEndReason.local);
    await _eventually(
      () async => (await _callNotifications()).isEmpty,
      'the notification goes with the call',
    );

    // Decline in the notification.
    call = await calls.reportIncomingCall(
      handle: const CallHandle.phoneNumber('+15550100'),
      video: true,
    );
    await _eventually(
      () async => (await _callNotifications()).isNotEmpty,
      'the incoming call notification is posted',
    );
    expect(await _notificationAction('decline'), isTrue);
    expect(
      await call.whenEnded.timeout(_timeout),
      SystemCallEndReason.declined,
    );
    await _eventually(
      () async => !(await _foregroundServices()).contains(_callService),
      'the call service stops',
    );
    expect(await _callNotifications(), isEmpty);
  }, skip: !android);

  testWidgets(
    'a ringing call Telecom ends: declined only for a reject (Android)',
    (tester) async {
      await configure();
      // The driver allows the app op that lets Telecom bind the example's
      // companion InCallService (a watch's or a car's, in effect).
      _log('COMPANION NOW');
      await Future<void>.delayed(const Duration(seconds: 3));

      Future<SystemCallEndReason> endFromTelecom(String how) async {
        final call = await calls.reportIncomingCall(
          handle: const CallHandle('integration-test'),
          displayName: 'Telecom $how',
        );
        await _eventually(
          () async =>
              await _support.invokeMethod<bool>('companionSeesRingingCall') ==
              true,
          'Telecom shows the ringing call to the companion',
        );
        expect(
          await _support.invokeMethod<bool>('companionEndRingingCall', {
            'how': how,
          }),
          isTrue,
        );
        final reason = await call.whenEnded.timeout(_timeout);
        _log('a ringing call Telecom ended with $how: ${reason.name}');
        return reason;
      }

      // A person declining it on a watch, a car or a headset: Telecom's
      // reject.
      expect(await endFromTelecom('reject'), SystemCallEndReason.declined);
      // Telecom's disconnect, the path it takes when it makes room for an
      // emergency call or a phone call the user places: nobody declined.
      expect(await endFromTelecom('disconnect'), SystemCallEndReason.failed);
      expect(calls.calls, isEmpty);
      await _eventually(
        () async => !(await _foregroundServices()).contains(_callService),
        'the call service stops',
      );
    },
    skip: !android || _driven != '1',
  );

  testWidgets(
    'an incoming call reported from the background (Android)',
    (tester) async {
      await configure();
      final lifecycle = _Lifecycle();
      addTearDown(lifecycle.dispose);
      _log('BACKGROUND NOW');
      await lifecycle.next(AppLifecycleState.paused);

      // As a high-priority FCM message's handler would.
      final call = await calls.reportIncomingCall(
        handle: const CallHandle('integration-test'),
        displayName: 'Background test',
      );
      expect(call.state, SystemCallState.ringing);
      await _eventually(
        () async => (await _callNotifications()).isNotEmpty,
        'the incoming call notification is posted from the background',
      );
      final shown = (await _callNotifications()).single;
      _log(
        'in the background: $shown, services ${await _foregroundServices()}',
      );
      expect(shown['fullScreen'], isTrue);
      await _checkTelecom('ringing, reported in the background');
      await call.end(SystemCallEndReason.unanswered);
      expect(
        await call.whenEnded.timeout(_timeout),
        SystemCallEndReason.unanswered,
      );
      await _eventually(
        () async => (await _callNotifications()).isEmpty,
        'the notification goes with the call',
      );
      _log('FOREGROUND NOW');
      await lifecycle.next(AppLifecycleState.resumed);
    },
    skip: !android || _driven != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

final RegExp _uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

void _log(String message) => debugPrint('[system_call_test] $message');

/// Asks the driver script to print Telecom's state and the services.
Future<void> _checkTelecom(String when) async {
  _log('CHECK TELECOM ($when)');
  // Gives the driver (polling every second) time to look.
  await Future<void>.delayed(const Duration(seconds: 2));
}

/// The app's call notifications (Android): channel, title, and whether it
/// has a full-screen intent and Answer, Decline or Hang up.
Future<List<Map<Object?, Object?>>> _callNotifications() async =>
    await _support.invokeListMethod<Map<Object?, Object?>>(
      'callNotifications',
    ) ??
    [];

/// Presses Answer, Decline or Hang up in the call notification (its own
/// PendingIntent, as a tap would).
Future<bool?> _notificationAction(String action) => _support.invokeMethod<bool>(
  'sendCallNotificationAction',
  {'action': action},
);

Future<List<String>> _foregroundServices() async =>
    await _support.invokeListMethod<String>('foregroundServices') ?? [];

Future<void> _eventually(Future<bool> Function() check, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await check()) {
    if (DateTime.now().isAfter(deadline)) fail(what);
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
}

Future<void> _until(bool Function() check, String what) =>
    _eventually(() async => check(), what);

/// Waits until Alice has sent, and Bob received, more audio.
Future<void> _rising(Room alice, Room bob, String when) async {
  Future<(num, num)> read() async {
    num sent = 0, received = 0;
    num value(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
    for (final r in await alice.session.getStats()) {
      final kind = r.values['kind'] ?? r.values['mediaType'];
      if (r.type == 'outbound-rtp' && kind == 'audio') {
        sent += value(r.values['packetsSent']);
      }
    }
    for (final r in await bob.session.getStats()) {
      final kind = r.values['kind'] ?? r.values['mediaType'];
      if (r.type == 'inbound-rtp' && kind == 'audio') {
        received += value(r.values['packetsReceived']);
      }
    }
    return (sent, received);
  }

  final (sent0, received0) = await read();
  final deadline = DateTime.now().add(_timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final (sent, received) = await read();
    if (received - received0 >= 25) {
      _log(
        '$when: audio sent +${sent - sent0}, received +'
        '${received - received0}',
      );
      return;
    }
  }
  fail('$when: Bob receives no audio from Alice');
}

/// The app's lifecycle states as they arrive.
class _Lifecycle {
  _Lifecycle() {
    _listener = AppLifecycleListener(onStateChange: _states.add);
  }

  late final AppLifecycleListener _listener;
  final StreamController<AppLifecycleState> _states =
      StreamController.broadcast();

  /// Waits for [state] (or, for paused, hidden: the app left the screen).
  Future<void> next(AppLifecycleState state) => _states.stream
      .firstWhere(
        (s) =>
            s == state ||
            (state == AppLifecycleState.paused &&
                s == AppLifecycleState.hidden),
      )
      .timeout(const Duration(minutes: 2));

  void dispose() {
    _listener.dispose();
    unawaited(_states.close());
  }
}

/// A room's events, kept until taken: waits for the next event of a type.
class _EventQueue {
  _EventQueue(Stream<RoomEvent> events) {
    _sub = events.listen((event) {
      _buffer.add(event);
      _arrived.add(null);
    });
  }

  late final StreamSubscription<RoomEvent> _sub;
  final List<RoomEvent> _buffer = [];
  final StreamController<void> _arrived = StreamController.broadcast();

  /// The next [T], dropping the events before it.
  Future<T> next<T extends RoomEvent>() async {
    final deadline = DateTime.now().add(_timeout);
    while (true) {
      final i = _buffer.indexWhere((e) => e is T);
      if (i >= 0) {
        final event = _buffer[i] as T;
        _buffer.removeRange(0, i + 1);
        return event;
      }
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) fail('no $T within $_timeout');
      await _arrived.stream.first.timeout(left, onTimeout: () {});
    }
  }

  Future<void> cancel() async {
    await _sub.cancel();
    await _arrived.close();
  }
}
