// The call page at phone, tablet and desktop widths, with a real Room on
// the package's fakes (a cooperative fake SFU, in-memory signaling, fake
// media): every action reachable, nothing overflowing, tiles that keep
// their video, label and overlay inside their bounds, and the stage taken
// by a remote screen share that starts.

import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/call_page.dart';
import 'package:cloudflare_realtime_example/call_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

// The package's own test fakes (not part of its API).
import '../../test/support/room_harness.dart';

/// Renders like the real renderer does: flutter_webrtc's own RTCVideoView,
/// fitting a frame of [width]×[height] (as the native side reports it),
/// without the plugin (nothing is initialized, so no texture is drawn).
class _FrameRenderer implements VideoRenderer {
  _FrameRenderer(double width, double height) {
    _renderer.value = rtc.RTCVideoValue(width: width, height: height);
  }

  final rtc.RTCVideoRenderer _renderer = rtc.RTCVideoRenderer();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> setStream(rtc.MediaStream? stream) async {}

  @override
  Widget build(
    BuildContext context, {
    required VideoViewFit fit,
    required bool mirror,
    required FilterQuality filterQuality,
  }) => rtc.RTCVideoView(
    _renderer,
    mirror: mirror,
    objectFit: fit == VideoViewFit.contain
        ? rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
        : rtc.RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
  );

  @override
  Future<void> dispose() => _renderer.dispose();
}

/// The Pixel's screen, and a desktop's.
const _portrait = Size(1080, 2424);
const _landscape = Size(1920, 1080);

/// A Windows microphone with a long name, marked as the system default.
const _longMic = MediaDevice(
  deviceId: '{0.0.1.00000000}.{sonar}',
  kind: MediaDeviceKind.audioInput,
  label:
      'SteelSeries Sonar – Microphone (SteelSeries Sonar Virtual Audio '
      'Device)',
  isDefault: true,
);

const _camera = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);
const _screen = TrackInfo(kind: TrackKind.video, source: TrackSource.screen);

