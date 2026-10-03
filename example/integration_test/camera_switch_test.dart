// Switches the camera during a call, through a real broker, with the one
// call that works on every platform (LocalParticipant.switchCamera): front
// and back on phones, the next camera on desktops. Two rooms in one
// process share in-memory signaling; Alice publishes her camera, Bob pulls
// it, and Bob must keep decoding frames from each camera Alice switches
// to, with no new pull and no renegotiation.
//
// Also checks the defaults that should hold on every platform: the front
// camera first where the device says which way its cameras face, and a
// capture at the requested preset.
//
// Skipped unless CF_REALTIME_BROKER_URL is set; see broker_settings.dart
// for the settings (including the dev server's X-Dev-User) and a command
// line. The test never prints them. With a single camera, it checks the
// call carries on and says that it couldn't switch.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

const _timeout = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  testWidgets(
    'switching the camera keeps the call sending',
    (tester) async {
      // Ask for the camera before joining. On a first run the prompt can
      // take a while to answer, and the SFU drops a session left unused
      // that long (410 on the first publish).
      final permission = CameraSource();
      await permission.enable();
      await permission.dispose();

      final realtime = CloudflareRealtime(broker: settings.config());
      final hub = InMemorySignalingHub();
      const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'switch-alice-$suffix',
        options: options,
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'switch-bob-$suffix',
        options: options,
      );
      addTearDown(bob.leave);

      final published = await alice.localParticipant.publishCamera(
        options: const CameraOptions(preset: VideoPreset.h360),
      );
      final camera = published.mediaSource as CameraSource;
      final first = camera.track!;
      final cameras = camera.devices;
      _log('cameras: ${cameras.map(_describe).join('; ')}');
      _log('opened ${_describe(first.device)}, ${_size(first)}');

      // The front camera first, wherever the platform says which way its
      // cameras face.
      if (cameras.any((c) => c.facing == CameraFacing.user)) {
        expect(first.device?.facing, CameraFacing.user);
      }
      // Near the preset, not the platform's default (before the
      // constraints fix, Android captured 1280x720 whatever was asked).
      // Cameras pick their closest mode: a Mac's FaceTime HD camera gives
      // 640x480 for 640x360. The long side covers portrait captures.
      final captured = first.track.getSettings();
      final longSide = [
        captured['width'],
        captured['height'],
      ].whereType<num>().fold<num>(0, (a, b) => a > b ? a : b);
      expect(
        longSide,
        inInclusiveRange(480, 860),
        reason: 'asked for 640x360, captured ${_size(first)}',
      );

      await published.publication.whenSending().timeout(_timeout);
      final pulled = await _remoteCamera(bob, alice);
      await _framesRising(bob, 'before switching');

      final switches = cameras.length < 2 ? 0 : 2;
      if (switches == 0) _log('only one camera: nothing to switch to');
      var previous = first;
      for (var i = 1; i <= switches; i++) {
        final watch = Stopwatch()..start();
        final now = await alice.localParticipant.switchCamera();
        final current = camera.track!;
        _log(
          'switch $i: ${_describe(now)} in ${watch.elapsedMilliseconds} ms, '
          '${_size(current)}',
        );
        expect(now, isNotNull);
        expect(now!.sameDeviceAs(previous.device!), isFalse);
        expect(current.device?.sameDeviceAs(now), isTrue);
        if (previous.device?.facing != null && now.facing != null) {
          expect(now.facing, isNot(previous.device!.facing));
        }
        expect(published.trackName, isNotEmpty);
        expect(alice.localParticipant.camera, same(published));
        await _framesRising(bob, 'after switch $i');
        previous = current;
      }

      // Same pull throughout: the subscriber never had to pull again.
      expect(await _remoteCamera(bob, alice), same(pulled));
      // The announced layer size follows the capture (M12; checked every
      // 3 s and after each switch).
      await Future<void>.delayed(const Duration(seconds: 4));
      _log('announced ${published.simulcast}, Bob sees ${pulled.simulcast}');
      expect(pulled.simulcast, published.simulcast);
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _log(String message) => debugPrint('[camera-switch] $message');

String _describe(MediaDevice? device) => device == null
    ? 'unknown camera'
    : '"${device.label}"${device.facing == null ? '' : ' (${device.facing!.name})'}';

String _size(CapturedTrack captured) {
  final s = captured.track.getSettings();
  return '${s['width']}x${s['height']}';
}

/// Alice's camera as Bob receives it, once its pull is active.
Future<RemoteTrackPublication> _remoteCamera(Room bob, Room alice) async {
  final deadline = DateTime.now().add(_timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final p in bob.participants) {
      final cam = p.camera;
      if (p.sessionId == alice.session.sessionId &&
          cam != null &&
          cam.subscriptionState == SfuTrackState.active) {
        return cam;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail('Bob never received Alice\'s camera');
}

/// Waits until Bob has decoded at least 15 more video frames than now.
Future<void> _framesRising(Room bob, String when) async {
  Future<num> decoded() async {
    num total = 0;
    for (final r in await bob.session.getStats()) {
      if (r.type == 'inbound-rtp' && r.values['kind'] == 'video') {
        final v = r.values['framesDecoded'];
        total += v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
      }
    }
    return total;
  }

  final start = await decoded();
  final deadline = DateTime.now().add(_timeout);
  var last = start;
  while (DateTime.now().isBefore(deadline)) {
    last = await decoded();
    if (last - start >= 15) {
      _log('$when: Bob decoded ${last - start} more frames');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('$when: Bob decoded only ${last - start} more frames in $_timeout');
}
