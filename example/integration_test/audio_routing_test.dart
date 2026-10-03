// Call audio routing on phones, the same way on Android and iOS
// (docs/design.md §4.6), through a real broker:
//
// - a voice call starts on the earpiece (or a connected headset; the
//   speaker on a device without an earpiece, such as a tablet or an
//   emulator);
// - publishing a camera moves it to the speaker;
// - Room.selectAudioRoute picks a route, which sticks;
// - Room.setSpeakerphone forces the speaker or the earpiece;
// - choosing a microphone keeps the call sending audio.
//
// Desktops and browsers have no call audio routing, which the room
// reports (canSelectAudioRoute) instead of doing something else. In a
// browser the test also checks that Bob's pulled audio plays in the
// package's hidden <audio> element, and, where the browser supports
// setSinkId, that choosing each output device keeps it playing there.
// WebKit (Safari) refuses a non-default output without a user gesture,
// which a test can't give: there the refusal is expected, and the audio
// must keep playing on the output it had.
//
// Two rooms in one process share in-memory signaling: Alice publishes, Bob
// pulls. The route is read back from the platform; on iOS the test also
// checks it against flutter_webrtc's list of outputs, and on Android its
// log can be compared with `adb shell dumpsys audio` ("Active
// communication device").
//
// Skipped unless CF_REALTIME_BROKER_URL is set; see broker_settings.dart
// for the settings (including the dev server's X-Dev-User) and a command
// line. The test never prints them.

import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';
import 'support/web_audio_probe.dart';

