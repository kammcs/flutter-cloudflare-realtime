import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

import 'call_page.dart';
import 'dev_config.dart';
import 'local_media_page.dart';
import 'network_changes.dart';
import 'presence_page.dart';
import 'ws_signaling.dart';

void main() {
  runApp(ExampleApp(hub: InMemorySignalingHub()));
}

/// The example app.
class ExampleApp extends StatelessWidget {
  const ExampleApp({
    super.key,
    required this.hub,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
  });

  /// Shared by every in-memory participant in this process.
  final InMemorySignalingHub hub;

  /// Where local media is captured from. Tests pass a fake.
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
      home: JoinPage(hub: hub, mediaBackend: mediaBackend),
    );
  }
}

/// Which signaling transport the call uses.
enum SignalingChoice {
  /// [InMemorySignaling]: participants in this app only. With a broker URL,
  /// a real call (a single participant, plus simulated ones); without, a
  /// presence-only demo.
  inMemory('In-memory (this app)'),

  /// The dev server's WebSocket signaling and broker
  /// (`tools/dev-server/`): calls across devices.
  devServer('Dev server (multi-device)');

  const SignalingChoice(this.label);

  final String label;
}

/// Picks a signaling transport and joins a room.
class JoinPage extends StatefulWidget {
  const JoinPage({
    super.key,
    required this.hub,
    this.mediaBackend = const FlutterWebrtcMediaBackend(),
  });

  final InMemorySignalingHub hub;
  final MediaBackend mediaBackend;

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  static final DevServerConfig? _devDefaults =
      DevServerConfig.fromEnvironment();

  final _formKey = GlobalKey<FormState>();
  late SignalingChoice _choice = _devDefaults == null
      ? SignalingChoice.inMemory
      : SignalingChoice.devServer;
  final _roomController = TextEditingController(text: 'demo');

  // In-memory signaling.
  final _nameController = TextEditingController(text: 'me');
  final _brokerUrlController = TextEditingController();
  final _brokerTokenController = TextEditingController();

  // Dev server.
  late final _serverUrlController = TextEditingController(
    text: _devDefaults?.serverUrl.toString() ?? '',
  );
  late final _devTokenController = TextEditingController(
    text: _devDefaults?.token ?? '',
  );
  late final _userNameController = TextEditingController(
    text: _devDefaults?.userName ?? '',
  );

  bool _joining = false;
  String? _error;
  int _guestCount = 0;

