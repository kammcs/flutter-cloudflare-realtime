import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// What the join screen hands the call screen: how to reach the others
/// (signaling) and the broker, independent of which signaling was chosen.
class CallSetup {
  CallSetup({
    required this.signaling,
    required this.participantId,
    required this.displayName,
    required this.broker,
    required this.disposeSignaling,
    this.signalingStatus,
    this.addSimulatedParticipant,
  });

  /// The presence transport: in-memory, or the dev server's WebSocket.
  final Signaling signaling;

  /// This device's participant ID in the room.
  final String participantId;

  /// Shown to the others (announced as `metadata.displayName`).
  final String displayName;

  /// Where the SFU calls go.
  final BrokerConfig broker;

  /// Releases [signaling] after the room is left.
  final Future<void> Function() disposeSignaling;

  /// A human-readable signaling status, such as "reconnecting", if the
  /// transport has one.
  final Stream<String>? signalingStatus;

  /// Adds a presence-only participant (in-memory signaling only).
  final Future<void> Function()? addSimulatedParticipant;
}

/// A call: a grid of video tiles for everyone, with mute, screen share and
/// leave controls.
class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.room,
    required this.setup,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
    this.publishOnStart = true,
  });

  final Room room;
  final CallSetup setup;

  /// Used for the desktop screen picker.
  final MediaBackend mediaBackend;

  /// Whether to publish the microphone and camera when the page opens.
  final bool publishOnStart;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final StreamSubscription<RoomEvent> _events;
  bool _left = false;
  bool _busy = false;

  Room get _room => widget.room;
  LocalParticipant get _local => _room.localParticipant;

  @override
  void initState() {
    super.initState();
    _events = _room.events.listen(_onEvent);
    if (widget.publishOnStart) {
      _run(() async {
        await _local.publishMicrophone();
        await _local.publishCamera();
      });
    }
  }

  void _onEvent(RoomEvent event) {
    switch (event) {
      case RoomSessionFailedEvent(:final failure):
        _show('The SFU session failed (${failure.reason}). Leave and rejoin.');
      case ParticipantJoinedEvent(:final participant):
        _show('${_nameOf(participant)} joined.');
      case ParticipantLeftEvent(:final participant):
        _show('${_nameOf(participant)} left.');
      case _:
        break;
    }
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// Runs a control action, showing its error instead of throwing.
  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on MediaException catch (e) {
      _show(e.message);
    } on UnsupportedError catch (e) {
      _show(e.message ?? 'Not supported on this platform.');
    } on Exception catch (e) {
      // Broker and session exceptions never contain SDP or tokens.
      _show('$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleMicrophone() => _run(() async {
    final mic = _local.microphone;
    if (mic == null) {
      await _local.publishMicrophone();
    } else {
      await mic.setMuted(!mic.muted);
    }
  });

  Future<void> _toggleCamera() => _run(() async {
    final camera = _local.camera;
    if (camera == null) {
      await _local.publishCamera();
    } else {
      await camera.setMuted(!camera.muted);
    }
  });

  Future<void> _toggleScreen() => _run(() async {
    final screen = _local.screen;
    if (screen != null) {
      await screen.unpublish();
      return;
    }
    if (kIsWeb) {
      await _local.publishScreen(); // The browser shows its picker.
      return;
    }
    final picker = ScreenSourcePicker(backend: widget.mediaBackend);
    if (!picker.isSupported) {
      await picker.dispose();
      _show('Screen share on this platform is not implemented yet (M6).');
      return;
    }
    final source = await showDialog<ScreenSource>(
      context: context,
      builder: (_) => _ScreenPickerDialog(picker: picker),
    );
    await picker.dispose();
    if (source != null) await _local.publishScreen(source: source);
  });

  Future<void> _leave() async {
    if (_left) return;
    _left = true;
    await _room.leave();
    await widget.setup.disposeSignaling();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _events.cancel();
    if (!_left) {
      _left = true;
      _room.leave().then((_) => widget.setup.disposeSignaling());
    }
    super.dispose();
  }

  static String _nameOf(RemoteParticipant p) =>
      (p.metadata?['displayName'] as String?) ?? p.participantId;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text('Room: ${_room.roomId}'),
          actions: [
            _StatusChip(
              room: _room,
              signalingStatus: widget.setup.signalingStatus,
            ),
            if (widget.setup.addSimulatedParticipant case final add?)
              IconButton(
                tooltip: 'Add simulated participant',
                icon: const Icon(Icons.person_add),
                onPressed: add,
              ),
            IconButton(
              tooltip: 'Leave',
              icon: const Icon(Icons.call_end),
              onPressed: _leave,
            ),
          ],
        ),
        body: SafeArea(
          child: StreamBuilder<LocalParticipant>(
            stream: _local.changes,
            builder: (context, _) => StreamBuilder<List<RemoteParticipant>>(
              stream: _room.participants,
              initialData: _room.currentParticipants,
              builder: (context, snapshot) =>
                  _buildGrid(snapshot.data ?? const []),
            ),
          ),
        ),
        bottomNavigationBar: StreamBuilder<LocalParticipant>(
          stream: _local.changes,
          builder: (context, _) => _buildControls(),
        ),
      ),
    );
  }

  Widget _buildGrid(List<RemoteParticipant> remotes) {
    final camera = _local.camera;
    final screen = _local.screen;
    final tiles = <Widget>[
      _Tile(
        label: '${widget.setup.displayName} (you)',
        micMuted: _local.microphone?.muted ?? true,
        video: camera == null
            ? null
            : ParticipantVideoView.local(camera.mediaSource),
      ),
      if (screen != null)
        _Tile(
          label: 'Your screen',
          video: ParticipantVideoView.local(
            screen.mediaSource,
            fit: VideoViewFit.contain,
          ),
        ),
      for (final remote in remotes) ...[
        _Tile(
          label: _nameOf(remote),
          micMuted: remote.microphone?.muted ?? true,
          video: remote.camera == null
              ? null
              : ParticipantVideoView.remote(remote.camera!),
        ),
        if (remote.screen case final share?)
          _Tile(
            label: "${_nameOf(remote)}'s screen",
            video: ParticipantVideoView.remote(
              share,
              fit: VideoViewFit.contain,
            ),
          ),
      ],
    ];
    return GridView.extent(
      padding: const EdgeInsets.all(8),
      maxCrossAxisExtent: 480,
      childAspectRatio: 16 / 9,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: tiles,
    );
  }

  Widget _buildControls() {
    final micOn = !(_local.microphone?.muted ?? true);
    final cameraOn = !(_local.camera?.muted ?? true);
    final sharing = _local.screen != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          spacing: 16,
          children: [
            IconButton.filledTonal(
              tooltip: micOn ? 'Mute microphone' : 'Unmute microphone',
              icon: Icon(micOn ? Icons.mic : Icons.mic_off),
              onPressed: _busy ? null : _toggleMicrophone,
            ),
            IconButton.filledTonal(
              tooltip: cameraOn ? 'Turn camera off' : 'Turn camera on',
              icon: Icon(cameraOn ? Icons.videocam : Icons.videocam_off),
              onPressed: _busy ? null : _toggleCamera,
            ),
            IconButton.filledTonal(
              tooltip: sharing ? 'Stop sharing' : 'Share screen',
              icon: Icon(
                sharing ? Icons.stop_screen_share : Icons.screen_share,
              ),
              onPressed: _busy ? null : _toggleScreen,
            ),
            IconButton.filled(
              tooltip: 'Leave call',
              style: IconButton.styleFrom(backgroundColor: Colors.red),
              icon: const Icon(Icons.call_end),
              onPressed: _leave,
            ),
          ],
        ),
      ),
    );
  }
}

