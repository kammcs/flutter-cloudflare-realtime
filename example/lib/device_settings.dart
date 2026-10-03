import 'dart:math' as math;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

import 'audio_routes_sheet.dart';

/// What to call [device] in a picker: its label (or "Device n" before a
/// browser grants access), marked when it is the system default.
String deviceLabel(MediaDevice device, int index) {
  final label = device.label.isEmpty ? 'Device ${index + 1}' : device.label;
  final lower = label.toLowerCase();
  // Chromium's own entries already say so ("Default - Headset").
  final saysDefault =
      lower.startsWith('default') || lower.startsWith('communications');
  return device.isDefault && !saysDefault ? '$label (system default)' : label;
}

/// A dropdown of [source]'s devices with the one in use selected.
///
/// Choosing one calls [DeviceMediaSource.setPreferredDevice]: a capturing
/// source opens the new device, then drops the old one, and a published
/// track's sender gets the new track with `replaceTrack` (no
/// renegotiation, the others keep pulling the same track).
class DeviceDropdown extends StatelessWidget {
  const DeviceDropdown({
    super.key,
    required this.source,
    this.label = 'Device',
    this.icon,
  });

  final DeviceMediaSource source;
  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaDevice>>(
      stream: source.devicesChanges,
      initialData: source.devices,
      builder: (context, devices) => StreamBuilder<MediaDevice?>(
        stream: source.activeDeviceChanges,
        initialData: source.activeDevice,
        builder: (context, active) {
          final list = devices.data ?? const [];
          final selected = list
              .where((d) => active.data != null && d.sameDeviceAs(active.data!))
              .firstOrNull;
          return DropdownButtonFormField<MediaDevice>(
            key: ValueKey(selected),
            initialValue: selected,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: label,
              prefixIcon: icon == null ? null : Icon(icon),
            ),
            items: [
              for (final (index, device) in list.indexed)
                DropdownMenuItem(
                  value: device,
                  child: Text(
                    deviceLabel(device, index),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: list.isEmpty ? null : source.setPreferredDevice,
          );
        },
      ),
    );
  }
}

/// The local microphone's level as a small bar, from the active-speaker
/// polling ([LocalParticipant.audioLevelChanges]): what is sent, so it stays
/// empty while muted.
class MicLevelMeter extends StatelessWidget {
  const MicLevelMeter({super.key, required this.participant, this.width = 48});

  final LocalParticipant participant;
  final double width;

  /// Maps a linear level to the bar: −60 dBFS (empty) to 0 dBFS (full).
  static double fill(double level) {
    if (level <= 0.001) return 0;
    final dbfs = 20 * math.log(level) / math.ln10;
    return ((dbfs + 60) / 60).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: StreamBuilder<double>(
        stream: participant.audioLevelChanges,
        initialData: participant.audioLevel,
        builder: (context, snapshot) => ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: fill(snapshot.data ?? 0),
            minHeight: 6,
            color: Colors.greenAccent.shade700,
          ),
        ),
      ),
    );
  }
}

/// A one-line status of the published microphone: the device in use and
/// its level. Tapping it calls [onTap] (the call screen opens the device
/// settings).
class MicStatus extends StatelessWidget {
  const MicStatus({super.key, required this.participant, this.onTap});

