// Call audio routing on phones, the same way on Android and iOS
// (docs/design.md §4.6), through a real broker:
//
// - a voice call starts on the earpiece (or a connected headset);
// - publishing a camera moves it to the speaker;
// - Room.selectAudioRoute picks a route, which sticks;
// - Room.setSpeakerphone forces the speaker or the earpiece;
// - choosing a microphone keeps the call sending audio.
//
// Desktops have no call audio routing, which the room reports
// (canSelectAudioRoute) instead of doing something else.
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
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

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
      if (Platform.isAndroid || Platform.isIOS) {
        final camera = CameraSource();
        await camera.enable();
        await camera.dispose();
      }

      final realtime = CloudflareRealtime(broker: settings.config());
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

      final phone = Platform.isAndroid || Platform.isIOS;
      expect(alice.canSelectAudioRoute, phone);
      if (!phone) {
        await expectLater(alice.setSpeakerphone(false), throwsUnsupportedError);
        expect(alice.currentAudioRoutes, isEmpty);
      }

      final published = await alice.localParticipant.publishMicrophone();
      await published.publication.whenSending().timeout(_timeout);
      await _audioArriving(bob, 'in a voice call');

      if (phone) {
        _log('routes: ${alice.currentAudioRoutes.join('; ')}');
        // A connected headset comes first; then the default for the call.
        final headset = alice.currentAudioRoutes
            .where((r) => r.kind.isExternal)
            .firstOrNull;
        AudioRouteKind expected(AudioRouteKind kind) => headset?.kind ?? kind;

        await _expectRoute(alice, expected(AudioRouteKind.earpiece), 'voice');

        final camera = await alice.localParticipant.publishCamera(
          options: const CameraOptions(preset: VideoPreset.h360),
        );
        await camera.publication.whenSending().timeout(_timeout);
        await _expectRoute(alice, expected(AudioRouteKind.speaker), 'video');

        final earpiece = alice.currentAudioRoutes
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
      final mics = mic.currentDevices;
      _log('microphones: ${mics.map((m) => '"${m.label}"').join('; ')}');
      if (mics.length < 2) _log('only one microphone: nothing to switch to');
      for (final device in [...mics.skip(1), if (mics.length > 1) mics.first]) {
        await mic.setPreferredDevice(device);
        expect(mic.currentTrack?.device?.sameDeviceAs(device), isTrue);
        _log('microphone "${device.label}" (${device.deviceId})');
        await _audioArriving(bob, 'from "${device.label}"');
      }
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
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
    'route $when: want ${kind.name}, got ${room.currentAudioRoute}'
    '${outputs.isEmpty ? '' : '; flutter_webrtc outputs: ${outputs.join(', ')}'}',
  );
  expect(route?.kind, kind, reason: 'route $when');
  if (Platform.isIOS && kind != AudioRouteKind.other) {
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
