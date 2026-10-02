import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// A local preview of the media layer: camera and microphone toggles with
/// device dropdowns, and a screen-share picker with thumbnails.
///
/// Nothing is published; this only shows local capture (roadmap M2 adds
/// publishing).
class LocalMediaPage extends StatefulWidget {
  const LocalMediaPage({
    super.key,
    this.backend = const FlutterWebrtcMediaBackend(),
  });

  /// Where capture comes from. Tests pass a fake.
  final MediaBackend backend;

  @override
  State<LocalMediaPage> createState() => _LocalMediaPageState();
}

class _LocalMediaPageState extends State<LocalMediaPage> {
  late final MediaDeviceList _devices = MediaDeviceList(
    backend: widget.backend,
  );
  late final CameraSource _camera = CameraSource(
    backend: widget.backend,
    deviceList: _devices,
  );
  late final MicrophoneSource _microphone = MicrophoneSource(
    backend: widget.backend,
    deviceList: _devices,
  );
  late final ScreenShareSource _screen = ScreenShareSource(
    backend: widget.backend,
  );
  late final ScreenSourcePicker _picker = ScreenSourcePicker(
    backend: widget.backend,
  );
  final List<StreamSubscription<Object>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _subscriptions.addAll([
      _camera.errors.listen(_showError),
      _microphone.errors.listen(_showError),
      _screen.errors.listen(_showError),
      _screen.ended.listen(
        (reason) => _showMessage('Screen share ended (${reason.name}).'),
      ),
    ]);
  }

  void _showError(MediaException error) => _showMessage(error.message);

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _picker.dispose();
    _screen.dispose();
    Future.wait([_camera.dispose(), _microphone.dispose()])
        .then((_) => _devices.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Local media')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Section(
            title: 'Camera',
            child: _DeviceSourceControls(
              source: _camera,
              icon: Icons.videocam,
              // Mirrored like a mirror, except from a back camera.
              preview: (track) => _TrackPreview(
                track: track,
                mirror: track?.device?.facing != CameraFacing.environment,
              ),
            ),
          ),
          _Section(
            title: 'Microphone',
            child: _DeviceSourceControls(source: _microphone, icon: Icons.mic),
          ),
          _Section(
            title: 'Speakers',
            child: _AudioOutputs(devices: _devices),
          ),
          _Section(
            title: 'Screen share',
            child: _ScreenShareControls(screen: _screen, picker: _picker),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

/// On/off, mute and device selection for a camera or microphone.
class _DeviceSourceControls extends StatelessWidget {
  const _DeviceSourceControls({
    required this.source,
    required this.icon,
    this.preview,
  });

  final DeviceMediaSource source;
  final IconData icon;
  final Widget Function(CapturedTrack? track)? preview;

  @override
  Widget build(BuildContext context) {
    final label = source.kind == TrackKind.video ? 'camera' : 'microphone';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        StreamBuilder<bool>(
          stream: source.enabled,
          initialData: source.isEnabled,
          builder: (context, snapshot) => SwitchListTile(
            secondary: Icon(icon),
            title: Text('Capture from the $label'),
            value: snapshot.data ?? false,
            onChanged: source.setEnabled,
          ),
        ),
        StreamBuilder<bool>(
          stream: source.broadcasting,
          initialData: source.isBroadcasting,
          builder: (context, snapshot) => SwitchListTile(
            secondary: const Icon(Icons.podcasts),
            title: const Text('Broadcasting'),
            subtitle: Text(switch (source.mutePolicy) {
              MutePolicy.keepCapture => 'Muting keeps the capture warm.',
              MutePolicy.releaseCapture => 'Muting releases the capture.',
            }),
            value: snapshot.data ?? false,
            onChanged: source.setBroadcasting,
          ),
        ),
        _DeviceDropdown(source: source),
        if (preview != null)
          StreamBuilder<CapturedTrack?>(
            stream: source.track,
            initialData: source.currentTrack,
            builder: (context, snapshot) => preview!(snapshot.data),
          ),
      ],
    );
  }
}

class _DeviceDropdown extends StatelessWidget {
  const _DeviceDropdown({required this.source});

  final DeviceMediaSource source;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaDevice>>(
      stream: source.devices,
      initialData: source.currentDevices,
      builder: (context, devices) => StreamBuilder<MediaDevice?>(
        stream: source.activeDevice,
        initialData: source.currentActiveDevice,
        builder: (context, active) {
          final list = devices.data ?? const [];
          final selected = list
              .where((d) => active.data != null && d.sameDeviceAs(active.data!))
              .firstOrNull;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: DropdownButtonFormField<MediaDevice>(
              key: ValueKey(selected),
              initialValue: selected,
              decoration: const InputDecoration(labelText: 'Device'),
              items: [
                for (final (index, device) in list.indexed)
                  DropdownMenuItem(
                    value: device,
                    child: Text(
                      device.label.isEmpty
                          ? 'Device ${index + 1}'
                          : device.label,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: list.isEmpty ? null : source.setPreferredDevice,
            ),
          );
        },
      ),
    );
  }
}

class _AudioOutputs extends StatelessWidget {
  const _AudioOutputs({required this.devices});

