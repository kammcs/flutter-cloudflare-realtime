import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/material.dart';

/// Signaling without media: who is in the room, through
/// [InMemorySignaling]. Shown when no broker is configured, so the demo
/// runs without any backend.
class PresencePage extends StatefulWidget {
  const PresencePage({super.key, required this.hub, required this.signaling});

  final InMemorySignalingHub hub;

  /// Already joined.
  final InMemorySignaling signaling;

  @override
  State<PresencePage> createState() => _PresencePageState();
}

class _PresencePageState extends State<PresencePage> {
  /// Simulated participants this page added, by participant ID.
  final Map<String, InMemorySignaling> _guests = {};
  int _guestCount = 0;
  late final Stream<List<ParticipantState>> _participants =
      widget.signaling.participants;

  Future<void> _addGuest() async {
    final roomId = widget.signaling.roomId;
    if (roomId == null) return;
    final id = 'guest-${++_guestCount}';
    final guest = InMemorySignaling(widget.hub);
    await guest.join(
      roomId,
      ParticipantState(
        participantId: id,
        sessionId: 'simulated-session-$_guestCount',
        tracks: const {
          'cam': TrackInfo(kind: TrackKind.video, source: TrackSource.camera),
          'mic': TrackInfo(
            kind: TrackKind.audio,
            source: TrackSource.microphone,
          ),
        },
      ),
    );
    setState(() => _guests[id] = guest);
  }

  Future<void> _removeGuest(String id) async {
    await _guests.remove(id)?.dispose();
    setState(() {});
  }

  Future<void> _leave() async {
    await _disposeAll();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _disposeAll() async {
    for (final guest in _guests.values) {
      await guest.dispose();
    }
    _guests.clear();
    await widget.signaling.dispose();
  }

  @override
  void dispose() {
    _disposeAll();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Room: ${widget.signaling.roomId}'),
        actions: [
          IconButton(
            tooltip: 'Leave',
            icon: const Icon(Icons.logout),
            onPressed: _leave,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addGuest,
        icon: const Icon(Icons.person_add),
        label: const Text('Add simulated participant'),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text('Presence only'),
            subtitle: Text(
              'Set a broker URL on the join screen to make calls.',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              'You are ${widget.signaling.self?.participantId}. '
              'Others in the room:',
              style: Theme.of(context).textTheme.titleSmall,
            ),
          ),
          Expanded(
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
        .map(
          (e) =>
              '${e.key} (${e.value.kind.name}, ${e.value.source.name}'
              '${e.value.muted ? ', muted' : ''})',
        )
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
