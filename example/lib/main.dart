import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

import 'local_media_page.dart';

void main() {
  runApp(ExampleApp(hub: InMemorySignalingHub()));
}

/// The example app.
///
/// Signaling runs in memory for now: every participant shares [hub], so the
/// demo works in a single process without a backend.
class ExampleApp extends StatelessWidget {
  const ExampleApp({
    super.key,
    required this.hub,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
  });

  final InMemorySignalingHub hub;

  /// Where the local media page captures from. Tests pass a fake.
  final MediaBackend mediaBackend;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cloudflare_realtime example',
      theme: ThemeData(colorSchemeSeed: Colors.orange),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.orange,
        brightness: Brightness.dark,
      ),
      home: RoomDemoPage(hub: hub, mediaBackend: mediaBackend),
    );
  }
}

/// Joins a room through [InMemorySignaling] and lists who else is there.
class RoomDemoPage extends StatefulWidget {
  const RoomDemoPage({
    super.key,
    required this.hub,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
  });

  final InMemorySignalingHub hub;
  final MediaBackend mediaBackend;

  @override
  State<RoomDemoPage> createState() => _RoomDemoPageState();
}

class _RoomDemoPageState extends State<RoomDemoPage> {
  static const _camera = TrackInfo(
    kind: TrackKind.video,
    source: TrackSource.camera,
  );
  static const _microphone = TrackInfo(
    kind: TrackKind.audio,
    source: TrackSource.microphone,
  );

  final _roomController = TextEditingController(text: 'demo');
  final _nameController = TextEditingController(text: 'me');
  late final InMemorySignaling _signaling = InMemorySignaling(widget.hub);
  late final Stream<List<ParticipantState>> _participants =
      _signaling.participants;

  /// Simulated participants this page added, by participant ID.
  final Map<String, InMemorySignaling> _guests = {};
  int _guestCount = 0;
  String? _error;

  bool get _joined => _signaling.roomId != null;

  Future<void> _join() async {
    final roomId = _roomController.text.trim();
    final name = _nameController.text.trim();
    if (roomId.isEmpty || name.isEmpty) return;
    try {
      await _signaling.join(
        roomId,
        ParticipantState(participantId: name, metadata: {'displayName': name}),
      );
      setState(() => _error = null);
    } on StateError catch (e) {
      setState(() => _error = e.message);
    }
  }

  Future<void> _leave() async {
    for (final guest in _guests.values) {
      await guest.dispose();
    }
    _guests.clear();
    await _signaling.leave();
    setState(() {});
  }

  Future<void> _addGuest() async {
    final roomId = _signaling.roomId;
    if (roomId == null) return;
    final id = 'guest-${++_guestCount}';
    final guest = InMemorySignaling(widget.hub);
    await guest.join(
      roomId,
      ParticipantState(
        participantId: id,
        sessionId: 'simulated-session-$_guestCount',
        tracks: {'$id-cam': _camera, '$id-mic': _microphone},
      ),
    );
    setState(() => _guests[id] = guest);
  }

  Future<void> _removeGuest(String id) async {
    await _guests.remove(id)?.dispose();
    setState(() {});
  }

  void _openLocalMedia() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalMediaPage(backend: widget.mediaBackend),
      ),
    );
  }

  @override
  void dispose() {
    for (final guest in _guests.values) {
      guest.dispose();
    }
    _signaling.dispose();
    _roomController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_joined ? 'Room: ${_signaling.roomId}' : 'Join a room'),
        actions: [
          IconButton(
            tooltip: 'Local media',
            icon: const Icon(Icons.perm_camera_mic),
            onPressed: _openLocalMedia,
          ),
          if (_joined)
            IconButton(
              tooltip: 'Leave',
              icon: const Icon(Icons.logout),
              onPressed: _leave,
            ),
        ],
      ),
      body: SafeArea(child: _joined ? _buildRoom() : _buildJoinForm()),
      floatingActionButton: _joined
          ? FloatingActionButton.extended(
              onPressed: _addGuest,
              icon: const Icon(Icons.person_add),
              label: const Text('Add simulated participant'),
            )
          : null,
    );
  }

  Widget _buildJoinForm() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _roomController,
                decoration: const InputDecoration(labelText: 'Room ID'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Your name'),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: _join, child: const Text('Join')),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoom() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Expanded(flex: 2, child: _VideoPlaceholder()),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: Text(
            'You are ${_signaling.self?.participantId}. Others in the room:',
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Expanded(
          flex: 3,
          child: StreamBuilder<List<ParticipantState>>(
            stream: _participants,
            initialData: const [],
            builder: (context, snapshot) {
              final participants = snapshot.data ?? const [];
              if (participants.isEmpty) {
                return const Center(child: Text('No one else is here yet.'));
              }
              return ListView(
                padding: const EdgeInsets.only(bottom: 88),
                children: [
                  for (final p in participants)
                    _ParticipantTile(
                      participant: p,
                      onRemove: _guests.containsKey(p.participantId)
                          ? () => _removeGuest(p.participantId)
                          : null,
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Where video tiles will go once rooms can pull media (roadmap M2 and M3).
class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.videocam_outlined, size: 48, color: colors.outline),
          const SizedBox(height: 8),
          const Text('Video tiles will appear here.'),
        ],
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant, this.onRemove});

  final ParticipantState participant;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final tracks = participant.tracks.entries
        .map((e) => '${e.key} (${e.value.kind.name}, ${e.value.source.name})')
        .join(', ');
    return ListTile(
      leading: const Icon(Icons.person),
      title: Text(participant.participantId),
      subtitle: Text(
        'Session: ${participant.sessionId ?? 'none'}\n'
        'Tracks: ${tracks.isEmpty ? 'none' : tracks}',
      ),
      isThreeLine: true,
      trailing: onRemove == null
          ? null
          : IconButton(
              tooltip: 'Remove',
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
    );
  }
}
