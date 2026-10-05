// ignore_for_file: avoid_print
// Counts and times the video renderer's platform calls during a call, per
// user action: microphone and camera mute toggles, gallery/stage layout
// switches, and unpublishing and republishing the camera (docs/design.md
// §4.3, Rendering; on macOS each `videoRendererSetSrcObject` runs on the
// main thread, which is the UI thread, doc/macos.md).
//
// Two rooms in one process share in-memory signaling. Alice publishes a
// camera and a microphone; the page shows Alice's self-view and Bob's view
// of Alice's camera, in tiles laid out like the example's call page (a
// gallery, or a stage with thumbnails), switched with each tile keeping a
// GlobalKey (as the example's do) and then without keys (Flutter re-creates
// the views). Every renderer operation is logged with the action that
// caused it, and every flutter_webrtc call is timed with the package's
// platform call timing (support/call_timing.dart), with the event loop's
// gaps over 250 ms. A summary line per action ends the log.
//
// Desktop only; from the environment:
//
//   CF_REALTIME_TIMING_CAMERA  the camera's label (default: the first whose
//                              label contains "FaceTime")
//   CF_REALTIME_TIMING_MIC     the microphone's label (default: the system
//                              default, without listing the devices)
//
// Skipped unless CF_REALTIME_BROKER_URL is set (broker_settings.dart).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';
import 'support/call_timing.dart';

final _microphoneLabel = Platform.environment['CF_REALTIME_TIMING_MIC'] ?? '';
final _cameraLabel = Platform.environment['CF_REALTIME_TIMING_CAMERA'] ?? '';
const _timeout = Duration(seconds: 60);

/// How long each step waits for the renderer work it caused to finish.
const _settle = Duration(seconds: 3);

late CallTiming _timing;
String _action = 'setup';

// print, not debugPrint: debugPrint is throttled, and the app may end
// before it has written everything.
void _log(String message) =>
    print('[renderer-timing +${_timing.now.inMilliseconds} ms] $message');

/// The renderer operations of one action.
final List<String> _ops = [];

/// Wraps the real renderer and logs each operation with [_action].
class _LoggingRenderer implements VideoRenderer {
  _LoggingRenderer(this._inner) : _id = ++_count;

  static int _count = 0;
  final VideoRenderer _inner;
  final int _id;

  Future<void> _timed(String op, Future<void> Function() body) async {
    final watch = Stopwatch()..start();
    try {
      await body();
    } finally {
      final line =
          'renderer #$_id $op: ${watch.elapsedMilliseconds} ms ($_action)';
      _ops.add(line);
      _log(line);
    }
  }

  @override
  Future<void> initialize() => _timed('initialize', _inner.initialize);

  @override
  Future<void> setStream(MediaStream? stream) => _timed(
    stream == null ? 'setStream(null)' : 'setStream(stream)',
    () => _inner.setStream(stream),
  );

  @override
  Widget build(
    BuildContext context, {
    required VideoViewFit fit,
    required bool mirror,
    required FilterQuality filterQuality,
  }) => _inner.build(
    context,
    fit: fit,
    mirror: mirror,
    filterQuality: filterQuality,
  );

  @override
  Future<void> dispose() => _timed('dispose', _inner.dispose);
}

/// What the page shows: Alice's camera as she sees it and as Bob sees it.
class _CallState extends ChangeNotifier {
  LocalMediaPublication? camera;
  RemoteTrackPublication? remoteCamera;
  bool stage = false;

  /// Whether the tiles keep a GlobalKey (as the example's do). Without
  /// one, Flutter re-creates a tile's view when the layout changes.
  bool keyed = true;

  void update({
    LocalMediaPublication? camera,
    RemoteTrackPublication? remoteCamera,
    bool? stage,
    bool? keyed,
  }) {
    this.camera = camera;
    this.remoteCamera = remoteCamera;
    if (stage != null) this.stage = stage;
    if (keyed != null) this.keyed = keyed;
    notifyListeners();
  }
}

/// Tiles laid out like the example's call page: a gallery, or one big tile
/// with a strip of thumbnails; each tile keeps its GlobalKey, so a layout
/// change moves it instead of re-creating it.
class _CallPage extends StatefulWidget {
  const _CallPage(this.state);

  final _CallState state;

