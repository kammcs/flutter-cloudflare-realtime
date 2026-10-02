// Call audio routing, the same way on every platform, through a real
// broker: a call starts on the speakerphone on phones (Android and iOS;
// out of the box iOS would use the earpiece), Room.setSpeakerphone moves
// it between the loudspeaker and the earpiece, and choosing a microphone
// keeps the call sending audio. Desktops have no speakerphone switch, which
// the room reports (canSetSpeakerphone) instead of doing something else.
//
// Two rooms in one process share in-memory signaling: Alice publishes her
// microphone, Bob pulls it.
//
// iOS reports its current route (the audio outputs list), so the test
// checks it there. Android doesn't tell the app; the test logs each step
// with the time, to compare with `adb shell dumpsys audio` ("Active
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
      // Ask for the microphone before joining: the SFU drops a session left
      // unused while a first-run prompt waits.
      final permission = MicrophoneSource();
      await permission.enable();
      await permission.dispose();

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
      expect(alice.canSetSpeakerphone, phone);
      expect(alice.speakerphone, isTrue, reason: 'RoomOptions default');
      if (!phone) {
        await expectLater(alice.setSpeakerphone(false), throwsUnsupportedError);
      }

      final published = await alice.localParticipant.publishMicrophone();
      await published.publication.whenSending().timeout(_timeout);
      await _audioArriving(bob, 'with the default route');

      if (phone) {
        await _expectRoute(speaker: true, 'at the start of the call');
        await alice.setSpeakerphone(false);
        expect(alice.speakerphone, isFalse);
        await _expectRoute(speaker: false, 'after setSpeakerphone(false)');
        await _audioArriving(bob, 'on the earpiece');
        await alice.setSpeakerphone(true);
        await _expectRoute(speaker: true, 'after setSpeakerphone(true)');
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

/// Waits for the route to settle, logs it, and on iOS checks it: the
/// loudspeaker ([speaker]) or not. iOS lists the current route's outputs
/// (plus a "Speaker" entry when the route isn't the speaker); Android
/// doesn't say, so only the log is there to compare with `adb`.
Future<void> _expectRoute(String when, {required bool speaker}) async {
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  final outputs = [
    for (final d in await rtc.navigator.mediaDevices.enumerateDevices())
      if (d.kind == 'audiooutput') d,
  ];
  _log(
    'route $when (want ${speaker ? 'speaker' : 'earpiece'}): '
    '${outputs.map((d) => '${d.deviceId}="${d.label}"').join('; ')}',
  );
  if (Platform.isIOS) {
    final onSpeaker = outputs.every((d) => d.deviceId == 'Speaker');
    expect(onSpeaker, speaker, reason: 'iOS route $when');
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