const _timeout = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  testWidgets(
    'call audio routing and microphone choice',
    (tester) async {
      // Ask for the microphone (and camera) before joining: the SFU drops a session left
      // unused while a first-run prompt waits.
      final permission = MicrophoneSource();
      await permission.enable();
      await permission.dispose();
      if (_phone) {
        final camera = CameraSource();
        await camera.enable();
        await camera.dispose();
      }

      final realtime = CloudflareRealtime(broker: settings.brokerOptions());
      final hub = InMemorySignalingHub();
      const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'audio-alice-$suffix',
        options: options,
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'audio-bob-$suffix',
        options: options,
      );
      addTearDown(bob.leave);

      final phone = _phone;
      expect(alice.canSelectAudioRoute, phone);
      if (!phone) {
        await expectLater(alice.setSpeakerphone(false), throwsUnsupportedError);
        expect(alice.audioRoutes, isEmpty);
      }

      final published = await alice.localParticipant.publishMicrophone();
      await published.publication.whenSending().timeout(_timeout);
      await _audioArriving(bob, 'in a voice call');
      if (kIsWeb) await _webAudioPlays(bob, 'in a voice call');

      if (phone) {
        _log('routes: ${alice.audioRoutes.join('; ')}');
        // A connected headset comes first; then the default for the call.
        // Without an earpiece (a tablet, an emulator) the earpiece's calls
        // play on the speaker.
        final headset = alice.audioRoutes
            .where((r) => r.kind.isExternal)
            .firstOrNull;
        final hasEarpiece = alice.audioRoutes.any(
          (r) => r.kind == AudioRouteKind.earpiece,
        );
        if (!hasEarpiece) _log('no earpiece: the speaker stands in for it');
        AudioRouteKind expected(AudioRouteKind kind) =>
            headset?.kind ??
            (kind == AudioRouteKind.earpiece && !hasEarpiece
                ? AudioRouteKind.speaker
                : kind);

        await _expectRoute(alice, expected(AudioRouteKind.earpiece), 'voice');

        final camera = await alice.localParticipant.publishCamera(
          options: const CameraOptions(preset: VideoPreset.h360),
        );
        await camera.publication.whenSending().timeout(_timeout);
        await _expectRoute(alice, expected(AudioRouteKind.speaker), 'video');

        final earpiece = alice.audioRoutes
            .where((r) => r.kind == AudioRouteKind.earpiece)
            .firstOrNull;
        if (earpiece != null) {
          await alice.selectAudioRoute(earpiece);
          await _expectRoute(alice, AudioRouteKind.earpiece, 'picked');
          await _audioArriving(bob, 'on the earpiece');
        }
        await alice.setSpeakerphone(true);
        await _expectRoute(
          alice,
          expected(AudioRouteKind.speaker),
          'setSpeakerphone(true)',
        );
        await alice.setSpeakerphone(false);
        await _expectRoute(
          alice,
          expected(AudioRouteKind.earpiece),
          'setSpeakerphone(false)',
        );
        await alice.setSpeakerphone(true);
      }

      // Each microphone in turn, then back to the first.
      final mic = published.mediaSource as MicrophoneSource;
      _log('microphones: ${mic.devices.map((m) => '"${m.label}"').join('; ')}');
      final mics = mic.devices.where(settings.mayOpenMicrophone).toList();
      if (settings.microphones != null) {
        _log('only: ${mics.map((m) => '"${m.label}"').join('; ')}');
      }
      if (mics.length < 2) _log('only one microphone: nothing to switch to');
      for (final device in [...mics.skip(1), if (mics.length > 1) mics.first]) {
        await mic.setPreferredDevice(device);
        expect(mic.track?.device?.sameDeviceAs(device), isTrue);
        _log('microphone "${device.label}" (${device.deviceId})');
        await _audioArriving(bob, 'from "${device.label}"');
      }

      if (kIsWeb) await _webOutputs(bob);
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// A phone (call audio routing); never a browser, which has no `Platform`.
final bool _phone = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

/// In a browser: Bob's pulled audio has an `<audio>` element that plays
/// (not paused, its clock moving) a live track, or the autoplay policy
/// blocked it and the room says so.
Future<void> _webAudioPlays(Room bob, String when, {String? sinkId}) async {
  List<WebAudioElement> playing() => [
    for (final e in remoteAudioElements())
      if (!e.paused && e.liveAudioTracks > 0) e,
  ];
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (playing().isEmpty && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  final before = playing();
  _log(
    '$when: audio elements ${remoteAudioElements()}, '
    'blocked: ${bob.isAudioPlaybackBlocked}',
  );
  expect(
    bob.isAudioPlaybackBlocked,
    isFalse,
    reason: 'the autoplay policy blocked the call audio',
  );
  expect(before, isNotEmpty, reason: '$when: no <audio> element plays');
  await Future<void>.delayed(const Duration(seconds: 1));
  final after = playing();
  expect(
    after.any((a) => before.any((b) => a.currentTime > b.currentTime)),
    isTrue,
    reason: '$when: the <audio> element\'s clock stands still',
  );
  if (sinkId != null) {
    expect(after.map((e) => e.sinkId), everyElement(sinkId), reason: when);
  }
}

/// In a browser: each audio output in turn through `setSinkId`, where the
/// browser supports it; [Room.setAudioOutputDevice] throws where it doesn't.
/// WebKit may refuse an output (an [AudioOutputException] with
/// [AudioOutputFailure.needsUserGesture]: no user gesture); the room must
/// then keep the previous one.
Future<void> _webOutputs(Room bob) async {
  final outputs = [
    for (final d in await rtc.navigator.mediaDevices.enumerateDevices())
      if (d.kind == 'audiooutput') d,
  ];
  _log(
    'canSelectAudioOutput: ${bob.canSelectAudioOutput}; outputs: '
    '${outputs.map((d) => '"${d.label}" (${d.deviceId})').join('; ')}',
  );
  if (!bob.canSelectAudioOutput) {
    await expectLater(
      bob.setAudioOutputDevice('default'),
      throwsUnsupportedError,
    );
    return;
  }
  // The elements' `sinkId` until one is accepted: the default.
  var current = '';
  for (final output in [...outputs.skip(1), ...outputs.take(1)]) {
    try {
      await bob.setAudioOutputDevice(output.deviceId);
    } on AudioOutputException catch (error) {
      // Chrome and Firefox accept every output: anything thrown there fails.
      if (!isWebKitBrowser() ||
          error.reason != AudioOutputFailure.needsUserGesture) {
        rethrow;
      }
      _log(
        'output "${output.label}" refused without a user gesture '
        '(WebKit): $error',
      );
      await _webAudioPlays(
        bob,
        'after output "${output.label}" was refused',
        sinkId: current,
      );
      continue;
    }
    current = output.deviceId;
    await _webAudioPlays(
      bob,
      'on output "${output.label}"',
      sinkId: output.deviceId,
    );
  }
}

void _log(String message) => debugPrint(
  '[audio] ${DateTime.now().toIso8601String().substring(11, 19)} $message',
);

/// Waits up to 5 s for [room]'s route to be of [kind], then logs it. On
/// iOS it also checks flutter_webrtc's list of outputs, which shows the
/// current route (plus a "Speaker" entry when the route isn't the speaker).
Future<void> _expectRoute(Room room, AudioRouteKind kind, String when) async {
  final route = await room.audioRouteChanges
      .firstWhere((r) => r?.kind == kind)
      .timeout(const Duration(seconds: 5), onTimeout: () => null);
  final outputs = [
    for (final d in await rtc.navigator.mediaDevices.enumerateDevices())
      if (d.kind == 'audiooutput') '${d.deviceId}="${d.label}"',
  ];
  _log(
    'route $when: want ${kind.name}, got ${room.audioRoute}'
    '${outputs.isEmpty ? '' : '; flutter_webrtc outputs: ${outputs.join(', ')}'}',
  );
  expect(route?.kind, kind, reason: 'route $when');
  if (!kIsWeb && Platform.isIOS && kind != AudioRouteKind.other) {
    final onSpeaker = outputs.every((o) => o.startsWith('Speaker='));
    expect(onSpeaker, kind == AudioRouteKind.speaker, reason: 'iOS $when');
  }
}

/// Waits until Bob has received at least 25 more audio packets than now.
Future<void> _audioArriving(Room bob, String when) async {
  Future<num> packets() async {
    num total = 0;
    for (final r in await bob.session.getStats()) {
      if (r.type == 'inbound-rtp' && r.values['kind'] == 'audio') {
        final v = r.values['packetsReceived'];
        total += v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
      }
    }
    return total;
  }

  final start = await packets();
  final deadline = DateTime.now().add(_timeout);
  var last = start;
  while (DateTime.now().isBefore(deadline)) {
    last = await packets();
    if (last - start >= 25) {
      _log('$when: Bob received ${last - start} more audio packets');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('$when: Bob received only ${last - start} more audio packets');
}