  @override
  State<_CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<_CallPage> {
  final _keys = {'local': GlobalKey(), 'remote': GlobalKey()};

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final state = widget.state;
          final camera = state.camera;
          final remote = state.remoteCamera;
          final tiles = [
            _tile(
              'local',
              camera == null
                  ? null
                  : ParticipantVideoView.local(camera.mediaSource),
            ),
            _tile(
              'remote',
              remote == null ? null : ParticipantVideoView.remote(remote),
            ),
          ];
          if (!state.stage) {
            return GridView.extent(
              maxCrossAxisExtent: 480,
              childAspectRatio: 16 / 9,
              children: tiles,
            );
          }
          return Column(
            children: [
              Expanded(child: tiles[1]),
              SizedBox(
                height: 112,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [AspectRatio(aspectRatio: 16 / 9, child: tiles[0])],
                ),
              ),
            ],
          );
        },
      ),
    ),
  );

  Widget _tile(String id, Widget? video) => KeyedSubtree(
    key: widget.state.keyed ? _keys[id] : null,
    child: ColoredBox(
      color: const Color(0xFF303030),
      child: video ?? Center(child: Text(id)),
    ),
  );
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
  final settings = BrokerSettings.read();

  testWidgets(
    'counts and times the renderer calls per action',
    (tester) async {
      _timing = CallTiming.start();
      final previousFactory = ParticipantVideoView.defaultRendererFactory;
      ParticipantVideoView.defaultRendererFactory = () =>
          _LoggingRenderer(FlutterWebrtcVideoRenderer());
      addTearDown(
        () => ParticipantVideoView.defaultRendererFactory = previousFactory,
      );

      final cameras =
          (await const FlutterWebrtcMediaBackend().enumerateDevices())
              .where((d) => d.kind == MediaDeviceKind.videoInput)
              .toList();
      final device = cameras.firstWhere(
        (d) => _cameraLabel.isNotEmpty
            ? d.label == _cameraLabel
            : d.label.contains('FaceTime'),
      );
      _log('camera "${device.label}"');

      final realtime = CloudflareRealtime(broker: settings.brokerOptions());
      final hub = InMemorySignalingHub();
      const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'render-alice-$suffix',
        options: options,
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'render-bob-$suffix',
        options: options,
      );
      addTearDown(bob.leave);

      final state = _CallState();
      RemoteTrackPublication? remoteCamera() {
        for (final p in bob.participants) {
          if (p.participantId == alice.localParticipant.participantId) {
            return p.camera;
          }
        }
        return null;
      }

      void refresh() => state.update(
        camera: alice.localParticipant.camera,
        remoteCamera: remoteCamera(),
      );
      final subscriptions = [
        bob.participantsChanges.listen((_) => refresh()),
        bob.events.listen((e) {
          if (e is! ParticipantConnectionQualityChangedEvent) {
            _log('bob: ${_describeEvent(e)}');
          }
          refresh();
        }),
        alice.events.listen((e) {
          if (e is! ParticipantConnectionQualityChangedEvent) {
            _log('alice: ${_describeEvent(e)}');
          }
          refresh();
        }),
      ];
      addTearDown(() async {
        for (final s in subscriptions) {
          await s.cancel();
        }
      });
      await tester.pumpWidget(_CallPage(state));
      // Until the call runs: both sessions' states and Alice's sent video.
      var settingUp = true;
      unawaited(() async {
        while (settingUp) {
          await Future<void>.delayed(const Duration(seconds: 3));
          if (!settingUp) break;
          final sent = <String>[];
          try {
            for (final r in await alice.session.getStats()) {
              if (r.type == 'outbound-rtp' && r.values['kind'] == 'video') {
                sent.add(
                  '${r.values['rid']}:${r.values['bytesSent']}B '
                  '${r.values['frameWidth']}x${r.values['frameHeight']} '
                  '${r.values['qualityLimitationReason']}',
                );
              }
            }
          } catch (e) {
            sent.add('stats failed: $e');
          }
          _log(
            'alice ${alice.session.connectionState.name}, '
            'bob ${bob.session.connectionState.name}; alice sends $sent',
          );
        }
      }());
      addTearDown(() => settingUp = false);

      var camera = await alice.localParticipant.publishCamera(
        device: device,
        options: const CameraOptions(preset: VideoPreset.h360),
      );
      refresh();
      await camera.publication.whenSending().timeout(_timeout);
      await _until(
        () => remoteCamera()?.track != null,
        'Bob never received Alice\'s camera',
      );
      refresh();
      _log('camera sending and pulled');
      // The microphone once the camera is sending: its first publish starts
      // Apple's voice processing, which can take a minute or more on a
      // loaded Mac (doc/macos.md, The first call is slow).
      final microphone = await alice.localParticipant.publishMicrophone(
        device: _microphoneLabel.isEmpty
            ? null
            : (await const FlutterWebrtcMediaBackend().enumerateDevices())
                  .firstWhere(
                    (d) =>
                        d.kind == MediaDeviceKind.audioInput &&
                        d.label == _microphoneLabel,
                  ),
      );
      _log(
        'microphone '
        '"${_microphoneLabel.isEmpty ? 'default' : _microphoneLabel}"',
      );
      try {
        await microphone.publication.whenSending().timeout(_timeout);
        _log('microphone sending');
      } on TimeoutException {
        // Apple's voice processing can take minutes to start on a loaded
        // Mac; the steps below don't need the audio to flow.
        _log('microphone not sending yet; going on');
      }
      await Future<void>.delayed(_settle);

      settingUp = false;
      final summaries = <String>[];
      Future<void> step(String action, Future<void> Function() body) async {
        _action = action;
        _ops.clear();
        final from = _timing.now;
        _log('>> $action');
        await body();
        await Future<void>.delayed(_settle);
        final to = _timing.now;
        final calls = _timing.calls.where(
          (c) =>
              c.channel == flutterWebrtcMethodChannel &&
              c.sentAt >= from &&
              c.sentAt < to,
        );
        final perMethod = <String, List<int>>{};
        for (final c in calls) {
          (perMethod[c.method] ??= []).add(c.duration!.inMilliseconds);
        }
        String describe(String method) {
          final ms = perMethod[method];
          return ms == null ? '$method 0' : '$method ${ms.length} $ms ms';
        }

        final summary =
            '$action: ${describe('videoRendererSetSrcObject')}; '
            '${describe('createVideoRenderer')}; '
            '${describe('videoRendererDispose')}; '
            '${describe('streamDispose')}; '
            'renderer ops ${_ops.length}; '
            'longest gap ${_timing.longestGap(from: from).inMilliseconds} ms';
        summaries.add(summary);
        _log('<< $summary');
        final slow = calls.where((c) => c.duration!.inMilliseconds >= 100);
        if (slow.isNotEmpty) _log('   slow calls: ${slow.toList()}');
        _timing.describeGaps(from: from).forEach((g) => _log('   $g'));
      }

      await step('idle', () async {});
      for (var i = 1; i <= 3; i++) {
        await step('microphone mute $i', microphone.mute);
        await step('microphone unmute $i', microphone.unmute);
      }
      for (var i = 1; i <= 3; i++) {
        await step('camera mute $i', camera.mute);
        await step('camera unmute $i', camera.unmute);
      }
      for (final keyed in [true, false]) {
        final how = keyed ? 'keyed' : 'no keys';
        for (var i = 1; i <= 3; i++) {
          await step(
            'to stage ($how) $i',
            () async => state.update(
              camera: state.camera,
              remoteCamera: state.remoteCamera,
              stage: true,
              keyed: keyed,
            ),
          );
          await step(
            'to gallery ($how) $i',
            () async => state.update(
              camera: state.camera,
              remoteCamera: state.remoteCamera,
              stage: false,
              keyed: keyed,
            ),
          );
        }
      }
      for (var i = 1; i <= 2; i++) {
        await step('camera unpublish $i', () async {
          await camera.unpublish();
          refresh();
        });
        await step('camera republish $i', () async {
          camera = await alice.localParticipant.publishCamera(
            device: device,
            options: const CameraOptions(preset: VideoPreset.h360),
          );
          refresh();
          await camera.publication.whenSending().timeout(_timeout);
          await _until(
            () => remoteCamera()?.track != null,
            'Bob never received Alice\'s camera again',
          );
          refresh();
        });
      }

      _action = 'teardown';
      _log('summary:');
      summaries.forEach(_log);
      final setSrcObject = _timing.calls
          .where((c) => c.method == 'videoRendererSetSrcObject')
          .map((c) => c.duration!.inMilliseconds)
          .toList();
      _log('every videoRendererSetSrcObject (ms): $setSrcObject');
      await tester.pumpWidget(const SizedBox());
      await Future<void>.delayed(_settle);
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

Future<void> _until(bool Function() test, String failure) async {
  final deadline = DateTime.now().add(_timeout);
  while (!test()) {
    if (DateTime.now().isAfter(deadline)) fail(failure);
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

String _describeEvent(RoomEvent e) => switch (e) {
  TrackSubscriptionFailedEvent(:final error) =>
    'TrackSubscriptionFailedEvent: $error',
  RoomErrorEvent(:final error) => 'RoomErrorEvent: $error',
  RoomConnectionStateChangedEvent(:final state) =>
    'RoomConnectionStateChangedEvent: ${state.name}',
  RoomSessionFailedEvent(:final failure) => 'RoomSessionFailedEvent: $failure',
  _ => '${e.runtimeType}',
};
