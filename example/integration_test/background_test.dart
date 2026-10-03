// Calls that survive the phone (docs/design.md §4.7), through a real
// broker. Two rooms in one process share in-memory signaling: Alice
// publishes her microphone and camera, Bob pulls them.
//
// 1. Background (phones). Android: the package's foreground service runs
//    while Alice publishes (CallService, in the foreground, types
//    microphone and camera), and the app goes to the background for 20 s:
//    Alice's outbound audio packets, microphone energy and encoded video
//    frames, and Bob's received audio and decoded frames, must keep
//    rising. iOS: the audio must keep flowing and the camera must be
//    reported paused (RoomCameraPausedEvent, background), then resumed.
//    The test logs `BACKGROUND NOW` and waits up to 2 minutes for the app
//    to go to the background, then `FOREGROUND NOW` and waits for it to
//    come back: on Android, background_test_driver.sh does both with adb
//    (`input keyevent KEYCODE_HOME`, then `am start`); on an iPhone a
//    person does (swipe home, then reopen the app), and only with
//    CF_REALTIME_BACKGROUND_MANUAL=1, else that test is skipped there.
//    Finally the service follows the publications: still running with the
//    microphone alone, gone once nothing is published.
// 2. Interruptions (Android): the example's MainActivity takes the audio
//    focus as another client would (a media player, an assistant). A
//    transient loss interrupts the call (RoomAudioInterruptedEvent, otherAudio)
//    and getting the focus back resumes it (RoomAudioResumedEvent); after a
//    permanent loss, Room.resumeAudio() takes it back. Bob must hear Alice
//    again afterwards. A phone call or Siri needs a person (checkpoint.md).
// 3. The proximity sensor (phones): on for a voice call on the earpiece,
//    off on the speaker and with video (off throughout with a headset, or
//    on a device without an earpiece). Whether the screen really turns off
//    needs a hand over the sensor; on Android, `adb shell dumpsys power`
//    lists the PROXIMITY_SCREEN_OFF_WAKE_LOCK while it is on.
//
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
const _lifecycleTimeout = Duration(minutes: 2);
const _backgroundFor = Duration(seconds: 20);
const _manualBackground = String.fromEnvironment(
  'CF_REALTIME_BACKGROUND_MANUAL',
);
const _callService = 'dev.kammcs.cloudflare_realtime.CallService';
const _support = MethodChannel('example/test_support');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();
  final android = !kIsWeb && Platform.isAndroid;
  final ios = !kIsWeb && Platform.isIOS;
  final phone = android || ios;

  /// Asks for the microphone and camera before joining: the SFU drops a
  /// session left unused while a first-run prompt waits.
  Future<void> permissions() async {
    final mic = MicrophoneSource();
    await mic.enable();
    await mic.dispose();
    final camera = CameraSource();
    await camera.enable();
    await camera.dispose();
  }

  /// Alice and Bob in one room; Bob pulls everything.
  Future<(Room, Room)> join(String test) async {
    final realtime = CloudflareRealtime(broker: settings.config());
    final hub = InMemorySignalingHub();
    const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final alice = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: '$test-alice-$suffix',
      options: options,
    );
    addTearDown(alice.leave);
    final bob = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: '$test-bob-$suffix',
      options: options,
    );
    addTearDown(bob.leave);
    return (alice, bob);
  }

  testWidgets(
    'the call keeps going in the background',
    (tester) async {
      await permissions();
      final (alice, bob) = await join('background');
      final events = <RoomEvent>[];
      final sub = alice.events.listen(events.add);
      addTearDown(sub.cancel);
      final lifecycle = _Lifecycle();
      addTearDown(lifecycle.dispose);

      final mic = await alice.localParticipant.publishMicrophone();
      final camera = await alice.localParticipant.publishCamera(
        options: const CameraOptions(preset: VideoPreset.h360),
      );
      await mic.publication.whenSending().timeout(_timeout);
      await camera.publication.whenSending().timeout(_timeout);
      await _rising(alice, bob, 'in the foreground', video: true);
      if (android) {
        expect(await _foregroundServices(), contains(_callService));
        _log('CHECK SERVICES');
      }

      _log('BACKGROUND NOW');
      await lifecycle.next(AppLifecycleState.paused);
      _log('in the background');
      final start = await _Counters.read(alice, bob);
      var previous = start;
      final steps = _backgroundFor.inSeconds ~/ 5;
      for (var i = 0; i < steps; i++) {
        await Future<void>.delayed(const Duration(seconds: 5));
        final now = await _Counters.read(alice, bob);
        _log('background +${(i + 1) * 5} s: ${now.since(previous)}');
        expect(
          now.audioSent,
          greaterThan(previous.audioSent),
          reason: 'Alice sends audio in the background',
        );
        expect(
          now.audioReceived,
          greaterThan(previous.audioReceived),
          reason: 'Bob receives it',
        );
        if (android) {
          expect(
            now.audioEnergy,
            greaterThan(previous.audioEnergy),
            reason: 'the microphone is not silenced',
          );
          expect(
            now.framesEncoded,
            greaterThan(previous.framesEncoded),
            reason: 'the camera keeps capturing',
          );
          expect(now.framesDecoded, greaterThan(previous.framesDecoded));
        }
        previous = now;
      }
      if (android) _log('CHECK SERVICES');
      if (ios) {
        expect(alice.cameraPause, CameraPauseReason.background);
        expect(
          events.whereType<RoomCameraPausedEvent>().map((e) => e.reason),
          contains(CameraPauseReason.background),
        );
      }

      _log('FOREGROUND NOW');
      await lifecycle.next(AppLifecycleState.resumed);
      _log('back in the foreground');
      await _rising(alice, bob, 'back in the foreground', video: true);
      if (ios) {
        expect(events.whereType<RoomCameraResumedEvent>(), isNotEmpty);
        expect(alice.cameraPause, isNull);
      }

      if (android) {
        await camera.unpublish();
        await Future<void>.delayed(const Duration(seconds: 1));
        expect(
          await _foregroundServices(),
          contains(_callService),
          reason: 'the microphone is still published',
        );
        _log('CHECK SERVICES');
        await mic.unpublish();
        await _eventually(
          () async => !(await _foregroundServices()).contains(_callService),
          'the service stops when nothing is published',
        );
        _log('CHECK SERVICES');
      }
    },
    skip: settings.skip || !(android || (ios && _manualBackground == '1')),
    timeout: const Timeout(Duration(minutes: 7)),
  );

  testWidgets(
    'losing the audio focus interrupts the call; getting it back resumes it',
    (tester) async {
      await permissions();
      final (alice, bob) = await join('focus');
      expect(alice.canDetectAudioInterruptions, isTrue);
      final events = _EventQueue(alice.events);
      addTearDown(events.cancel);
      addTearDown(() => _support.invokeMethod<void>('releaseAudioFocus'));

      final mic = await alice.localParticipant.publishMicrophone();
      await mic.publication.whenSending().timeout(_timeout);
      await _rising(alice, bob, 'before');

      // A transient loss, then the focus comes back by itself.
      expect(
        await _support.invokeMethod<bool>('takeAudioFocus', {
          'transient': true,
        }),
        isTrue,
      );
      final interrupted = await events.next<RoomAudioInterruptedEvent>();
      _log('interrupted: ${interrupted.reason.name}');
      expect(interrupted.reason, CallInterruptionReason.otherAudio);
      expect(alice.audioInterruption, CallInterruptionReason.otherAudio);
      expect(mic.isMuted, isFalse, reason: 'not announced as muted');
      await _support.invokeMethod<void>('releaseAudioFocus');
      final resumed = await events.next<RoomAudioResumedEvent>();
      _log('resumed after ${resumed.reason.name}');
      expect(alice.audioInterruption, isNull);
      await _rising(alice, bob, 'after a transient loss');

      // A permanent loss: Android doesn't give the focus back, so the app
      // takes it (as the room also does when the app returns to the
      // foreground).
      expect(
        await _support.invokeMethod<bool>('takeAudioFocus', {
          'transient': false,
        }),
        isTrue,
      );
      await events.next<RoomAudioInterruptedEvent>();
      await _support.invokeMethod<void>('releaseAudioFocus');
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(alice.audioInterruption, isNotNull, reason: 'no focus back');
      expect(await alice.resumeAudio(), isTrue);
      await events.next<RoomAudioResumedEvent>();
      await _rising(alice, bob, 'after resumeAudio()');
    },
    skip: settings.skip || !android,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'the proximity sensor is on for a voice call on the earpiece only',
    (tester) async {
      await permissions();
      final (alice, _) = await join('proximity');
      await alice.localParticipant.publishMicrophone();
      final headset = alice.audioRoutes.any((r) => r.kind.isExternal);
      if (headset) {
        _log('a headset is connected: the sensor stays off');
        expect(alice.isProximitySensorActive, isFalse);
        return;
      }
      // A tablet or an emulator has no earpiece: its voice calls play on
      // the speaker, where the sensor stays off.
      if (!alice.audioRoutes.any((r) => r.kind == AudioRouteKind.earpiece)) {
        _log('no earpiece: the sensor stays off');
        await _expectProximity(alice, false, 'a voice call on the speaker');
        return;
      }
      await _expectProximity(alice, true, 'a voice call on the earpiece');
      _log('CHECK PROXIMITY on');
      await alice.setSpeakerphone(true);
      await _expectProximity(alice, false, 'on the speaker');
      await alice.setSpeakerphone(false);
      await _expectProximity(alice, true, 'back on the earpiece');
      await alice.localParticipant.publishCamera(
        options: const CameraOptions(preset: VideoPreset.h360),
      );
      await _expectProximity(alice, false, 'with video');
      _log('CHECK PROXIMITY off');
    },
    skip: settings.skip || !phone,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

void _log(String message) => debugPrint(
  '[background] ${DateTime.now().toIso8601String().substring(11, 19)} '
  '$message',
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

Future<void> _expectProximity(Room room, bool on, String when) async {
  final active = await room.proximitySensorActiveChanges
      .firstWhere((value) => value == on)
      .timeout(const Duration(seconds: 5), onTimeout: () => !on);
  _log(
    'proximity $when: ${room.isProximitySensorActive} '
    '(route ${room.audioRoute})',
  );
  expect(active, on, reason: 'proximity sensor $when');
}

/// Waits until Alice has sent, and Bob received, more audio (and video).
Future<void> _rising(
  Room alice,
  Room bob,
  String when, {
  bool video = false,
}) async {
  final start = await _Counters.read(alice, bob);
  final deadline = DateTime.now().add(_timeout);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final now = await _Counters.read(alice, bob);
    final d = now.since(start);
    if (d.audioReceived >= 25 &&
        (!video || (d.framesEncoded >= 10 && d.framesDecoded >= 10))) {
      _log('$when: $d');
      return;
    }
  }
  fail('$when: ${(await _Counters.read(alice, bob)).since(start)}');
}

/// Alice's outbound and Bob's inbound counters, from getStats().
class _Counters {
  _Counters({
    required this.audioSent,
    required this.audioEnergy,
    required this.framesEncoded,
    required this.audioReceived,
    required this.framesDecoded,
  });

  static Future<_Counters> read(Room alice, Room bob) async {
    num audioSent = 0, energy = 0, encoded = 0, received = 0, decoded = 0;
    num value(Object? v) => v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
    for (final r in await alice.session.getStats()) {
      final kind = r.values['kind'] ?? r.values['mediaType'];
      if (r.type == 'outbound-rtp' && kind == 'audio') {
        audioSent += value(r.values['packetsSent']);
      } else if (r.type == 'outbound-rtp' && kind == 'video') {
        encoded += value(r.values['framesEncoded']);
      } else if (r.type == 'media-source' && kind == 'audio') {
        energy += value(r.values['totalAudioEnergy']);
      }
    }
    for (final r in await bob.session.getStats()) {
      final kind = r.values['kind'] ?? r.values['mediaType'];
      if (r.type == 'inbound-rtp' && kind == 'audio') {
        received += value(r.values['packetsReceived']);
      } else if (r.type == 'inbound-rtp' && kind == 'video') {
        decoded += value(r.values['framesDecoded']);
      }
    }
    return _Counters(
      audioSent: audioSent,
      audioEnergy: energy,
      framesEncoded: encoded,
      audioReceived: received,
      framesDecoded: decoded,
    );
  }

  final num audioSent;
  final num audioEnergy;
  final num framesEncoded;
  final num audioReceived;
  final num framesDecoded;

  _Counters since(_Counters start) => _Counters(
    audioSent: audioSent - start.audioSent,
    audioEnergy: audioEnergy - start.audioEnergy,
    framesEncoded: framesEncoded - start.framesEncoded,
    audioReceived: audioReceived - start.audioReceived,
    framesDecoded: framesDecoded - start.framesDecoded,
  );

  @override
  String toString() =>
      'audio sent $audioSent, energy ${audioEnergy.toStringAsFixed(4)}, '
      'frames encoded $framesEncoded; Bob: audio $audioReceived, '
      'frames decoded $framesDecoded';
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
      .timeout(_lifecycleTimeout);

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
