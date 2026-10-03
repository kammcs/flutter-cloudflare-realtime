import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart' show RenderFittedBox;
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
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

/// Renders as [FlutterWebrtcVideoRenderer] does, with flutter_webrtc's own
/// RTCVideoView, for a frame of [width]×[height] as the native side reports
/// it. Nothing is initialized, so no texture is drawn, but the view lays
/// out as it does with real video.
class _FrameRenderer implements VideoRenderer {
  _FrameRenderer(double width, double height) {
    _renderer.value = rtc.RTCVideoValue(width: width, height: height);
  }

  final rtc.RTCVideoRenderer _renderer = rtc.RTCVideoRenderer();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setStream(MediaStream? stream) async {}

  @override
  Widget build(
    BuildContext context, {
    required VideoViewFit fit,
    required bool mirror,
    required FilterQuality filterQuality,
  }) => rtc.RTCVideoView(
    _renderer,
    mirror: mirror,
    filterQuality: filterQuality,
    objectFit: switch (fit) {
      VideoViewFit.contain =>
        rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      VideoViewFit.cover =>
        rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    },
  );

  @override
  Future<void> dispose() => _renderer.dispose();
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

/// Waits out `RoomOptions.leaseReleaseGrace` (500 ms by default), after
/// which an unmounted view's lease is released.
Future<void> _afterGrace(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 600));
  await _settle(tester);
}

Widget _frame(Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: Center(child: SizedBox(width: 320, height: 180, child: child)),
);

const _cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);

