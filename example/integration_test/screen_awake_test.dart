// Keeping the screen on during a video call (docs/design.md §4.7, Keeping
// the screen on), through a real broker: with the default
// RoomOptions.keepScreenAwake (whileVideo), a voice call lets the screen
// sleep, published video keeps it on (held past the screen timeout),
// muting it lets the screen sleep again, and leaving releases it. The
// video is the camera on phones and in browsers, and a share of the first
// screen on desktops (another app may hold the webcam there).
//
// - Android: screen_awake_test_driver.sh sets the screen timeout to 15 s
//   and, at each `CHECK SCREEN`, prints whether the app's window has
//   FLAG_KEEP_SCREEN_ON (`dumpsys window`) and whether the device is awake
//   (`dumpsys power`); it restores the timeout afterwards. While the video
//   is held for 25 s the device must stay awake.
// - Windows: the test reads the root isolate's thread execution state
//   (ES_DISPLAY_REQUIRED while held) and the system's
//   (CallNtPowerInformation, which `powercfg /requests` details from an
//   elevated prompt).
// - Elsewhere it checks Room.keepingScreenAwake only.
//
// Skipped unless CF_REALTIME_BROKER_URL is set (see broker_settings.dart).
// The test never prints the settings.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';
import 'support/windows_power.dart';

const _timeout = Duration(seconds: 30);
const _holdFor = Duration(seconds: 25);
const _esContinuous = 0x80000000;
const _esDisplayRequired = 0x2;

void _log(String message) => debugPrint('screen_awake_test: $message');

/// Asks the Android driver to check the screen now, and gives it time to.
Future<void> _check(String message) async {
  _log('CHECK SCREEN $message');
  await Future<void>.delayed(const Duration(seconds: 3));
}

/// Logs Windows' execution state and returns this thread's, or `null` off
/// Windows.
int? _windowsState(String when) {
  final state = readWindowsExecutionState();
  if (state == null) return null;
  String hex(int v) => '0x${v.toRadixString(16)}';
  _log(
    '$when: thread ${hex(state.thread)}, system '
    '${state.system < 0 ? 'unreadable' : hex(state.system)}',
  );
  return state.thread;
}

final _desktop =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux);

/// The camera, or on desktops a share of the first screen.
Future<LocalMediaPublication> _publishVideo(Room room) async {
  if (!_desktop) {
    return room.localParticipant.publishCamera(
      options: const CameraOptions(preset: VideoPreset.h360),
    );
  }
  final sources = await FlutterWebrtcMediaBackend().desktopCapturer!.getSources(
    types: {ScreenSourceType.screen},
  );
  _log('sharing the first of ${sources.length} screens');
  return room.localParticipant.publishScreen(source: sources.first);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  testWidgets(
    'a video call keeps the screen on; a voice call lets it sleep',
    (tester) async {
      // The prompts first: the SFU drops a session left unused meanwhile.
      final mic = MicrophoneSource();
      await mic.enable();
      await mic.dispose();
      if (!_desktop) {
        final cam = CameraSource();
        await cam.enable();
        await cam.dispose();
      }

      final realtime = CloudflareRealtime(broker: settings.config());
      final room = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(InMemorySignalingHub()),
        participantId: 'screen-awake-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(room.leave);
      expect(room.options.keepScreenAwake, KeepScreenAwake.whileVideo);
      _log('canKeepScreenAwake: ${room.canKeepScreenAwake}');

      final microphone = await room.localParticipant.publishMicrophone();
      await microphone.publication.whenSending().timeout(_timeout);
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(room.isKeepingScreenAwake, isFalse, reason: 'a voice call');
      final voice = _windowsState('voice call');
      if (voice != null) expect(voice & _esDisplayRequired, 0);
      await _check('voice call: expect no KEEP_SCREEN_ON');

      final published = await _publishVideo(room);
      await published.publication.whenSending().timeout(_timeout);
      if (room.canKeepScreenAwake) {
        await room.keepingScreenAwakeChanges
            .firstWhere((held) => held)
            .timeout(_timeout);
        final video = _windowsState('video call');
        if (video != null) {
          expect(video & _esContinuous, _esContinuous);
          expect(video & _esDisplayRequired, _esDisplayRequired);
        }
        await _check('video call: expect KEEP_SCREEN_ON');
        await Future<void>.delayed(_holdFor);
        expect(room.isKeepingScreenAwake, isTrue);
        _windowsState('video call, ${_holdFor.inSeconds} s later');
        await _check(
          'video call ${_holdFor.inSeconds} s later: expect '
          'KEEP_SCREEN_ON and Awake',
        );
      }

      await published.mute();
      await room.keepingScreenAwakeChanges
          .firstWhere((held) => !held)
          .timeout(_timeout);
      final muted = _windowsState('video muted');
      if (muted != null) expect(muted & _esDisplayRequired, 0);
      await _check('video muted: expect no KEEP_SCREEN_ON');

      if (room.canKeepScreenAwake) {
        await published.unmute();
        await room.keepingScreenAwakeChanges
            .firstWhere((held) => held)
            .timeout(_timeout);
        await _check('video unmuted: expect KEEP_SCREEN_ON');
      }

      await room.leave();
      expect(room.isKeepingScreenAwake, isFalse);
      final left = _windowsState('left');
      if (left != null) expect(left & _esDisplayRequired, 0);
      await _check('left: expect no KEEP_SCREEN_ON');
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