/// The room's connection state, plus the signaling status if there is one.
class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.room, this.signalingStatus});

  final Room room;
  final Stream<String>? signalingStatus;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RoomConnectionState>(
      stream: room.connectionState,
      initialData: room.currentConnectionState,
      builder: (context, state) => StreamBuilder<String>(
        stream: signalingStatus,
        builder: (context, signaling) {
          final media = state.data?.name ?? '';
          final presence = signaling.data;
          final ok =
              state.data == RoomConnectionState.connected &&
              (presence == null || presence == 'connected');
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Chip(
              avatar: Icon(
                ok ? Icons.cloud_done : Icons.cloud_off,
                size: 18,
                color: ok ? Colors.green : Colors.orange,
              ),
              label: Text(
                presence == null
                    ? media
                    : 'media: $media · signaling: $presence',
              ),
            ),
          );
        },
      ),
    );
  }
}

/// One participant's (or screen's) video, with a name label.
class _Tile extends StatelessWidget {
  const _Tile({required this.label, this.video, this.micMuted = false});

  final String label;
  final Widget? video;
  final bool micMuted;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          video ??
              ColoredBox(
                color: const Color(0xFF202124),
                child: Center(
                  child: CircleAvatar(
                    radius: 28,
                    child: Text(
                      label.isEmpty
                          ? '?'
                          : label.characters.first.toUpperCase(),
                    ),
                  ),
                ),
              ),
          Positioned(
            left: 8,
            bottom: 8,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (micMuted) ...[
                      const Icon(Icons.mic_off, size: 16, color: Colors.white),
                      const SizedBox(width: 4),
                    ],
                    Text(label, style: const TextStyle(color: Colors.white)),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The desktop "choose what to share" dialog.
class _ScreenPickerDialog extends StatefulWidget {
  const _ScreenPickerDialog({required this.picker});

  final ScreenSourcePicker picker;

  @override
  State<_ScreenPickerDialog> createState() => _ScreenPickerDialogState();
}

class _ScreenPickerDialogState extends State<_ScreenPickerDialog> {
  @override
  void initState() {
    super.initState();
    widget.picker.start();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Share your screen'),
      content: SizedBox(
        width: 560,
        height: 380,
        child: StreamBuilder<ScreenPickerState>(
          stream: widget.picker.state,
          initialData: widget.picker.currentState,
          builder: (context, snapshot) {
            final state = snapshot.data!;
            if (state.error != null && state.sources.isEmpty) {
              return const Center(
                child: Text('Listing screens failed. Close and try again.'),
              );
            }
            if (state.sources.isEmpty) {
              return const Center(child: CircularProgressIndicator());
            }
            return GridView.extent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 4 / 3,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
              children: [
                for (final source in state.sources)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(source),
                    child: Column(
                      children: [
                        Expanded(
                          child: source.thumbnail == null
                              ? Icon(
                                  source.type == ScreenSourceType.screen
                                      ? Icons.desktop_windows
                                      : Icons.web_asset,
                                  size: 40,
                                )
                              : Image.memory(
                                  source.thumbnail!,
                                  gaplessPlayback: true,
                                ),
                        ),
                        Text(
                          source.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}
