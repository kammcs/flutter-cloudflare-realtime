import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import '../support/room_harness.dart';

/// Records what the view asks of its renderer.
class _FakeRenderer implements VideoRenderer {
  _FakeRenderer(this.log);

  final List<String> log;
  MediaStream? stream;

  @override
  Future<void> initialize() async => log.add('initialize');

  @override
  Future<void> setStream(MediaStream? stream) async {
    this.stream = stream;
    log.add('setStream(${stream?.id})');
  }

  @override
  Widget build(
    BuildContext context, {
    required VideoViewFit fit,
    required bool mirror,
    required FilterQuality filterQuality,
  }) => Text(
    'video ${stream?.id} ${fit.name}${mirror ? ' mirrored' : ''}',
    textDirection: TextDirection.ltr,
  );

  @override
  Future<void> dispose() async => log.add('dispose');
}

class _RecordingReporter implements LayerDemandReporter {
  final List<(String, TileDemand)> reports = [];
  final List<String> removed = [];

  @override
  void reportDemand(String subscriptionId, Object viewKey, TileDemand demand) =>
      reports.add((subscriptionId, demand));

  @override
  void removeView(String subscriptionId, Object viewKey) =>
      removed.add(subscriptionId);
}

/// Lets both kinds of pending work run: fake-zone timers and microtasks
/// (created by the widget), and root-zone microtasks (completed futures
/// such as a subscription's `cancel()`), which only the real event loop
/// runs.
Future<void> _step(WidgetTester tester) async {
  // With a duration, pump also fires due timers (the session batches
  // requests with zero-length timers).
  await tester.pump(const Duration(milliseconds: 1));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
}

/// Steps until [future] completes.
Future<T> _drive<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  late T value;
  Object? error;
  future.then(
    (v) {
      value = v;
      done = true;
    },
    onError: (Object e) {
      error = e;
      done = true;
    },
  );
  for (var i = 0; i < 100 && !done; i++) {
    await _step(tester);
  }
  if (!done) fail('the future did not complete');
  if (error != null) throw error!;
  return value;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await _step(tester);
  }
}

Widget _frame(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 320, height: 180, child: child)),
);

const _cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);

