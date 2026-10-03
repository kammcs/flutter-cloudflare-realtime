// The microphone the app chooses is the one libwebrtc records from
// (macOS), through a real broker.
//
// Found on a Mac whose system default input is BlackHole, a silent
// loopback device: choosing "MacBook Pro Microphone" in the example's
// Devices sheet changed the track but not the audio device module's
// recording device, so the remote heard nothing (docs/design.md §4.5,
// `flutter_webrtc` realities). audio_routing_test.dart didn't catch it: it
// checks that packets keep arriving, and silence sends packets too.
//
// The check: after each choice, the audio device module (WebRTC-SDK's
// AVAudioEngine module) logs `Setting input device: <label>`, or `Using
// default input device` for the system default (`default`). The test reads
// that from flutter_webrtc's native log. Before the fix nothing was logged.
// Sound alone can't tell: the built-in microphone read exact zeros for
// long stretches in a quiet room (voice processing on) and a loopback device
// carries whatever the Mac plays, so the publisher's `media-source` energy
// is only logged, for each input. With
// --dart-define=CF_REALTIME_EXPECT_SOUND=1 (someone talks during the run),
// every real input must also capture energy.
//
// CF_REALTIME_MICROPHONES (broker_settings.dart) limits the test to the
// inputs with those labels, for a machine where some must not be opened:
//
//   --dart-define="CF_REALTIME_MICROPHONES=BlackHole 16ch,MacBook Pro Microphone"
//
// macOS only. Skipped unless CF_REALTIME_BROKER_URL is set; see
// broker_settings.dart. The test never prints the settings.

// NativeLogsListener isn't exported by flutter_webrtc.
// ignore_for_file: implementation_imports

import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/src/native_logs_listener.dart';
import 'package:integration_test/integration_test.dart';
import 'package:logger/logger.dart';

import 'broker_settings.dart';

const _timeout = Duration(seconds: 30);

const _expectSound = String.fromEnvironment('CF_REALTIME_EXPECT_SOUND') == '1';

/// How long the audio device module may take to log a choice.
const _selectTimeout = Duration(seconds: 5);

/// How long a choice runs before it is measured.
const _settle = Duration(milliseconds: 2500);

/// How long each microphone is measured.
const _window = Duration(seconds: 3);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();
  final macos = !kIsWeb && Platform.isMacOS;

  testWidgets(
    'the audio device module records from the microphone chosen',
    (tester) async {
      final adm = _AdmLog();
      NativeLogsListener.instance.setLogger(
        Logger(output: adm, filter: _Everything(), printer: SimplePrinter()),
        'info',
      );
      addTearDown(
        () => NativeLogsListener.instance.setLogger(Logger(), 'none'),
      );

      // Ask for the microphone before joining: the SFU drops a session left
      // unused while a first-run prompt waits.
      final permission = MicrophoneSource();
      await permission.enable();
      await permission.dispose();

      final realtime = CloudflareRealtime(broker: settings.brokerOptions());
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(InMemorySignalingHub()),
        participantId: 'mic-alice-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(alice.leave);

      final published = await alice.localParticipant.publishMicrophone();
      await published.publication.whenSending().timeout(_timeout);
      final mic = published.mediaSource as MicrophoneSource;

      _log(
        'microphones: ${[for (final m in mic.devices) '"${m.label}" (${m.deviceId})${m.isDefault ? ' default' : ''}'
              '${_isVirtual(m) ? ' virtual' : ''}'].join('; ')}',
      );
      final first = await _measure(alice, mic);
      _log('at join, "${mic.track?.device?.label}": $first');

      final chosen = mic.devices.where(settings.mayOpenMicrophone).toList();
      if (settings.microphones != null) {
        _log('only: ${chosen.map((m) => '"${m.label}"').join('; ')}');
      }
      final real = [
        for (final m in chosen)
          if (!_isVirtual(m)) m,
      ];
      expect(real, isNotEmpty, reason: 'no real microphone to choose');

      final results = <MediaDevice, _Capture>{};
      // Real ones first, then the virtual ones, for the log: they show what
      // silence reads.
      for (final device in [...real, ...chosen.where(_isVirtual)]) {
        final from = adm.lines.length;
        await mic.setPreferredDevice(device);
        expect(mic.track?.device?.sameDeviceAs(device), isTrue);
        final want = device.deviceId == 'default'
            ? 'Using default input device'
            : 'Setting input device: ${device.label}';
        // The system default needs no change when the module is on it.
        final selected =
            await adm.waitFor(want, from: from, timeout: _selectTimeout) ||
            (device.deviceId == 'default' &&
                (adm.current?.startsWith(want) ?? true));
        _log(
          '"${device.label}": the module '
          '${selected ? 'selected it' : 'did NOT select it'}; '
          'its lines: ${adm.lines.skip(from).toList()}',
        );
        expect(
          selected,
          isTrue,
          reason:
              'choosing "${device.label}" did not reach the audio device '
              'module: it keeps recording from another input',
        );
        // The module may undo the switch within a second or two; the
        // backend selects the input again (docs/design.md §4.5).
        await Future<void>.delayed(_settle);
        final capture = await _measure(alice, mic);
        results[device] = capture;
        _log(
          '"${device.label}"${_isVirtual(device) ? ' (virtual)' : ''}: '
          '$capture${capture.samples == 0 ? ' (capture stalled)' : ''}',
        );
        expect(
          adm.current,
          startsWith(want),
          reason:
              'the audio device module left "${device.label}" while it was '
              'measured',
        );
      }

      if (_expectSound) {
        for (final device in real) {
          expect(
            results[device]!.energy,
            greaterThan(0),
            reason: '"${device.label}" captured only silence',
          );
        }
      }
    },
    skip: settings.skip || !macos,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

