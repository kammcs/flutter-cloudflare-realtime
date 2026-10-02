import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

import 'audio_routes_sheet.dart';
import 'screen_share_dialog.dart';

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
/// outlined, and the dominant speaker gets a star.
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

  /// Stage layout (one big tile and thumbnails) instead of the gallery.
  bool _stageLayout = false;

  /// The tile the user put on the stage, if any.
  String? _pinned;

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
              tooltip: _stageLayout ? 'Gallery layout' : 'Stage layout',
              icon: Icon(_stageLayout ? Icons.grid_view : Icons.view_agenda),
              onPressed: () => setState(() => _stageLayout = !_stageLayout),
            ),
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
  List<_TileData> _tiles(List<RemoteParticipant> remotes) {
    final camera = _local.camera;
    final screen = _local.screen;
    return [
      _TileData(
        id: 'local',
        label: '${widget.setup.displayName} (you)',
        participantId: _local.participantId,
        micMuted: _local.microphone?.muted ?? true,
        speaking: _local.speakingChanges,
        video: camera == null
            ? null
            : ParticipantVideoView.local(camera.mediaSource),
      ),
      if (screen != null)
        _TileData(
          id: 'local-screen',
          label: 'Your screen',
          video: ParticipantVideoView.local(
            screen.mediaSource,
            fit: VideoViewFit.contain,
          ),
        ),
      for (final remote in remotes) ...[
        _TileData(
          id: remote.camera?.id ?? remote.participantId,
          label: _nameOf(remote),
          participantId: remote.participantId,
          micMuted: remote.microphone?.muted ?? true,
          speaking: remote.speakingChanges,
          publication: remote.camera,
          video: remote.camera == null
              ? null
              : ParticipantVideoView.remote(remote.camera!),
        ),
        if (remote.screen case final share?)
          _TileData(
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

  Widget _buildGrid(List<_TileData> tiles, String? dominant) {
    return GridView.extent(
      padding: const EdgeInsets.all(8),
      maxCrossAxisExtent: 480,
      childAspectRatio: 16 / 9,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: [
        for (final tile in tiles)
          _Tile(
            key: ValueKey(tile.id),
            data: tile,
            session: () => _room.session,
            dominant:
                tile.participantId != null && tile.participantId == dominant,
          ),
      ],
    );
  }

  /// One big tile (the pinned one, else a remote screen share, else the
  /// dominant speaker, else the first remote) and a strip of thumbnails.
  /// The stage pulls the full layer (`a`), the thumbnails the lowest (`c`).
  Widget _buildStage(List<_TileData> tiles, String? dominant) {
    _TileData? pick(bool Function(_TileData) test) {
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
              child: _Tile(
                key: ValueKey(stage.id),
                data: stage,
                session: () => _room.session,
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
                        child: _Tile(
                          key: ValueKey(tile.id),
                          data: tile,
                          session: () => _room.session,
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
            if (cameraOn)
              IconButton.filledTonal(
                tooltip: 'Switch camera',
                icon: const Icon(Icons.cameraswitch),
                onPressed: _busy ? null : _switchCamera,
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

/// What one tile shows.
class _TileData {
  const _TileData({
    required this.id,
    required this.label,
    this.participantId,
    this.video,
    this.micMuted = false,
    this.speaking,
    this.publication,
  });

  /// Stable across rebuilds (the publication ID for remote tracks).
  final String id;
  final String label;

  /// Whose tile this is, for the speaking highlight. `null` for screens.
  final String? participantId;
  final Widget? video;
  final bool micMuted;
  final Stream<bool>? speaking;

  /// The remote video shown, for the layer overlay.
  final RemoteTrackPublication? publication;
}

/// One participant's (or screen's) video, with a name label, a speaking
/// highlight, and for remote video the simulcast layer overlay.
class _Tile extends StatelessWidget {
  const _Tile({
    super.key,
    required this.data,
    required this.session,
    this.dominant = false,
    this.pinned = false,
    this.compact = false,
  });

  final _TileData data;
  final SfuSession Function() session;

  /// The dominant speaker: a thicker highlight and a star.
  final bool dominant;
  final bool pinned;

  /// A thumbnail: smaller labels, no layer menu.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: data.speaking,
      initialData: false,
      builder: (context, snapshot) {
        final speaking = snapshot.data ?? false;
        final Color? borderColor = speaking
            ? Colors.greenAccent
            : dominant
            ? Colors.amber
            : null;
        return Container(
          foregroundDecoration: borderColor == null
              ? null
              : BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: borderColor,
                    width: dominant ? 4 : 2,
                  ),
                ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                data.video ?? _Avatar(label: data.label),
                Positioned(
                  left: 6,
                  bottom: 6,
                  right: 6,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: _Label(
                      label: data.label,
                      micMuted: data.micMuted,
                      speaking: speaking,
                      dominant: dominant,
                      pinned: pinned,
                      compact: compact,
                    ),
                  ),
                ),
                if (data.publication case final publication?
                    when data.video != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: _LayerOverlay(
                      publication: publication,
                      session: session,
                      compact: compact,
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF202124),
    child: Center(
      child: CircleAvatar(
        radius: 28,
        child: Text(label.isEmpty ? '?' : label.characters.first.toUpperCase()),
      ),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label({
    required this.label,
    required this.micMuted,
    required this.speaking,
    required this.dominant,
    required this.pinned,
    required this.compact,
  });

  final String label;
  final bool micMuted;
  final bool speaking;
  final bool dominant;
  final bool pinned;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 12.0 : 16.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            if (micMuted)
              Icon(Icons.mic_off, size: size, color: Colors.white)
            else if (speaking)
              Icon(Icons.graphic_eq, size: size, color: Colors.greenAccent),
            if (dominant) Icon(Icons.star, size: size, color: Colors.amber),
            if (pinned) Icon(Icons.push_pin, size: size, color: Colors.white),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontSize: size - 2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Debug overlay for a remote video: the simulcast layer asked for, the
/// resolution actually received (from `getStats()`), and a menu to override
/// the automatic layer.
class _LayerOverlay extends StatefulWidget {
  const _LayerOverlay({
    required this.publication,
    required this.session,
    this.compact = false,
  });

  final RemoteTrackPublication publication;
  final SfuSession Function() session;
  final bool compact;

  @override
  State<_LayerOverlay> createState() => _LayerOverlayState();
}

class _LayerOverlayState extends State<_LayerOverlay> {
  Timer? _timer;
  String? _resolution;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _readStats());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The received size and frame rate, from the pull's `inbound-rtp`.
  Future<void> _readStats() async {
    final mid = widget.publication.subscription?.mid;
    String? resolution;
    if (mid != null) {
      try {
        for (final report in await widget.session().getStats()) {
          final values = report.values;
          if (report.type != 'inbound-rtp' ||
              values['kind'] != 'video' ||
              values['mid'] != mid) {
            continue;
          }
          final width = values['frameWidth'];
          final height = values['frameHeight'];
          final fps = values['framesPerSecond'];
          if (width is num && height is num) {
            resolution =
                '${width.round()}×${height.round()}'
                '${fps is num ? ' ${fps.round()}fps' : ''}';
          }
        }
      } catch (_) {
        // Stats can fail briefly (renegotiation, a closed session).
      }
    }
    if (mounted && resolution != _resolution) {
      setState(() => _resolution = resolution);
    }
  }

  Future<void> _choose(SimulcastLayer? layer) async {
    try {
      await widget.publication.setPreferredLayer(layer);
    } on Exception catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Layer change failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RemoteTrackLayerState>(
      stream: widget.publication.layerChanges,
      initialData: widget.publication.layerState,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final manual = state.preferredLayer;
        final rid = state.currentRid ?? '-';
        final mode = manual == null ? 'auto' : manual.name;
        final text = [
          'rid $rid ($mode)',
          if (state.hidden) 'hidden',
          ?_resolution,
        ].join(' · ');
        final chip = DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black54,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white,
                fontSize: widget.compact ? 10 : 12,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        );
        if (widget.compact || widget.publication.simulcast == null) {
          return chip;
        }
        // A null value would read as "cancelled", so "auto" is a string.
        return PopupMenuButton<String>(
          tooltip: 'Simulcast layer',
          onSelected: (choice) => _choose(
            choice == 'auto' ? null : SimulcastLayer.values.byName(choice),
          ),
          itemBuilder: (context) => [
            CheckedPopupMenuItem(
              value: 'auto',
              checked: manual == null,
              child: const Text('Auto (from tile size)'),
            ),
            for (final layer in SimulcastLayer.values)
              CheckedPopupMenuItem(
                value: layer.name,
                checked: manual == layer,
                child: Text(
                  '${layer.name[0].toUpperCase()}${layer.name.substring(1)}'
                  ' (${layer.ridIn(widget.publication.simulcast!.rids)})',
                ),
              ),
          ],
          child: chip,
        );
      },
    );
  }
}
