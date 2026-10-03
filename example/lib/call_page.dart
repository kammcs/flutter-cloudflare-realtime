import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

import 'audio_routes_sheet.dart';
import 'call_tile.dart';
import 'device_settings.dart';
import 'screen_share_dialog.dart';
import 'system_call_demo.dart';

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

/// A call: video tiles for everyone, with mute, screen share and leave
/// controls.
///
/// For the week-6 checkpoint it shows simulcast layer switching: a
/// gallery/stage toggle (the stage pulls the full layer, thumbnails the
/// lowest), a per-tile overlay with the RID asked for and the resolution
/// received, and a menu to override the layer. Speaking participants are
/// outlined, and the dominant speaker gets a star. Each tile shows its
/// participant's connection quality as bars, and the stats button adds the
/// typed stats (layers sent, bitrate, loss, RTT) to the overlays.
///
/// Above the controls, the microphone in use and its level; tapping it (or
/// the "Devices" button) opens the device settings, where the microphone,
/// camera and speaker can be changed during the call.
class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.room,
    required this.setup,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
    this.publishOnStart = true,
    this.systemCall,
  });

  final Room room;
  final CallSetup setup;

  /// Used for the desktop screen picker.
  final MediaBackend mediaBackend;

  /// Whether to publish the microphone and camera when the page opens.
  final bool publishOnStart;

  /// The system call (CallKit, Android Telecom) this call is, if any: the
  /// room follows it (mute, hold, ending), docs/design.md §4.8.
  final SystemCall? systemCall;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  late final StreamSubscription<RoomEvent> _events;
  bool _left = false;
  bool _busy = false;

  /// Stage layout (one big tile and thumbnails) instead of the gallery.
  bool _stageLayout = false;

  /// The tile the user put on the stage, if any.
  String? _pinned;

  /// Whether the tiles show the typed stats (Room.stats).
  bool _showStats = false;

  /// One key per tile, so a tile that moves (gallery to stage, stage to
  /// thumbnails) keeps its state, and its video view keeps its renderer,
  /// instead of being built afresh in its new place.
  final Map<String, GlobalKey> _tileKeys = {};

  /// The speaker chosen in the device settings, if any.
  final ValueNotifier<String?> _audioOutput = ValueNotifier(null);

  Room get _room => widget.room;
  LocalParticipant get _local => _room.localParticipant;

  @override
  void initState() {
    super.initState();
    _events = _room.events.listen(_onEvent);
    if (widget.systemCall case final call?) {
      // Mute in step with the system's; the room leaves when the call ends
      // (for example from the lock screen), and ends it when it leaves.
      _room.attachSystemCall(call);
      call.whenEnded.then((reason) {
        _show('The system call ended (${reason.name}).');
        _leave();
      });
    }
    if (widget.publishOnStart) {
      _run(() async {
        await _local.publishMicrophone();
        await _local.publishCamera();
      });
    }
  }

  void _onEvent(RoomEvent event) {
    switch (event) {
      case RoomSessionFailedEvent(:final failure)
          when !_room.options.reconnect.enabled:
        _show('The SFU session failed (${failure.reason}).');
      case RoomReconnectingEvent(:final reason):
        _show('Connection lost (${reason.name}). Reconnecting…');
      case RoomReconnectedEvent(:final duration, :final attempts):
        final seconds = (duration.inMilliseconds / 1000).toStringAsFixed(1);
        _show(
          'Reconnected in $seconds s'
          '${attempts > 1 ? ' ($attempts attempts)' : ''}.',
        );
      case RoomReconnectFailedEvent():
        _show('Could not reconnect. Use "Reconnect" to try again.');
      case ParticipantJoinedEvent(:final participant):
        _show('${_nameOf(participant)} joined.');
      case ParticipantLeftEvent(:final participant):
        _show('${_nameOf(participant)} left.');
      case LocalTrackUnpublishedEvent(:final endReason?, :final publication)
          when publication.source == TrackSource.screen:
        _show(switch (endReason) {
          ScreenShareEndReason.userStopped => 'You stopped sharing.',
          ScreenShareEndReason.sourceClosed =>
            'Screen share ended: the shared window or display went away.',
          ScreenShareEndReason.stopped => 'Screen share ended.',
        });
      case LocalScreenShareStalledEvent(:final error, :final publication):
        _showStalledShare(publication, error);
      case _:
        break;
    }
  }

  /// A share that sends no frames: on macOS, almost always the missing
  /// Screen Recording permission.
  Future<void> _showStalledShare(
    LocalMediaPublication share,
    MediaException error,
  ) async {
    if (!mounted) return;
    final stop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.screen_share_outlined),
        title: const Text('Your screen share is empty'),
        content: Text(
          error is ScreenCapturePermissionException
              ? '${error.message}\n\n${error.guidance}'
              : error.message,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep sharing'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop sharing'),
          ),
        ],
      ),
    );
    if (stop ?? false) await _run(share.unpublish);
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
    } on ScreenShareSetupException catch (e) {
      // A developer's mistake: the console says what to fix.
      debugPrint('Screen share setup: ${e.guidance}');
      _show('Screen sharing is not set up in this build (see the log).');
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

  Future<void> _switchCamera() => _run(() async {
    await _local.switchCamera();
  });

  void _showDevices() => showDeviceSettingsSheet(context, _room, _audioOutput);

  Future<void> _toggleScreen() => _run(() async {
    final screen = _local.screen;
    if (screen != null) {
      await screen.unpublish();
      return;
    }
    final platform = widget.mediaBackend.platform;
    final web = platform == MediaPlatform.web;
    if (platform == MediaPlatform.android || platform == MediaPlatform.ios) {
      // The system's consent dialog (Android) or broadcast picker (iOS) is
      // the picker: no dialog of ours. On iOS this completes once the user
      // taps "Start Broadcast".
      await _local.publishScreen();
      return;
    }
    ScreenSourcePicker? picker;
    if (!web) {
      picker = ScreenSourcePicker(backend: widget.mediaBackend);
      if (!picker.isSupported) {
        await picker.dispose();
        _show('Screen share is not available on this platform.');
        return;
      }
    }
    final ShareChoice? choice;
    try {
      choice = await showDialog<ShareChoice>(
        context: context,
        builder: (_) => ScreenShareDialog(
          picker: picker,
          // Loopback audio on Windows, tab audio in Chromium browsers.
          canShareAudio: web || platform == MediaPlatform.windows,
        ),
      );
    } finally {
      await picker?.dispose();
    }
    if (choice == null) return;
    // On the web the browser shows its own picker now.
    await _local.publishScreen(
      source: choice.source,
      options: choice.options,
      encodings: choice.encodings,
    );
  });

  /// The checkpoint demo: fails the SFU session as a network drop would,
  /// so the room's automatic recovery can be watched without pulling a
  /// cable. Debug and demo only (see Room.debugSimulateConnectionFailure).
  void _simulateNetworkDrop() {
    if (_left) return;
    _room.debugSimulateConnectionFailure();
  }

  Future<void> _reconnect() async {
    if (_left) return;
    await _room.reconnect();
  }

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
    _audioOutput.dispose();
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
            IconButton(
              tooltip: _showStats ? 'Hide stats' : 'Show stats',
              isSelected: _showStats,
              icon: const Icon(Icons.query_stats),
              onPressed: () => setState(() => _showStats = !_showStats),
            ),
            IconButton(
              tooltip: _stageLayout ? 'Gallery layout' : 'Stage layout',
              icon: Icon(_stageLayout ? Icons.grid_view : Icons.view_agenda),
              onPressed: () => setState(() => _stageLayout = !_stageLayout),
            ),
            if (widget.systemCall case final call?)
              SystemCallHoldButton(call: call),
            if (widget.setup.addSimulatedParticipant case final add?)
              IconButton(
                tooltip: 'Add simulated participant',
                icon: const Icon(Icons.person_add),
                onPressed: add,
              ),
            IconButton(
              tooltip: 'Simulate network drop (debug)',
              icon: const Icon(Icons.wifi_off),
              onPressed: _simulateNetworkDrop,
            ),
            IconButton(
              tooltip: 'Leave',
              icon: const Icon(Icons.call_end),
              onPressed: _leave,
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              _ConnectionBanner(room: _room, onReconnect: _reconnect),
              _AudioBlockedBanner(room: _room),
              Expanded(
                child: StreamBuilder<LocalParticipant>(
                  stream: _local.changes,
                  builder: (context, _) =>
                      StreamBuilder<List<RemoteParticipant>>(
                        stream: _room.participants,
                        initialData: _room.currentParticipants,
                        builder: (context, snapshot) =>
                            _buildLayout(snapshot.data ?? const []),
                      ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: StreamBuilder<LocalParticipant>(
          stream: _local.changes,
          builder: (context, _) => _buildControls(),
        ),
      ),
    );
  }

  /// Everyone's tiles, in order: you, your screen, then each remote
  /// participant's camera and screen.
  List<CallTileData> _tiles(List<RemoteParticipant> remotes) {
    final tiles = _tileData(remotes);
    final ids = {for (final tile in tiles) tile.id};
    _tileKeys.removeWhere((id, _) => !ids.contains(id));
    return tiles;
  }

  GlobalKey _keyOf(CallTileData tile) =>
      _tileKeys.putIfAbsent(tile.id, GlobalKey.new);

  List<CallTileData> _tileData(List<RemoteParticipant> remotes) {
    final camera = _local.camera;
    final screen = _local.screen;
    return [
      CallTileData(
        id: 'local',
        label: '${widget.setup.displayName} (you)',
        participantId: _local.participantId,
        participant: _local,
        localPublication: camera,
        micMuted: _local.microphone?.muted ?? true,
        speaking: _local.speakingChanges,
        video: camera == null
            ? null
            : ParticipantVideoView.local(camera.mediaSource),
      ),
      if (screen != null)
        CallTileData(
          id: 'local-screen',
          label: 'Your screen',
          localPublication: screen,
          video: ParticipantVideoView.local(
            screen.mediaSource,
            fit: VideoViewFit.contain,
          ),
        ),
      for (final remote in remotes) ...[
        CallTileData(
          id: remote.camera?.id ?? remote.participantId,
          label: _nameOf(remote),
          participantId: remote.participantId,
          participant: remote,
          micMuted: remote.microphone?.muted ?? true,
          speaking: remote.speakingChanges,
          publication: remote.camera,
          video: remote.camera == null
              ? null
              : ParticipantVideoView.remote(remote.camera!),
        ),
        if (remote.screen case final share?)
          CallTileData(
            id: share.id,
            label: "${_nameOf(remote)}'s screen",
            publication: share,
            video: ParticipantVideoView.remote(
              share,
              fit: VideoViewFit.contain,
            ),
          ),
      ],
    ];
  }

  Widget _buildLayout(List<RemoteParticipant> remotes) {
    // Rebuilt when the dominant speaker changes: it gets the highlight, and
    // the stage in the stage layout.
    return StreamBuilder<String?>(
      stream: _room.dominantSpeaker,
      initialData: _room.currentDominantSpeaker,
      builder: (context, snapshot) {
        final dominant = snapshot.data;
        final tiles = _tiles(remotes);
        return _stageLayout
            ? _buildStage(tiles, dominant)
            : _buildGrid(tiles, dominant);
      },
    );
  }

  Widget _buildGrid(List<CallTileData> tiles, String? dominant) {
    return GridView.extent(
      padding: const EdgeInsets.all(8),
      maxCrossAxisExtent: 480,
      childAspectRatio: 16 / 9,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final tile in tiles)
          CallTile(
            key: _keyOf(tile),
            data: tile,
            showStats: _showStats,
            dominant:
                tile.participantId != null && tile.participantId == dominant,
          ),
      ],
    );
  }

  /// One big tile (the pinned one, else a remote screen share, else the
  /// dominant speaker, else the first remote) and a strip of thumbnails.
  /// The stage pulls the full layer (`a`), the thumbnails the lowest (`c`).
  Widget _buildStage(List<CallTileData> tiles, String? dominant) {
    CallTileData? pick(bool Function(CallTileData) test) {
      for (final tile in tiles) {
        if (test(tile)) return tile;
      }
      return null;
    }

    final stage =
        pick((t) => t.id == _pinned) ??
        pick((t) => t.publication?.source == TrackSource.screen) ??
        pick((t) => t.participantId != null && t.participantId == dominant) ??
        pick((t) => t.publication != null) ??
        tiles.first;
    final others = [
      for (final tile in tiles)
        if (tile.id != stage.id) tile,
    ];
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: GestureDetector(
              onDoubleTap: () => setState(() => _pinned = null),
              child: CallTile(
                key: _keyOf(stage),
                data: stage,
                showStats: _showStats,
                dominant: stage.participantId == dominant,
                pinned: stage.id == _pinned,
              ),
            ),
          ),
        ),
        if (others.isNotEmpty)
          SizedBox(
            height: 112,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: [
                for (final tile in others)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: AspectRatio(
                      aspectRatio: 16 / 9,
                      child: GestureDetector(
                        onTap: () => setState(() => _pinned = tile.id),
                        child: CallTile(
                          key: _keyOf(tile),
                          data: tile,
                          showStats: _showStats,
                          dominant:
                              tile.participantId != null &&
                              tile.participantId == dominant,
                          compact: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildControls() {
    final micOn = !(_local.microphone?.muted ?? true);
    final cameraOn = !(_local.camera?.muted ?? true);
    final sharing = _local.screen != null;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MicStatus(participant: _local, onTap: _showDevices),
            _buildButtons(micOn: micOn, cameraOn: cameraOn, sharing: sharing),
          ],
        ),
      ),
    );
  }

  Widget _buildButtons({
    required bool micOn,
    required bool cameraOn,
    required bool sharing,
  }) {
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 16,
      runSpacing: 8,
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
        if (cameraOn)
          IconButton.filledTonal(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: _busy ? null : _switchCamera,
          ),
        IconButton.filledTonal(
          tooltip: 'Devices',
          icon: const Icon(Icons.tune),
          onPressed: _showDevices,
        ),
        if (_room.canSelectAudioRoute)
          StreamBuilder<AudioRoute?>(
            stream: _room.audioRouteChanges,
            initialData: _room.currentAudioRoute,
            builder: (context, route) => IconButton.filledTonal(
              tooltip: 'Audio output',
              icon: Icon(audioRouteIcon(route.data?.kind)),
              onPressed: () => showAudioRoutesSheet(context, _room),
            ),
          ),
        IconButton.filledTonal(
          tooltip: sharing ? 'Stop sharing' : 'Share screen',
          icon: Icon(sharing ? Icons.stop_screen_share : Icons.screen_share),
          onPressed: _busy ? null : _toggleScreen,
        ),
        IconButton.filled(
          tooltip: 'Leave call',
          style: IconButton.styleFrom(backgroundColor: Colors.red),
          icon: const Icon(Icons.call_end),
          onPressed: _leave,
        ),
      ],
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

/// A strip above the tiles while the call isn't connected: a progress bar
/// while the room replaces its session, or a "Reconnect" button once it
/// has given up.
class _ConnectionBanner extends StatelessWidget {
  const _ConnectionBanner({required this.room, required this.onReconnect});

  final Room room;
  final Future<void> Function() onReconnect;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RoomConnectionState>(
      stream: room.connectionState,
      initialData: room.currentConnectionState,
      builder: (context, snapshot) {
        final theme = Theme.of(context);
        switch (snapshot.data) {
          case RoomConnectionState.reconnecting:
            return Material(
              color: theme.colorScheme.tertiaryContainer,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(),
                  Padding(
                    padding: EdgeInsets.all(8),
                    child: Text(
                      'Reconnecting… your camera and microphone '
                      'keep running.',
                    ),
                  ),
                ],
              ),
            );
          case RoomConnectionState.disconnected when !room.hasLeft:
            return Material(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  children: [
                    const Expanded(child: Text('Disconnected from the call.')),
                    TextButton(
                      onPressed: onReconnect,
                      child: const Text('Reconnect'),
                    ),
                  ],
                ),
              ),
            );
          case _:
            return const SizedBox.shrink();
        }
      },
    );
  }
}

/// A "Click to enable audio" banner while the browser's autoplay policy
/// blocks remote audio (web only; native platforms never block). The
/// click is the user gesture the browser waits for.
class _AudioBlockedBanner extends StatelessWidget {
  const _AudioBlockedBanner({required this.room});

  final Room room;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: room.audioPlaybackBlockedChanges,
      initialData: room.audioPlaybackBlocked,
      builder: (context, snapshot) {
        if (snapshot.data != true) return const SizedBox.shrink();
        return Material(
          color: Theme.of(context).colorScheme.secondaryContainer,
          child: InkWell(
            // Call startAudio() straight from the tap, with nothing
            // awaited first, so the browser counts the gesture.
            onTap: room.startAudio,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(Icons.volume_off),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your browser blocked the call audio. '
                      'Click to enable audio.',
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
