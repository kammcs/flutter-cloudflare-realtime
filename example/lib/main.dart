import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(ExampleApp(hub: InMemorySignalingHub()));
}

/// The example app.
///
/// Signaling runs in memory for now: every participant shares [hub], so the
/// demo works in a single process without a backend.
class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.hub});

  final InMemorySignalingHub hub;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'cloudflare_realtime example',
      theme: ThemeData(colorSchemeSeed: Colors.orange),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.orange,
        brightness: Brightness.dark,
      ),
      home: RoomDemoPage(hub: hub),
    );
  }
}

/// Joins a room through [InMemorySignaling] and lists who else is there.
class RoomDemoPage extends StatefulWidget {
  const RoomDemoPage({super.key, required this.hub});

  final InMemorySignalingHub hub;

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
  final _brokerUrlController = TextEditingController();
  final _brokerTokenController = TextEditingController();
  late final InMemorySignaling _signaling = InMemorySignaling(widget.hub);

  /// The broker and SFU session, when a broker URL was given.
  HttpBrokerClient? _broker;
  SfuSession? _session;
  bool _joining = false;
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
    if (roomId.isEmpty || name.isEmpty || _joining) return;
    setState(() => _joining = true);
    try {
      final sessionId = await _connectSession(roomId);
      await _signaling.join(
        roomId,
        ParticipantState(
          participantId: name,
          sessionId: sessionId,
          metadata: {'displayName': name},
        ),
      );
      // TODO(M3): replace this with a Room: publish the local camera and
      // microphone (once the media layer lands) and pull what others
      // publish.
      setState(() => _error = null);
    } on StateError catch (e) {
      await _closeSession();
      setState(() => _error = e.message);
    } on Exception catch (e) {
      // Broker and session exceptions never contain SDP or tokens.
      await _closeSession();
      setState(() => _error = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  /// Creates an SFU session through the broker, if a broker URL was given.
  /// Returns its session ID, or null without a broker.
  Future<String?> _connectSession(String roomId) async {
    final url = _brokerUrlController.text.trim();
    if (url.isEmpty) return null;
    final token = _brokerTokenController.text.trim();
    final broker = _broker = HttpBrokerClient(
      roomId: roomId,
      config: BrokerConfig(
        baseUrl: Uri.parse(url),
        headers: () async => {
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ),
    );
    final session = _session = await SfuSession.connect(broker: broker);
    return session.sessionId;
  }

  Future<void> _closeSession() async {
    await _session?.close();
    _session = null;
    _broker?.dispose();
    _broker = null;
  }

  Future<void> _leave() async {
    for (final guest in _guests.values) {
      await guest.dispose();
    }
    _guests.clear();
    await _signaling.leave();
    await _closeSession();
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

  @override
  void dispose() {
    for (final guest in _guests.values) {
      guest.dispose();
    }
    _signaling.dispose();
    _session?.close();
    _broker?.dispose();
    _roomController.dispose();
    _nameController.dispose();
    _brokerUrlController.dispose();
    _brokerTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_joined ? 'Room: ${_signaling.roomId}' : 'Join a room'),
        actions: [
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
              const SizedBox(height: 8),
              TextField(
                controller: _brokerUrlController,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Broker URL (optional)',
                  helperText: 'Set it to create a real SFU session.',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _brokerTokenController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Broker bearer token (optional)',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _joining ? null : _join,
                child: Text(_joining ? 'Connecting…' : 'Join'),
              ),
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
        if (_session case final session?) _SessionStatus(session: session),
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

/// Where video tiles will go once rooms can pull media (roadmap M3).
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

/// The SFU session's ID and connection state.
class _SessionStatus extends StatelessWidget {
  const _SessionStatus({required this.session});

  final SfuSession session;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<SfuConnectionState>(
      stream: session.connectionState,
      initialData: session.currentConnectionState,
      builder: (context, snapshot) => ListTile(
        leading: const Icon(Icons.cloud_outlined),
        title: Text('SFU session ${session.sessionId}'),
        subtitle: Text(
          'Connection: ${snapshot.data?.name}'
          '${session.failure == null ? '' : ' (${session.failure!.reason})'}',
        ),
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