Matcher _near(Offset expected) => predicate<Offset>(
  (o) => (o - expected).distance < 0.5,
  'within 0.5 of $expected',
);

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

    testWidgets('a back camera is not mirrored; switching follows', (
      tester,
    ) async {
      const back = MediaDevice(
        deviceId: '0',
        kind: MediaDeviceKind.videoInput,
        label: 'Camera 0, Facing back',
        facing: CameraFacing.environment,
      );
      const front = MediaDevice(
        deviceId: '1',
        kind: MediaDeviceKind.videoInput,
        label: 'Camera 1, Facing front',
        facing: CameraFacing.user,
      );
      final camera = CameraSource(
        backend: FakeMediaBackend(
          platform: MediaPlatform.android,
          devices: [back, front],
        ),
      );
      await tester.pumpWidget(
        _frame(ParticipantVideoView.local(camera, rendererFactory: factory)),
      );
      await _drive(tester, camera.enable());
      await _settle(tester);
      var stream = camera.currentTrack!.stream;
      expect(find.text('video ${stream.id} cover mirrored'), findsOneWidget);

      await _drive(tester, camera.switchCamera());
      await _settle(tester);
      stream = camera.currentTrack!.stream;
      expect(camera.currentTrack!.device, back);
      expect(find.text('video ${stream.id} cover'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await _settle(tester);
      await _drive(tester, camera.dispose());
    });

    testWidgets(
      'binds the renderer once: rebuilds never set the stream again',
      (tester) async {
        final camera = CameraSource(backend: FakeMediaBackend(devices: [cam1]));
        await _drive(tester, camera.enable());
        final stream = camera.currentTrack!.stream;

        // A parent that rebuilds for unrelated reasons (speaking highlights,
        // stats, audio levels), each time with a new view widget for the
        // same source, and new settings.
        Widget build(int n) => _frame(
          Opacity(
            opacity: n.isEven ? 1 : 0.9,
            child: ParticipantVideoView.local(
              camera,
              fit: n.isEven ? VideoViewFit.cover : VideoViewFit.contain,
              mirror: n.isEven,
              rendererFactory: () => _FakeRenderer(log),
            ),
          ),
        );
        for (var n = 0; n < 10; n++) {
          await tester.pumpWidget(build(n));
          await _step(tester);
        }
        await _settle(tester);
        expect(log, ['initialize', 'setStream(${stream.id})']);
        expect(find.text('video ${stream.id} contain'), findsOneWidget);

        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        expect(log.last, 'dispose');
        await _drive(tester, camera.dispose());
      },
    );

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

  group('fit', () {
    // A 16:9 cell at an offset, as in a gallery, and the extreme frames
    // seen in calls: a phone's portrait screen and a desktop's.
    const cell = Rect.fromLTWH(100, 50, 480, 270);
    Widget inCell(Widget view) => Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: [Positioned.fromRect(rect: cell, child: view)],
      ),
    );

    for (final (name, frame) in [
      ('portrait 1080×2424', const Size(1080, 2424)),
      ('landscape 1920×1080', const Size(1920, 1080)),
      ('ultra-wide 3440×1440', const Size(3440, 1440)),
    ]) {
      testWidgets('a $name frame letterboxes inside the view with contain, '
          'and is clipped to it with cover', (tester) async {
        final camera = CameraSource(backend: FakeMediaBackend(devices: [cam1]));
        await _drive(tester, camera.enable());
        for (final fit in VideoViewFit.values) {
          await tester.pumpWidget(
            inCell(
              ParticipantVideoView.local(
                camera,
                fit: fit,
                mirror: false,
                rendererFactory: () =>
                    _FrameRenderer(frame.width, frame.height),
              ),
            ),
          );
          await _settle(tester);
          expect(tester.getRect(find.byType(ParticipantVideoView)), cell);
          final picture = tester.getRect(
            find.descendant(
              of: find.byType(rtc.RTCVideoView),
              matching: find.byType(Transform),
            ),
          );
          expect(
            picture.width / picture.height,
            moreOrLessEquals(frame.width / frame.height, epsilon: 0.01),
            reason: '$fit keeps the aspect ratio',
          );
          expect(picture.center, _near(cell.center), reason: '$fit centers');
          final fitted = tester.renderObject<RenderFittedBox>(
            find.byType(FittedBox),
          );
          switch (fit) {
            case VideoViewFit.contain:
              // Within the cell, touching two opposite sides.
              expect(cell.inflate(0.5).contains(picture.topLeft), isTrue);
              expect(cell.inflate(0.5).contains(picture.bottomRight), isTrue);
              expect(
                (picture.width - cell.width).abs() < 0.5 ||
                    (picture.height - cell.height).abs() < 0.5,
                isTrue,
              );
            case VideoViewFit.cover:
              // Covers the cell; the overflow is clipped at the view.
              expect(picture.inflate(0.5).contains(cell.topLeft), isTrue);
              expect(picture.inflate(0.5).contains(cell.bottomRight), isTrue);
              expect(fitted.size, cell.size);
              expect(fitted.clipBehavior, isNot(Clip.none));
          }
        }
        await tester.pumpWidget(const SizedBox());
        await _settle(tester);
        await _drive(tester, camera.dispose());
      });
    }
  });

  group('remote', () {
    late RoomHarness h;
    late Room bob;
    late InMemorySignaling ann;

    Future<RemoteTrackPublication> setUpRoom(
      WidgetTester tester, {
      TrackInfo info = _cam,
    }) async {
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
            tracks: {'c': info},
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
      expect(cam.isSubscribed, isTrue, reason: 'the lease release waits');
      await _afterGrace(tester);
      expect(cam.isSubscribed, isFalse);
      expect(h.closesOf(bob), hasLength(1));
      expect(log.last, 'dispose');
      expect(reporter.removed, ['ann/c']);
      await tearDownRoom(tester);
    });

    testWidgets('binds the renderer once: rebuilds and mutes never set the '
        'stream again', (tester) async {
      final cam = await setUpRoom(tester);
      Widget build(int n) => _frame(
        Padding(
          padding: EdgeInsets.all(n.isEven ? 0 : 1),
          child: ParticipantVideoView.remote(
            cam,
            rendererFactory: factory,
            fit: n.isEven ? VideoViewFit.cover : VideoViewFit.contain,
            layerReporter: _RecordingReporter(),
          ),
        ),
      );
      await tester.pumpWidget(build(0));
      await _settle(tester);
      final stream = cam.currentTrack!.stream;
      expect(log, ['initialize', 'setStream(${stream.id})']);

      for (var n = 1; n <= 10; n++) {
        await tester.pumpWidget(build(n));
        await _step(tester);
      }
      // The publisher mutes and unmutes: the placeholder shows meanwhile,
      // and the same stream shows again without being set again.
      for (final muted in [true, false]) {
        await _drive(
          tester,
          ann.update(
            ParticipantState(
              participantId: 'ann',
              sessionId: 'ann-1',
              tracks: {'c': _cam.copyWith(muted: muted)},
            ),
          ),
        );
        await _settle(tester);
      }
      expect(find.text('video ${stream.id} cover'), findsOneWidget);
      expect(log, ['initialize', 'setStream(${stream.id})']);

      await tester.pumpWidget(const SizedBox());
      await _afterGrace(tester);
      await tearDownRoom(tester);
    });

    testWidgets('reports its size to the room by default, which picks the '
        'layer; automaticLayers: false opts out', (tester) async {
      final cam = await setUpRoom(
        tester,
        info: _cam.copyWith(
          simulcast: SimulcastInfo(
            rids: const ['a', 'b', 'c'],
            width: 1280,
            height: 720,
          ),
        ),
      );
      Widget view({required bool automatic}) => Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          // 640x360 logical is 1920x1080 physical at the test's
          // device-pixel ratio of 3: the full layer.
          child: SizedBox(
            width: 640,
            height: 360,
            child: ParticipantVideoView.remote(
              cam,
              automaticLayers: automatic,
              rendererFactory: factory,
            ),
          ),
        ),
      );

      await tester.pumpWidget(view(automatic: false));
      await _settle(tester);
      expect(h.pullsOf(bob), ['ann-1/c@b'], reason: 'the default layer');
      expect(cam.layerState.automaticRid, isNull);

      await tester.pumpWidget(view(automatic: true));
      await _settle(tester);
      expect(cam.layerState.automaticRid, 'a');
      expect(cam.currentRid, 'a');

      await tester.pumpWidget(const SizedBox());
      await _afterGrace(tester);
      expect(cam.isSubscribed, isFalse);
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
      await _afterGrace(tester);
      expect(cam.isSubscribed, isTrue);
      expect(h.closesOf(bob), isEmpty);

      await tester.pumpWidget(const SizedBox());
      await _afterGrace(tester);
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
      await _afterGrace(tester);
      expect(cam.isSubscribed, isFalse);
      await tearDownRoom(tester);
    });
  });
}