/// The audio device module's input-device lines from flutter_webrtc's
/// native log.
class _AdmLog extends LogOutput {
  final List<String> lines = [];

  @override
  void output(OutputEvent event) {
    for (final line in event.lines) {
      final at = line.indexOf('AudioEngineDevice::');
      if (at < 0) continue;
      final text = line.substring(at + 'AudioEngineDevice::'.length);
      if (text.startsWith('Setting input device') ||
          text.startsWith('Using default input device')) {
        lines.add(text);
      }
    }
  }

  /// The module's last choice, if it logged one.
  String? get current => lines.lastOrNull;

  /// Whether a line starting with [prefix] is logged, from line [from] on,
  /// within [timeout].
  Future<bool> waitFor(
    String prefix, {
    required int from,
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!lines.skip(from).any((l) => l.startsWith(prefix))) {
      if (DateTime.now().isAfter(deadline)) return false;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return true;
  }
}

class _Everything extends LogFilter {
  @override
  bool shouldLog(LogEvent event) => true;
}

/// A loopback or virtual input, which may be silent by design.
bool _isVirtual(MediaDevice device) {
  final label = device.label.toLowerCase();
  return const [
    'blackhole',
    'loopback',
    'soundflower',
    'virtual',
    'iphone microphone', // Continuity: needs a phone nearby.
  ].any(label.contains);
}

/// What the microphone's `media-source` report says over [_window].
class _Capture {
  _Capture(this.energy, this.samples, this.maxLevel);

  /// The growth of `totalAudioEnergy`.
  final double energy;

  /// The growth of `totalSamplesDuration`, in seconds.
  final double samples;

  /// The highest `audioLevel` seen.
  final double maxLevel;

  @override
  String toString() =>
      'energy +${energy.toStringAsExponential(3)} over '
      '${samples.toStringAsFixed(2)} s, max level '
      '${maxLevel.toStringAsFixed(5)}';
}

Future<_Capture> _measure(Room room, MicrophoneSource mic) async {
  Future<({double energy, double samples, double level})> read() async {
    final trackId = mic.track?.track.id;
    for (final r in await room.session.getStats()) {
      if (r.type != 'media-source' || r.values['kind'] != 'audio') continue;
      if (trackId != null && r.values['trackIdentifier'] != trackId) continue;
      double value(String name) {
        final v = r.values[name];
        return v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0;
      }

      return (
        energy: value('totalAudioEnergy'),
        samples: value('totalSamplesDuration'),
        level: value('audioLevel'),
      );
    }
    return (energy: 0.0, samples: 0.0, level: 0.0);
  }

  final start = await read();
  var maxLevel = start.level;
  var last = start;
  final deadline = DateTime.now().add(_window);
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    last = await read();
    if (last.level > maxLevel) maxLevel = last.level;
  }
  return _Capture(
    last.energy - start.energy,
    last.samples - start.samples,
    maxLevel,
  );
}

void _log(String message) => debugPrint(
  '[mic] ${DateTime.now().toIso8601String().substring(11, 19)} $message',
);
