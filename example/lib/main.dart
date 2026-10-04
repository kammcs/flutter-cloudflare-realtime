import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/material.dart';

import 'audio_routes_sheet.dart';
import 'call_diagnostics.dart';
import 'call_page.dart';
import 'dev_config.dart';
import 'local_media_page.dart';
import 'network_changes.dart';
import 'presence_page.dart';
import 'sample_caller_image.dart';
import 'system_call_demo.dart';
import 'ws_signaling.dart';

/// Whether to time `flutter_webrtc`'s platform calls and the event loop's
/// gaps, from `--dart-define=CF_REALTIME_CALL_TIMING=true`: a debug aid
/// that prints each gap over 250 ms with the calls behind it, and each call
/// slower than 100 ms (`CloudflareRealtime.debugPlatformCallTiming`).
const callTiming = bool.fromEnvironment('CF_REALTIME_CALL_TIMING');

void main() {
  if (callTiming) {
    // Before any other binding, so that its messenger times the calls.
    PlatformCallTimingBinding.ensureInitialized();
    CloudflareRealtime.debugPlatformCallTiming =
        const PlatformCallTimingOptions();
  }
  runApp(ExampleApp(hub: InMemorySignalingHub()));
}

/// The video codec every participant sends, from `--dart-define=VIDEO_CODEC`:
/// a MIME type (default `video/VP8`), or `default` for the platform's own
/// order, which overrides the package default (VP8 everywhere).
///
/// The SFU forwards video as it was sent, so in a mixed call every device
/// decodes what every other device encodes. VP8 everywhere keeps Windows
/// away from H.264 (flutter-webrtc #982) whichever side encodes it, and is
/// libwebrtc's most exercised simulcast path (docs/checkpoint.md).
const videoCodec = String.fromEnvironment(
  'VIDEO_CODEC',
  defaultValue: 'video/VP8',
);