  final MediaDeviceList devices;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<MediaDevice>>(
      stream: devices.audioOutputs,
      initialData: devices.currentDevicesOfKind(MediaDeviceKind.audioOutput),
      builder: (context, snapshot) {
        final outputs = snapshot.data ?? const [];
        if (outputs.isEmpty) {
          return const Text('No audio outputs listed.');
        }
        return Column(
          children: [
            for (final output in outputs)
              ListTile(
                dense: true,
                leading: const Icon(Icons.speaker),
                title: Text(
                  output.label.isEmpty ? output.deviceId : output.label,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ScreenShareControls extends StatefulWidget {
  const _ScreenShareControls({required this.screen, required this.picker});

  final ScreenShareSource screen;
  final ScreenSourcePicker picker;

  @override
  State<_ScreenShareControls> createState() => _ScreenShareControlsState();
}

class _ScreenShareControlsState extends State<_ScreenShareControls> {
  @override
  void initState() {
    super.initState();
    if (widget.picker.isSupported) widget.picker.start();
  }

  @override
  Widget build(BuildContext context) {
    final screen = widget.screen;
    if (!screen.isSupported) {
      return const Text(
        'Screen share on this platform needs host-app setup that the package '
        "doesn't cover yet (roadmap M9).",
      );
    }
    return StreamBuilder<CapturedTrack?>(
      stream: screen.track,
      initialData: screen.currentTrack,
      builder: (context, snapshot) {
        final track = snapshot.data;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (track != null) ...[
              _TrackPreview(track: track),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: screen.stop,
                icon: const Icon(Icons.stop_screen_share),
                label: const Text('Stop sharing'),
              ),
              const SizedBox(height: 16),
            ] else if (screen.usesSystemPicker)
              FilledButton.icon(
                onPressed: () => screen.start(),
                icon: const Icon(Icons.screen_share),
                label: const Text('Share screen'),
              ),
            if (widget.picker.isSupported)
              _SourceGrid(
                picker: widget.picker,
                selectedId: track == null ? null : screen.selectedSource?.id,
                onPick: (source) => screen.start(source: source),
              ),
          ],
        );
      },
    );
  }
}

/// The desktop "choose what to share" grid.
class _SourceGrid extends StatelessWidget {
  const _SourceGrid({
    required this.picker,
    required this.selectedId,
    required this.onPick,
  });

  final ScreenSourcePicker picker;
  final String? selectedId;
  final ValueChanged<ScreenSource> onPick;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ScreenPickerState>(
      stream: picker.state,
      initialData: picker.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Choose a screen or window:')),
                if (state.isLoading)
                  const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                IconButton(
                  tooltip: 'Refresh sources',
                  icon: const Icon(Icons.refresh),
                  onPressed: picker.refresh,
                ),
              ],
            ),
            if (state.permissionProblem case final problem?)
              Text(
                'This app may not have permission to record the screen. '
                '${problem.guidance}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (state.error != null)
              Text(
                state.error!.noScreens
                    ? 'No screens were listed. Try refreshing.'
                    : 'Listing screens and windows failed. Try refreshing.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            GridView.extent(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              maxCrossAxisExtent: 200,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              childAspectRatio: 4 / 3,
              children: [
                for (final source in state.sources)
                  _SourceTile(
                    source: source,
                    selected: source.id == selectedId,
                    onTap: () => onPick(source),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _SourceTile extends StatelessWidget {
  const _SourceTile({
    required this.source,
    required this.selected,
    required this.onTap,
  });

  final ScreenSource source;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final thumbnail = source.thumbnail;
    final icon = Icon(
      source.type == ScreenSourceType.screen
          ? Icons.desktop_windows
          : Icons.web_asset,
      size: 40,
      color: colors.outline,
    );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? colors.primary : colors.outlineVariant,
            width: selected ? 3 : 1,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            Expanded(
              child: thumbnail == null
                  ? icon
                  : Image.memory(
                      thumbnail,
                      gaplessPlayback: true,
                      // macOS thumbnails are TIFF, which Flutter's codecs
                      // may not decode.
                      errorBuilder: (_, _, _) => icon,
                    ),
            ),
            Text(
              source.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Renders a captured track with `RTCVideoView`.
///
/// The renderer is only created once there is a track, so the page builds
/// without the native plugin (as in widget tests) while nothing is
/// captured.
class _TrackPreview extends StatefulWidget {
  const _TrackPreview({required this.track, this.mirror = false});

  final CapturedTrack? track;
  final bool mirror;

  @override
  State<_TrackPreview> createState() => _TrackPreviewState();
}

class _TrackPreviewState extends State<_TrackPreview> {
  RTCVideoRenderer? _renderer;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(_TrackPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track != widget.track) _attach();
  }

  Future<void> _attach() async {
    final track = widget.track;
    if (track == null) {
      _renderer?.srcObject = null;
      return;
    }
    var renderer = _renderer;
    if (renderer == null) {
      renderer = _renderer = RTCVideoRenderer();
      await renderer.initialize();
    }
    if (!mounted) return;
    renderer.srcObject = track.stream;
    setState(() => _ready = true);
  }

  @override
  void dispose() {
    final renderer = _renderer;
    if (renderer != null) {
      renderer.srcObject = null;
      renderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        color: Colors.black,
        child: widget.track == null || renderer == null || !_ready
            ? const Center(
                child: Icon(Icons.videocam_off, color: Colors.white54),
              )
            : RTCVideoView(
                renderer,
                mirror: widget.mirror,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
              ),
      ),
    );
  }
}