  final LocalParticipant participant;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final mic = participant.microphone;
    final source = mic?.mediaSource;
    if (mic == null || source is! DeviceMediaSource) {
      return const SizedBox.shrink();
    }
    final style = Theme.of(context).textTheme.bodySmall;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: StreamBuilder<MediaDevice?>(
          stream: source.activeDeviceChanges,
          initialData: source.activeDevice,
          builder: (context, snapshot) {
            final device = snapshot.data;
            return Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: [
                Icon(mic.isMuted ? Icons.mic_off : Icons.mic, size: 16),
                Flexible(
                  child: Text(
                    device == null ? 'No microphone' : deviceLabel(device, 0),
                    overflow: TextOverflow.ellipsis,
                    style: style,
                  ),
                ),
                MicLevelMeter(participant: participant),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Opens the call's device settings: microphone, camera and speaker.
///
/// [output] remembers the speaker chosen here (the room doesn't report the
/// output device in use); `null` means the system's.
Future<void> showDeviceSettingsSheet(
  BuildContext context,
  Room room,
  ValueNotifier<String?> output,
) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => DeviceSettingsSheet(room: room, output: output),
);

/// Device pickers for a call. Each switches live: see [DeviceDropdown].
class DeviceSettingsSheet extends StatelessWidget {
  const DeviceSettingsSheet({
    super.key,
    required this.room,
    required this.output,
  });

  final Room room;
  final ValueNotifier<String?> output;

  @override
  Widget build(BuildContext context) {
    final local = room.localParticipant;
    return StreamBuilder<LocalParticipant>(
      stream: local.changes,
      builder: (context, _) {
        final mic = local.microphone?.mediaSource;
        final camera = local.camera?.mediaSource;
        final devices = switch ((mic, camera)) {
          (DeviceMediaSource(:final deviceList), _) => deviceList,
          (_, DeviceMediaSource(:final deviceList)) => deviceList,
          _ => null,
        };
        // Scrolls on short screens (a phone in landscape) instead of
        // overflowing.
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              spacing: 16,
              children: [
                Text('Devices', style: Theme.of(context).textTheme.titleLarge),
                if (mic is DeviceMediaSource)
                  Row(
                    spacing: 12,
                    children: [
                      Expanded(
                        child: DeviceDropdown(
                          source: mic,
                          label: 'Microphone',
                          icon: Icons.mic,
                        ),
                      ),
                      MicLevelMeter(participant: local, width: 64),
                    ],
                  )
                else
                  const Text('Publish the microphone to choose one.'),
                if (camera is DeviceMediaSource)
                  DeviceDropdown(
                    source: camera,
                    label: 'Camera',
                    icon: Icons.videocam,
                  )
                else
                  const Text('Publish the camera to choose one.'),
                if (room.canSelectAudioRoute)
                  // Phones route call audio (speaker, earpiece, headsets).
                  OutlinedButton.icon(
                    icon: const Icon(Icons.volume_up),
                    label: const Text('Audio output…'),
                    onPressed: () => showAudioRoutesSheet(context, room),
                  )
                else if (room.canSelectAudioOutput && devices != null)
                  AudioOutputDropdown(
                    room: room,
                    devices: devices,
                    output: output,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The speakers [devices] lists; choosing one calls
/// [Room.setAudioOutputDevice] (app-wide on native platforms). A refused
/// choice shows why and snaps back to the speaker in use.
class AudioOutputDropdown extends StatefulWidget {
  const AudioOutputDropdown({
    super.key,
    required this.room,
    required this.devices,
    required this.output,
  });

  final Room room;
  final MediaDeviceList devices;

  /// The speaker the room accepted last; `null` for the system default.
  final ValueNotifier<String?> output;

  @override
  State<AudioOutputDropdown> createState() => _AudioOutputDropdownState();
}

class _AudioOutputDropdownState extends State<AudioOutputDropdown> {
  /// Counts refusals: a new count rebuilds the field on the speaker in use.
  int _refusals = 0;

  Future<void> _choose(String? deviceId) async {
    if (deviceId == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.room.setAudioOutputDevice(deviceId);
      widget.output.value = deviceId;
    } on AudioOutputException catch (e) {
      // The room kept the previous speaker: show that one again.
      debugPrint('Speaker refused: $e');
      if (mounted) setState(() => _refusals++);
      messenger.showSnackBar(SnackBar(content: Text(refusalMessage(e.reason))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaDevice>>(
      stream: widget.devices.audioOutputsChanges,
      initialData: widget.devices.audioOutputs,
      builder: (context, snapshot) => ValueListenableBuilder<String?>(
        valueListenable: widget.output,
        builder: (context, chosen, _) {
          final outputs = [
            for (final device in snapshot.data ?? const <MediaDevice>[])
              if (device.deviceId.isNotEmpty) device,
          ];
          // Until one is chosen here, the system's default plays (libwebrtc
          // uses Windows' default communications device).
          final selected =
              outputs.where((d) => d.deviceId == chosen).firstOrNull ??
              outputs.where((d) => d.isDefault).firstOrNull;
          return DropdownButtonFormField<String>(
            key: ValueKey((selected?.deviceId, _refusals)),
            initialValue: selected?.deviceId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Speaker',
              prefixIcon: Icon(Icons.speaker),
            ),
            items: [
              for (final (index, device) in outputs.indexed)
                DropdownMenuItem(
                  value: device.deviceId,
                  child: Text(
                    deviceLabel(device, index),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: outputs.isEmpty ? null : _choose,
          );
        },
      ),
    );
  }
}

/// What to tell the user when the platform refused a speaker ([reason]).
String refusalMessage(AudioOutputFailure reason) => switch (reason) {
  AudioOutputFailure.needsUserGesture =>
    'The browser changes the speaker only right after a click or tap. '
        'Choose it again.',
  AudioOutputFailure.notFound =>
    'That speaker is no longer available. Choose another one.',
  AudioOutputFailure.permissionDenied =>
    'Allow microphone access in the browser to choose a speaker.',
  AudioOutputFailure.other => 'Could not change the speaker.',
};