/// The room options the example joins with.
const roomOptions = RoomOptions(
  sessionOptions: SfuSessionOptions(
    defaults: SfuSessionDefaults(
      videoCodecPreferences: videoCodec == 'default' ? null : [videoCodec],
    ),
  ),
);

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

  /// Joins as an outgoing system call (CallKit, Android Telecom): the call
  /// shows in the system's UI and the lock screen (docs/design.md §4.8).
  bool _asSystemCall = false;
  int _guestCount = 0;

  /// Simulated incoming calls so far: every second one has a picture.
  int _simulatedCalls = 0;

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

  /// Joins the room. With [incoming] (an answered system call) or "Start
  /// as system call", the room follows a system call: it leaves when the
  /// call ends (the lock screen's End), and the system's mute is the
  /// microphone's.
  Future<void> _join({SystemCall? incoming}) async {
    if (_joining || !(_formKey.currentState?.validate() ?? false)) {
      await incoming?.end(SystemCallEndReason.failed);
      return;
    }
    final roomId = _roomController.text.trim();
    setState(() {
      _joining = true;
      _error = null;
    });
    var call = incoming;
    // iOS: a call answered from the lock screen joins with the app in the
    // background; this keeps it running until the microphone is published
    // (the call's audio keeps it running from then on).
    final endBackgroundTask = incoming == null
        ? null
        : await beginBackgroundTask('join answered call');
    try {
      if (_choice == SignalingChoice.inMemory &&
          _brokerUrlController.text.trim().isEmpty) {
        await call?.end(SystemCallEndReason.failed);
        await _joinPresenceOnly(roomId);
        return;
      }
      // One source for the room and the dev-server signaling, so both react
      // to the same change (and each change is logged once).
      final networkChanges = createNetworkChangeSource();
      final setup = _choice == SignalingChoice.inMemory
          ? _inMemorySetup(roomId)
          : _devServerSetup(networkChanges);
      if (call == null && _asSystemCall) {
        if (!await prepareSystemCalls()) {
          _showSnack('System calls are not supported here: a plain call.');
        }
        call = await SystemCalls.instance.startOutgoingCall(
          handle: CallHandle(roomId),
          displayName: 'Room $roomId',
        );
        await call.reportConnecting();
      }
      final Room room;
      try {
        // Android 12+: Bluetooth headsets are audio routes only with this.
        await requestBluetoothPermission();
        room =
            await CloudflareRealtime(
              broker: setup.broker,
              mediaBackend: widget.mediaBackend,
              // Faster recovery when the network changes (docs/design.md §8).
              networkChanges: networkChanges,
            ).join(
              roomId,
              signaling: setup.signaling,
              participantId: setup.participantId,
              metadata: {'displayName': setup.displayName},
              options: roomOptions,
            );
      } catch (_) {
        await setup.disposeSignaling();
        rethrow;
      }
      if (call != null && call.isOutgoing && !call.isEnded) {
        // The room is the other side here: it "answered".
        await call.reportConnected();
      }
      if (call != null) await _followSystemCall(room, call);
      await endBackgroundTask?.call();
      if (!mounted) {
        await room.leave();
        await setup.disposeSignaling();
        await call?.end(SystemCallEndReason.failed);
        return;
      }
      final systemCall = call;
      call = null;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CallPage(
            room: room,
            setup: setup,
            mediaBackend: widget.mediaBackend,
            systemCall: systemCall,
          ),
        ),
      );
    } on StateError catch (e) {
      setState(() => _error = e.message);
    } on Exception catch (e) {
      // Broker and session exceptions never contain SDP or tokens.
      setState(() => _error = 'Could not join: $e');
    } finally {
      // A system call whose room never opened.
      await call?.end(SystemCallEndReason.failed);
      await endBackgroundTask?.call();
      if (mounted) setState(() => _joining = false);
    }
  }

  /// Ties [room] to [call] and publishes the microphone before the call
  /// page opens. Answered from a locked iPhone's lock screen, the app stays
  /// in the background, where Flutter builds no widgets until it comes back:
  /// the page (which publishes the camera, and the microphone if it isn't
  /// yet) is only built then, but the call has its audio, and follows the
  /// system's mute and End, at once.
  Future<void> _followSystemCall(Room room, SystemCall call) async {
    if (call.isEnded || room.hasLeft) return; // The page leaves at once.
    room.attachSystemCall(call);
    try {
      await room.localParticipant.publishMicrophone();
    } on Exception catch (e) {
      // The page tries again.
      logDiagnostic('systemCall', 'could not publish the microphone: $e');
    } on StateError {
      // The call ended meanwhile, and the room left with it.
    }
  }

  /// Reports an incoming system call in 5 s (time to lock the phone or
  /// leave the app, to see the full-screen ring), as an app's signaling or
  /// push would; answering it, here or in the system's UI, joins the room.
  /// Every second call carries a caller picture (Android's ring screen and
  /// notification show it); the others show the caller's monogram.
  Future<void> _simulateIncomingCall() async {
    if (_joining || !(_formKey.currentState?.validate() ?? false)) return;
    final roomId = _roomController.text.trim();
    if (!await prepareSystemCalls()) {
      _showSnack('System calls are not supported here: in-app only.');
    }
    _showSnack('An incoming call rings in 5 s.');
    // iOS suspends the app soon after the phone locks, so this delay would
    // only end once it's unlocked: a background task keeps it running until
    // the call is reported. (A real app is woken by a VoIP push, reported
    // natively: docs/design.md §4.8.) Android keeps the app running.
    final endBackgroundTask = await beginBackgroundTask('incoming call');
    final SystemCall call;
    try {
      final picture = (++_simulatedCalls).isEven
          ? await sampleCallerImage()
          : null;
      await Future<void>.delayed(const Duration(seconds: 5));
      call = await SystemCalls.instance.reportIncomingCall(
        handle: const CallHandle('demo-caller'),
        displayName: 'Demo caller',
        payload: {'room': roomId},
        callerImage: picture,
      );
    } on Exception catch (e) {
      _showSnack('Could not report the call: $e');
      return;
    } finally {
      // From here CallKit wakes the app for Answer or Decline.
      await endBackgroundTask();
    }
    if (!mounted) {
      await call.end();
      return;
    }
    if (await showIncomingCall(context, call)) {
      await _join(incoming: call);
    } else {
      // Declined (or ended) before it was answered: no room.
      final reason = call.endReason?.name ?? 'ended';
      logDiagnostic('systemCall', 'the incoming call ended: $reason');
      _showSnack('The incoming call ended ($reason).');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
      broker: BrokerOptions(
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

  CallSetup _devServerSetup(NetworkChangeSource? networkChanges) {
    final dev = DevServerConfig.parse(
      serverUrl: _serverUrlController.text,
      token: _devTokenController.text,
      userName: _userNameController.text,
    );
    final signaling = dev.createSignaling(
      networkChanges: networkChanges?.changes,
      // A timeline next to the room's [reconnect] lines.
      log: (message) => logDiagnostic('signaling', message),
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
      broker: dev.brokerOptions(),
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
                    if (systemCallsAvailable)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Start as system call'),
                        subtitle: const Text(
                          'In the phone\'s call UI and on the lock screen',
                        ),
                        value: _asSystemCall,
                        onChanged: (on) => setState(() => _asSystemCall = on),
                      ),
                    const SizedBox(height: 8),
                    FilledButton(
                      onPressed: _joining ? null : _join,
                      child: Text(_joining ? 'Connecting…' : 'Join'),
                    ),
                    if (systemCallsAvailable)
                      Tooltip(
                        message:
                            'Rings in 5 s: lock the phone meanwhile to see '
                            'the lock-screen ring',
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.ring_volume),
                          label: const Text('Simulate incoming call'),
                          onPressed: _joining ? null : _simulateIncomingCall,
                        ),
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