  @override
  void dispose() {
    for (final c in [
      _roomController,
      _nameController,
      _brokerUrlController,
      _brokerTokenController,
      _serverUrlController,
      _devTokenController,
      _userNameController,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _join() async {
    if (_joining || !(_formKey.currentState?.validate() ?? false)) return;
    final roomId = _roomController.text.trim();
    setState(() {
      _joining = true;
      _error = null;
    });
    try {
      if (_choice == SignalingChoice.inMemory &&
          _brokerUrlController.text.trim().isEmpty) {
        await _joinPresenceOnly(roomId);
        return;
      }
      final setup = _choice == SignalingChoice.inMemory
          ? _inMemorySetup(roomId)
          : _devServerSetup();
      final Room room;
      try {
        room =
            await CloudflareRealtime(
              broker: setup.broker,
              mediaBackend: widget.mediaBackend,
              // Faster recovery when the network changes (docs/design.md §8).
              networkChanges: createNetworkChangeSource(),
            ).join(
              roomId,
              signaling: setup.signaling,
              participantId: setup.participantId,
              metadata: {'displayName': setup.displayName},
            );
      } catch (_) {
        await setup.disposeSignaling();
        rethrow;
      }
      if (!mounted) {
        await room.leave();
        await setup.disposeSignaling();
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CallPage(
            room: room,
            setup: setup,
            mediaBackend: widget.mediaBackend,
          ),
        ),
      );
    } on StateError catch (e) {
      setState(() => _error = e.message);
    } on Exception catch (e) {
      // Broker and session exceptions never contain SDP or tokens.
      setState(() => _error = 'Could not join: $e');
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }

  Future<void> _joinPresenceOnly(String roomId) async {
    final signaling = InMemorySignaling(widget.hub);
    try {
      await signaling.join(
        roomId,
        ParticipantState(
          participantId: _nameController.text.trim(),
          metadata: {'displayName': _nameController.text.trim()},
        ),
      );
    } catch (_) {
      await signaling.dispose();
      rethrow;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PresencePage(hub: widget.hub, signaling: signaling),
      ),
    );
  }

  CallSetup _inMemorySetup(String roomId) {
    final name = _nameController.text.trim();
    final token = _brokerTokenController.text.trim();
    final signaling = InMemorySignaling(widget.hub);
    final guests = <InMemorySignaling>[];
    return CallSetup(
      signaling: signaling,
      participantId: name,
      displayName: name,
      broker: BrokerConfig(
        baseUrl: Uri.parse(_brokerUrlController.text.trim()),
        headers: () async => {
          if (token.isNotEmpty) 'Authorization': 'Bearer $token',
        },
      ),
      disposeSignaling: () async {
        for (final guest in guests) {
          await guest.dispose();
        }
        await signaling.dispose();
      },
      // A presence-only guest: it has a (fake) session so it gets a tile,
      // and publishes nothing, so nobody tries to pull from it.
      addSimulatedParticipant: () async {
        final id = 'guest-${++_guestCount}';
        final guest = InMemorySignaling(widget.hub);
        guests.add(guest);
        await guest.join(
          roomId,
          ParticipantState(
            participantId: id,
            sessionId: 'simulated-session-$_guestCount',
            metadata: {'displayName': id},
          ),
        );
      },
    );
  }

  CallSetup _devServerSetup() {
    final dev = DevServerConfig.parse(
      serverUrl: _serverUrlController.text,
      token: _devTokenController.text,
      userName: _userNameController.text,
    );
    final signaling = dev.createSignaling(
      onError: (error) {
        if (!mounted) return;
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Signaling: $error')));
      },
    );
    return CallSetup(
      signaling: signaling,
      participantId: dev.newParticipantId(),
      displayName: dev.userName,
      broker: dev.brokerConfig(),
      disposeSignaling: signaling.dispose,
      signalingStatus: signaling.statusChanges.map(
        (WsSignalingStatus status) => status.name,
      ),
    );
  }

  void _openLocalMedia() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LocalMediaPage(backend: widget.mediaBackend),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Join a room'),
        actions: [
          IconButton(
            tooltip: 'Local media',
            icon: const Icon(Icons.perm_camera_mic),
            onPressed: _openLocalMedia,
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    DropdownButtonFormField<SignalingChoice>(
                      initialValue: _choice,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Signaling'),
                      items: [
                        for (final choice in SignalingChoice.values)
                          DropdownMenuItem(
                            value: choice,
                            child: Text(
                              choice.label,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (choice) => setState(() => _choice = choice!),
                    ),
                    TextFormField(
                      controller: _roomController,
                      decoration: const InputDecoration(labelText: 'Room ID'),
                      validator: (v) =>
                          (v ?? '').trim().isEmpty ? 'Enter a room ID' : null,
                    ),
                    ...switch (_choice) {
                      SignalingChoice.inMemory => _inMemoryFields(),
                      SignalingChoice.devServer => _devServerFields(),
                    },
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _joining ? null : _join,
                      child: Text(_joining ? 'Connecting…' : 'Join'),
                    ),
                    if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _inMemoryFields() => [
    TextFormField(
      controller: _nameController,
      decoration: const InputDecoration(labelText: 'Your name'),
      validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a name' : null,
    ),
    TextFormField(
      controller: _brokerUrlController,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'Broker URL (optional)',
        helperText: 'Without one, the demo shows presence only.',
      ),
    ),
    TextFormField(
      controller: _brokerTokenController,
      obscureText: true,
      decoration: const InputDecoration(
        labelText: 'Broker bearer token (optional)',
      ),
    ),
  ];

  List<Widget> _devServerFields() => [
    TextFormField(
      controller: _serverUrlController,
      keyboardType: TextInputType.url,
      decoration: const InputDecoration(
        labelText: 'Dev server URL',
        helperText: 'See tools/dev-server/README.md',
      ),
      validator: (v) => DevServerConfig.validateServerUrl(v ?? ''),
    ),
    TextFormField(
      controller: _devTokenController,
      obscureText: true,
      decoration: const InputDecoration(labelText: 'Dev token'),
      validator: (v) => DevServerConfig.validateToken(v ?? ''),
    ),
    TextFormField(
      controller: _userNameController,
      decoration: const InputDecoration(labelText: 'User name'),
      validator: (v) => DevServerConfig.validateUserName(v ?? ''),
    ),
  ];
}