/// Lets both kinds of pending work run: fake-zone timers and microtasks,
/// and root-zone microtasks, which only the real event loop runs.
Future<void> _step(WidgetTester tester) async {
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

/// A call: "ada" (this device) and "android", who has a camera and maybe a
/// screen share.
class _Call {
  _Call(this.tester);

  final WidgetTester tester;
  final RoomHarness h = RoomHarness(
    media: FakeMediaBackend(devices: [cam1, _longMic]),
  );
  late Room room;
  late InMemorySignaling android;

  Future<void> start({
    required Size window,
    Size frame = _portrait,
    bool sharing = true,
    bool publish = true,
  }) async {
    tester.view.physicalSize = window;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final previous = ParticipantVideoView.defaultRendererFactory;
    ParticipantVideoView.defaultRendererFactory = () =>
        _FrameRenderer(frame.width, frame.height);
    addTearDown(() => ParticipantVideoView.defaultRendererFactory = previous);

    h.broker.trackKinds['android-1/c'] = 'video';
    h.broker.trackKinds['android-1/s'] = 'video';
    final signaling = InMemorySignaling(h.hub);
    room = await _drive(
      tester,
      h.join('ada', signaling: signaling, metadata: {'displayName': 'ada'}),
    );
    android = InMemorySignaling(h.hub);
    await _drive(tester, android.join('room', _android(sharing: sharing)));
    await tester.pumpWidget(
      MaterialApp(
        home: CallPage(
          room: room,
          mediaBackend: h.media,
          publishOnStart: publish,
          setup: CallSetup(
            signaling: signaling,
            participantId: 'ada',
            displayName: 'ada',
            broker: BrokerOptions(
              baseUrl: Uri.parse('https://broker.test/realtime'),
              headers: () async => const {},
            ),
            disposeSignaling: signaling.dispose,
            signalingStatus: Stream.value('connected'),
            addSimulatedParticipant: () async {},
          ),
        ),
      ),
    );
    await _settle(tester);
  }

  ParticipantState _android({bool sharing = true, bool cameraMuted = false}) =>
      ParticipantState(
        participantId: 'android',
        sessionId: 'android-1',
        metadata: const {'displayName': 'android'},
        tracks: {
          'c': _camera.copyWith(muted: cameraMuted),
          if (sharing) 's': _screen,
        },
      );

  Future<void> update({bool sharing = true, bool cameraMuted = false}) async {
    await _drive(
      tester,
      android.update(_android(sharing: sharing, cameraMuted: cameraMuted)),
    );
    await _settle(tester);
  }

  Future<void> end() async {
    await tester.pumpWidget(const SizedBox());
    await _settle(tester);
    // The video views' pulls are released after a grace period.
    await tester.pump(const Duration(seconds: 1));
    await _settle(tester);
    await _drive(tester, android.dispose());
  }
}

/// Fails on any error the frame reported, such as a RenderFlex overflow.
void _expectNoErrors(WidgetTester tester, String when) {
  final error = tester.takeException();
  expect(error, isNull, reason: '$when: $error');
}

/// Whether [rect] lies within [bounds] (to a fraction of a pixel).
Matcher _within(Rect bounds) => predicate<Rect>(
  (rect) =>
      rect.left >= bounds.left - 0.5 &&
      rect.top >= bounds.top - 0.5 &&
      rect.right <= bounds.right + 0.5 &&
      rect.bottom <= bounds.bottom + 0.5,
  'within $bounds',
);

void main() {
  const phones = [320.0, 360.0, 412.0];
  final windows = {
    for (final width in phones) width: Size(width, 720),
    600.0: const Size(600, 960),
    1280.0: const Size(1280, 800),
  };

  for (final MapEntry(key: width, value: window) in windows.entries) {
    testWidgets('at ${width.round()} dp every action is reachable and '
        'nothing overflows', (tester) async {
      final call = _Call(tester);
      await call.start(window: window);
      _expectNoErrors(tester, 'stage');

      // The share started the stage; the toggle is right in the app bar.
      final toggle = find.byTooltip('Gallery layout').hitTestable();
      expect(toggle, findsOneWidget);
      expect(tester.getRect(toggle), _within(Offset.zero & window));
      await tester.tap(toggle);
      await _settle(tester);
      _expectNoErrors(tester, 'gallery');
      expect(find.byTooltip('Stage layout').hitTestable(), findsOneWidget);

      // The connection status: a chip on wide screens, an icon elsewhere.
      if (width >= wideAppBarWidth) {
        expect(
          find.text('media: connected · signaling: connected'),
          findsOneWidget,
        );
      } else {
        expect(
          find
              .byTooltip('Connection: media: connected · signaling: connected')
              .hitTestable(),
          findsOneWidget,
        );
      }

      // The other actions: in the app bar, or in its menu.
      const actions = [
        'Add simulated participant',
        'Simulate network drop (debug)',
        'Leave',
      ];
      if (width < compactAppBarWidth) {
        await tester.tap(find.byTooltip('More actions'));
        await tester.pumpAndSettle();
        for (final action in [...actions, 'Show stats']) {
          final item = find.text(action);
          expect(item, findsOneWidget, reason: action);
          expect(tester.getRect(item), _within(Offset.zero & window));
        }
        await tester.tap(find.text('Show stats'));
        await _settle(tester);
      } else {
        for (final action in [...actions, 'Show stats']) {
          final button = find.byTooltip(action).hitTestable();
          expect(button, findsOneWidget, reason: action);
          expect(tester.getRect(button), _within(Offset.zero & window));
        }
        await tester.tap(find.byTooltip('Show stats'));
        await _settle(tester);
      }
      _expectNoErrors(tester, 'stats on');

      // The control bar, all of it on screen.
      for (final control in [
        'Mute microphone',
        'Turn camera off',
        'Switch camera',
        'Devices',
        'Share screen',
        'Leave call',
      ]) {
        final button = find.byTooltip(control).hitTestable();
        expect(button, findsOneWidget, reason: control);
        expect(tester.getRect(button), _within(Offset.zero & window));
      }

      // The microphone's long name ellipsizes within the screen.
      final mic = find.textContaining('SteelSeries Sonar');
      expect(mic, findsOneWidget);
      expect(tester.getRect(mic), _within(Offset.zero & window));

      // The device settings.
      await tester.tap(find.byTooltip('Devices'));
      await tester.pumpAndSettle();
      _expectNoErrors(tester, 'devices sheet');
      expect(find.text('Devices'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await call.end();
    });
  }

  for (final (name, frame) in [
    ('portrait', _portrait),
    ('landscape', _landscape),
  ]) {
    for (final window in [const Size(1280, 800), const Size(360, 720)]) {
      testWidgets('a $name screen share stays inside its tile, with its label '
          'and overlay, in the gallery and on the stage '
          '(${window.width.round()} dp)', (tester) async {
        final call = _Call(tester);
        await call.start(window: window, frame: frame, publish: false);

        for (final stage in [true, false]) {
          final where = stage ? 'stage' : 'gallery';
          final label = find.text("android's screen");
          final tile = find.ancestor(
            of: label,
            matching: find.byType(CallTile),
          );
          expect(tile, findsOneWidget, reason: where);
          final tileRect = tester.getRect(tile);
          expect(tileRect, _within(Offset.zero & window), reason: where);

          // The picture: flutter_webrtc's view, fitted inside the tile.
          final view = find.descendant(
            of: tile,
            matching: find.byType(rtc.RTCVideoView),
          );
          final picture = find.descendant(
            of: view,
            matching: find.byType(Transform),
          );
          final pictureRect = tester.getRect(picture);
          expect(pictureRect, _within(tileRect), reason: '$where picture');
          expect(
            pictureRect.center.dx,
            moreOrLessEquals(tileRect.center.dx, epsilon: 0.5),
            reason: '$where: letterboxed in the middle',
          );
          final aspect = pictureRect.width / pictureRect.height;
          expect(
            aspect,
            moreOrLessEquals(frame.width / frame.height, epsilon: 0.01),
          );

          // The label (bottom left) and the layer overlay (top right).
          final labelRect = tester.getRect(label);
          expect(labelRect, _within(tileRect), reason: '$where label');
          expect(labelRect.left, lessThan(tileRect.center.dx));
          expect(labelRect.top, greaterThan(tileRect.center.dy));
          final overlay = find.descendant(
            of: tile,
            matching: find.textContaining('rid '),
          );
          expect(overlay, findsOneWidget, reason: where);
          final overlayRect = tester.getRect(overlay);
          expect(overlayRect, _within(tileRect), reason: '$where overlay');
          expect(overlayRect.right, greaterThan(tileRect.center.dx));
          expect(overlayRect.bottom, lessThan(tileRect.center.dy));

          // A screen is nobody's: never starred as the dominant speaker.
          expect(
            find.descendant(of: tile, matching: find.byIcon(Icons.star)),
            findsNothing,
            reason: where,
          );

          // The tile paints its background behind the letterbox bars.
          final background = find.descendant(
            of: tile,
            matching: find.byWidgetPredicate(
              (w) => w is ColoredBox && w.color == tileBackground,
            ),
          );
          expect(tester.getRect(background.first), tileRect);

          if (stage) {
            await tester.tap(find.byTooltip('Gallery layout'));
            await _settle(tester);
          }
        }
        _expectNoErrors(tester, 'layouts');
        await call.end();
      });
    }
  }

  testWidgets('a remote screen share that starts takes the stage, once', (
    tester,
  ) async {
    final call = _Call(tester);
    await call.start(
      window: const Size(1280, 800),
      sharing: false,
      publish: false,
    );
    expect(find.byTooltip('Stage layout'), findsOneWidget, reason: 'gallery');

    await call.update();
    expect(find.byTooltip('Gallery layout'), findsOneWidget, reason: 'stage');
    expect(find.text('android is sharing their screen.'), findsOneWidget);

    // Back to the gallery: the same share doesn't force the stage again.
    await tester.tap(find.byTooltip('Gallery layout'));
    await _settle(tester);
    await call.update(cameraMuted: true);
    expect(find.byTooltip('Stage layout'), findsOneWidget);

    // It stops, then a new share starts: the stage again.
    await call.update(sharing: false);
    expect(find.byTooltip('Stage layout'), findsOneWidget);
    await call.update();
    expect(find.byTooltip('Gallery layout'), findsOneWidget);

    await call.end();
  });

  testWidgets('a pin made before a share starts gives way to it', (
    tester,
  ) async {
    final call = _Call(tester);
    await call.start(
      window: const Size(1280, 800),
      sharing: false,
      publish: false,
    );
    await tester.tap(find.byTooltip('Stage layout'));
    await _settle(tester);
    // Pin "ada (you)" from the thumbnails.
    await tester.tap(find.text('ada (you)'));
    await _settle(tester);
    expect(find.byIcon(Icons.push_pin), findsOneWidget);

    await call.update();
    expect(find.byIcon(Icons.push_pin), findsNothing);
    final stage = tester.getRect(
      find.ancestor(
        of: find.text("android's screen"),
        matching: find.byType(CallTile),
      ),
    );
    expect(stage.height, greaterThan(400), reason: 'the share is on stage');
    await call.end();
  });
}