void main() {
  final log = <String>[];
  VideoRenderer factory() => _FakeRenderer(log);

  setUp(log.clear);

  group('local', () {
    testWidgets('renders the capture while there is one, mirrored', (
      tester,
    ) async {
      final camera = CameraSource(backend: FakeMediaBackend(devices: [cam1]));
      await tester.pumpWidget(
        _frame(ParticipantVideoView.local(camera, rendererFactory: factory)),
      );
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);
      expect(log, isEmpty, reason: 'no renderer until there is video');

      await _drive(tester, camera.enable());
      await _settle(tester);
      final stream = camera.currentTrack!.stream;
      expect(log, ['initialize', 'setStream(${stream.id})']);
      expect(find.text('video ${stream.id} cover mirrored'), findsOneWidget);

      await _drive(tester, camera.disable());
      await _settle(tester);
      expect(log.last, 'setStream(null)');
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      expect(log.last, 'dispose');
      await _drive(tester, camera.dispose());
    });

    testWidgets('mirror and fit can be set; defaultRendererFactory is used', (
      tester,
    ) async {
      final previous = ParticipantVideoView.defaultRendererFactory;
      ParticipantVideoView.defaultRendererFactory = factory;
      addTearDown(() => ParticipantVideoView.defaultRendererFactory = previous);

      final camera = CameraSource(backend: FakeMediaBackend(devices: [cam1]));
      await _drive(tester, camera.enable());
      await tester.pumpWidget(
        _frame(
          ParticipantVideoView.local(
            camera,
            mirror: false,
            fit: VideoViewFit.contain,
            placeholder: const Text('off', textDirection: TextDirection.ltr),
          ),
        ),
      );
      await _settle(tester);
      final stream = camera.currentTrack!.stream;
      expect(find.text('video ${stream.id} contain'), findsOneWidget);

      await _drive(tester, camera.disable());
      await _settle(tester);
      expect(find.text('off'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await _drive(tester, camera.dispose());
    });
  });

  group('remote', () {
    late RoomHarness h;
    late Room bob;
    late InMemorySignaling ann;

    Future<RemoteTrackPublication> setUpRoom(WidgetTester tester) async {
      h = RoomHarness();
      bob = await _drive(tester, h.join('bob'));
      ann = InMemorySignaling(h.hub);
      h.broker.trackKinds['ann-1/c'] = 'video';
      await _drive(
        tester,
        ann.join(
          'room',
          ParticipantState(
            participantId: 'ann',
            sessionId: 'ann-1',
            tracks: const {'c': _cam},
          ),
        ),
      );
      await _settle(tester);
      return bob.participant('ann')!.camera!;
    }

    Future<void> tearDownRoom(WidgetTester tester) async {
      await _drive(tester, bob.leave());
      await _drive(tester, ann.dispose());
    }

    testWidgets('subscribes while mounted and unsubscribes on unmount', (
      tester,
    ) async {
      final cam = await setUpRoom(tester);
      expect(cam.isSubscribed, isFalse);
      final reporter = _RecordingReporter();

      await tester.pumpWidget(
        _frame(
          ParticipantVideoView.remote(
            cam,
            rendererFactory: factory,
            layerReporter: reporter,
          ),
        ),
      );
      expect(cam.isSubscribed, isTrue);
      await _settle(tester);
      expect(h.pullsOf(bob), ['ann-1/c']);
      final stream = cam.currentTrack!.stream;
      expect(log, ['initialize', 'setStream(${stream.id})']);
      expect(find.text('video ${stream.id} cover'), findsOneWidget);

      // The size hook reports under the publication's stable ID.
      expect(reporter.reports, isNotEmpty);
      expect(reporter.reports.last.$1, 'ann/c');
      expect(reporter.reports.last.$2.visible, isTrue);
      expect(reporter.reports.last.$2.width, greaterThan(0));

      // Muted by the publisher: the placeholder shows, the pull stays.
      await _drive(
        tester,
        ann.update(
          ParticipantState(
            participantId: 'ann',
            sessionId: 'ann-1',
            tracks: {'c': _cam.copyWith(muted: true)},
          ),
        ),
      );
      await _settle(tester);
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);
      expect(cam.isSubscribed, isTrue);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      expect(cam.isSubscribed, isFalse);
      expect(h.closesOf(bob), hasLength(1));
      expect(log.last, 'dispose');
      expect(reporter.removed, ['ann/c']);
      await tearDownRoom(tester);
    });

    testWidgets('two views share one pull', (tester) async {
      final cam = await setUpRoom(tester);
      Widget both({required bool second}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            SizedBox(
              height: 100,
              child: ParticipantVideoView.remote(cam, rendererFactory: factory),
            ),
            if (second)
              SizedBox(
                height: 100,
                child: ParticipantVideoView.remote(
                  cam,
                  rendererFactory: factory,
                ),
              ),
          ],
        ),
      );
      await tester.pumpWidget(both(second: true));
      await _settle(tester);
      expect(h.pullsOf(bob), hasLength(1));

      await tester.pumpWidget(both(second: false));
      await _settle(tester);
      expect(cam.isSubscribed, isTrue);
      expect(h.closesOf(bob), isEmpty);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      expect(cam.isSubscribed, isFalse);
      await tearDownRoom(tester);
    });

    testWidgets('with subscribe: false it only shows what others pull', (
      tester,
    ) async {
      final cam = await setUpRoom(tester);
      await tester.pumpWidget(
        _frame(
          ParticipantVideoView.remote(
            cam,
            subscribe: false,
            rendererFactory: factory,
          ),
        ),
      );
      await _settle(tester);
      expect(cam.isSubscribed, isFalse);
      expect(h.pullsOf(bob), isEmpty);
      expect(find.byIcon(Icons.videocam_off), findsOneWidget);

      await _drive(tester, cam.subscribe());
      await _settle(tester);
      expect(
        find.text('video ${cam.currentTrack!.stream.id} cover'),
        findsOneWidget,
      );

      // Turning subscribe on and off follows the widget.
      await tester.pumpWidget(
        _frame(ParticipantVideoView.remote(cam, rendererFactory: factory)),
      );
      await _drive(tester, cam.unsubscribe());
      expect(cam.isSubscribed, isTrue, reason: 'the view holds it now');
      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      expect(cam.isSubscribed, isFalse);
      await tearDownRoom(tester);
    });
  });
}
