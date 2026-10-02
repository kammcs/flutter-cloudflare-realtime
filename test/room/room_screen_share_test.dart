// Screen share through the Room (docs/design.md §10, roadmap M6): the
// encoding defaults, VP8 on Windows, a share that ends outside the app, and
// the no-frames watchdog (the macOS Screen Recording symptom).

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCPeerConnectionState, StatsReport;

import '../support/room_harness.dart';

const _screen1 = ScreenSource(
  id: 'screen-1',
  name: 'Screen 1',
  type: ScreenSourceType.screen,
);

Future<void> _settle() => pumpEventQueue(times: 50);

/// Runs pending microtasks and zero-length timers (the session batches
/// requests with them) on fake time.
void pump(FakeAsync async) {
  for (var i = 0; i < 40; i++) {
    async.elapse(Duration.zero);
  }
}

List<RoomEvent> _record(Room room) {
  final events = <RoomEvent>[];
  room.events.listen(events.add);
  return events;
}

void main() {
  late FakeDesktopCapturer desktop;
  late FakeMediaBackend media;
  late RoomHarness h;

  setUp(() {
    desktop = FakeDesktopCapturer([_screen1]);
    media = FakeMediaBackend(devices: [cam1, mic1], desktop: desktop);
    h = RoomHarness(media: media);
  });

  group('encoding', () {
    test('defaults to one text-friendly layer at 15 fps', () async {
      final alice = await h.join('alice');
      final share = await alice.localParticipant.publishScreen(
        source: _screen1,
      );
      expect(
        h.pcOf(alice).transceivers.single.sendEncodings,
        ScreenSharePresets.detail,
      );
      expect(ScreenSharePresets.detail.single.maxFramerate, 15);
      expect(share.simulcast, isNull);
      final capture = media.displayMediaCalls.single['video'] as Map;
      expect(capture['mandatory'], {'frameRate': 15.0});
      await alice.leave();
    });

    test('the simulcast preset announces its layers', () async {
      final alice = await h.join('alice');
      final bob = await h.join('bob');
      final share = await alice.localParticipant.publishScreen(
        source: _screen1,
        encodings: ScreenSharePresets.simulcast,
      );
      expect(
        h.pcOf(alice).transceivers.single.sendEncodings,
        ScreenSharePresets.simulcast,
      );
      expect(share.simulcast!.rids, ['a', 'b']);
      expect(share.simulcast!.scaleDownBy, [1, 4]);
      await _settle();
      expect(bob.participant('alice')!.screen!.simulcast!.rids, ['a', 'b']);
      await alice.leave();
      await bob.leave();
    });

    test(
      'is VP8 on every platform (flutter-webrtc #982), like cameras',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;
        addTearDown(() => debugDefaultTargetPlatformOverride = null);
        final alice = await h.join('alice');
        await alice.localParticipant.publishScreen(source: _screen1);
        expect(h.pcOf(alice).transceivers.single.codecPreferences, [
          'video/VP8',
        ]);
        await alice.leave();

        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        final eve = await h.join('eve');
        await eve.localParticipant.publishScreen(source: _screen1);
        expect(h.pcOf(eve).transceivers.single.codecPreferences, ['video/VP8']);
        await eve.leave();
      },
    );
  });

  group('ending outside the app', () {
    test('a closed source unpublishes the share and its audio, and updates '
        'signaling', () async {
      final alice = await h.join('alice');
      final bob = await h.join('bob');
      final events = _record(alice);
      final share = await alice.localParticipant.publishScreen(
        source: _screen1,
        options: const ScreenShareOptions(captureAudio: true),
      );
      final audio = alice.localParticipant.screenAudio!;
      await _settle();
      expect(h.announced('alice')!.tracks, hasLength(2));
      expect(bob.participant('alice')!.screenAudio, isNotNull);

      desktop.removed.add(_screen1);
      await _settle();
      expect(share.isPublished, isFalse);
      expect(audio.isPublished, isFalse);
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(bob.participant('alice')!.screen, isNull);
      expect(bob.participant('alice')!.screenAudio, isNull);
      final unpublished = events.whereType<LocalTrackUnpublishedEvent>();
      expect(unpublished.map((e) => e.publication), [share, audio]);
      expect(
        unpublished.map((e) => e.endReason),
        everyElement(ScreenShareEndReason.sourceClosed),
      );
      expect(h.closesOf(alice), hasLength(2));
      await alice.leave();
      await bob.leave();
    });

    test("the browser's Stop sharing button unpublishes (web)", () async {
      media.platform = MediaPlatform.web;
      final alice = await h.join('alice');
      final events = _record(alice);
      final share = await alice.localParticipant.publishScreen();
      final track = share.mediaSource.currentTrack!.track as FakeTrack;
      track.endExternally();
      await _settle();
      expect(share.isPublished, isFalse);
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(
        events.whereType<LocalTrackUnpublishedEvent>().single.endReason,
        ScreenShareEndReason.userStopped,
      );
      await alice.leave();
    });

    test('stopping from the system unpublishes (Android)', () async {
      final service = FakeScreenCaptureService();
      final android = FakeMediaBackend(
        platform: MediaPlatform.android,
        devices: [cam1, mic1],
        screenCapture: service,
      );
      h = RoomHarness(media: android);
      final alice = await h.join('alice');
      final events = _record(alice);
      final share = await alice.localParticipant.publishScreen();
      expect(service.calls, ['consent', 'start', startsWith('watch:')]);
      final track = share.mediaSource.currentTrack!.track as FakeTrack;

      service.stopFromSystem(track.id);
      await _settle();
      expect(share.isPublished, isFalse);
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(
        events.whereType<LocalTrackUnpublishedEvent>().single.endReason,
        ScreenShareEndReason.userStopped,
      );
      expect(service.running, isFalse);
      await alice.leave();
      await android.close();
    });

    test('stopping the broadcast unpublishes (iOS)', () async {
      final broadcast = FakeBroadcastExtension();
      final ios = FakeMediaBackend(
        platform: MediaPlatform.ios,
        devices: [cam1, mic1],
        broadcast: broadcast,
      );
      h = RoomHarness(media: ios);
      final alice = await h.join('alice');
      final events = _record(alice);
      final publishing = alice.localParticipant.publishScreen();
      await _settle();
      expect(h.announced('alice')!.tracks, isEmpty, reason: 'not started');
      broadcast.start();
      final share = await publishing;
      expect(share.isPublished, isTrue);

      broadcast.finish();
      await _settle();
      expect(share.isPublished, isFalse);
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(
        events.whereType<LocalTrackUnpublishedEvent>().single.endReason,
        ScreenShareEndReason.userStopped,
      );
      await alice.leave();
      await ios.close();
    });

    test('an incomplete iOS setup fails publishScreen', () async {
      final broadcast = FakeBroadcastExtension()
        ..problems = const [BroadcastSetupProblem.noExtensionKey];
      final ios = FakeMediaBackend(
        platform: MediaPlatform.ios,
        devices: [cam1, mic1],
        broadcast: broadcast,
      );
      h = RoomHarness(media: ios);
      final alice = await h.join('alice');
      await expectLater(
        alice.localParticipant.publishScreen(),
        throwsA(isA<ScreenShareSetupException>()),
      );
      expect(alice.localParticipant.screen, isNull);
      await alice.leave();
      await ios.close();
    });

    test('a share that ends while it is being pushed is unpublished', () async {
      final alice = await h.join('alice');
      final push = h.broker.onNewTracks!;
      h.broker.onNewTracks = (sessionId, request) {
        if (request.sessionDescription != null) desktop.removed.add(_screen1);
        return push(sessionId, request);
      };
      final share = await alice.localParticipant.publishScreen(
        source: _screen1,
      );
      await _settle();
      expect(share.isPublished, isFalse);
      expect(alice.localParticipant.screen, isNull);
      expect(h.announced('alice')!.tracks, isEmpty);
      await alice.leave();
    });

    test(
      'app actions carry no end reason; muting keeps it published',
      () async {
        final alice = await h.join('alice');
        final events = _record(alice);
        final share = await alice.localParticipant.publishScreen(
          source: _screen1,
        );
        await share.mute();
        await _settle();
        expect(share.isPublished, isTrue);
        expect(h.announced('alice')!.tracks[share.trackName]!.muted, isTrue);
        await share.unpublish();
        await _settle();
        expect(
          events.whereType<LocalTrackUnpublishedEvent>().single.endReason,
          isNull,
        );
        await alice.leave();
      },
    );
  });

  group('no-frames watchdog', () {
    /// Runs [body] on fake time with Alice sharing her screen.
    void run(
      void Function(
        FakeAsync async,
        Room alice,
        LocalMediaPublication share,
        List<RoomEvent> events,
      )
      body, {
      // No connection-quality polls: these tests count the watchdog's.
      RoomOptions options = const RoomOptions(
        connectEarly: false,
        stats: RoomStatsOptions(connectionQuality: null),
      ),
    }) {
      fakeAsync((async) {
        late Room alice;
        h.join('alice', options: options).then((r) => alice = r);
        pump(async);
        final events = _record(alice);
        late LocalMediaPublication share;
        alice.localParticipant
            .publishScreen(source: _screen1)
            .then((s) => share = s);
        pump(async);
        body(async, alice, share, events);
        alice.leave();
        pump(async);
        async.elapse(const Duration(seconds: 30));
      });
    }

    /// Stats with the share's `media-source` reporting [frames].
    void reportFrames(Room alice, LocalMediaPublication share, int frames) {
      h.pcOf(alice).statsProvider = () => [
        StatsReport('ms', 'media-source', 0, {
          'kind': 'video',
          'trackIdentifier': share.mediaSource.currentTrack?.track.id,
          'frames': frames,
        }),
      ];
    }

    List<LocalScreenShareStalledEvent> stalled(List<RoomEvent> events) =>
        events.whereType<LocalScreenShareStalledEvent>().toList();

    test('reports a share without frames once', () {
      run((async, alice, share, events) {
        reportFrames(alice, share, 0);
        async.elapse(const Duration(milliseconds: 7500));
        expect(stalled(events), isEmpty);
        async.elapse(const Duration(seconds: 1));
        final event = stalled(events).single;
        expect(event.publication, share);
        expect(event.error, isA<MediaCaptureException>());
        expect(share.isPublished, isTrue, reason: 'the app decides');

        final polls = h.pcOf(alice).statsCalls;
        async.elapse(const Duration(seconds: 20));
        expect(stalled(events), hasLength(1));
        expect(h.pcOf(alice).statsCalls, polls, reason: 'stopped polling');
      });
    });

    test('on macOS, suspects the Screen Recording permission', () {
      media.platform = MediaPlatform.macos;
      run((async, alice, share, events) {
        reportFrames(alice, share, 0);
        async.elapse(const Duration(seconds: 9));
        final error = stalled(events).single.error;
        expect(error, isA<ScreenCapturePermissionException>());
        expect(
          (error as ScreenCapturePermissionException).guidance,
          ScreenCapturePermissionException.macOSGuidance,
        );
      });
    });

    test('stops watching at the first frame', () {
      run((async, alice, share, events) {
        reportFrames(alice, share, 0);
        async.elapse(const Duration(seconds: 3));
        reportFrames(alice, share, 12);
        async.elapse(const Duration(seconds: 1));
        final polls = h.pcOf(alice).statsCalls;
        reportFrames(alice, share, 0);
        async.elapse(const Duration(seconds: 20));
        expect(stalled(events), isEmpty);
        expect(h.pcOf(alice).statsCalls, polls);
      });
    });

    test('encoded frames on the publication count too', () {
      run((async, alice, share, events) {
        h.pcOf(alice).statsProvider = () => [
          StatsReport('out', 'outbound-rtp', 0, {
            'kind': 'video',
            'mid': share.publication.mid,
            'framesEncoded': 3,
          }),
        ];
        async.elapse(const Duration(seconds: 20));
        expect(stalled(events), isEmpty);
      });
    });

    test('says nothing without stats for the share', () {
      run((async, alice, share, events) {
        h.pcOf(alice).stats = [
          StatsReport('other', 'media-source', 0, {
            'kind': 'video',
            'trackIdentifier': 'someone-else',
            'frames': 0,
          }),
        ];
        async.elapse(const Duration(seconds: 30));
        expect(stalled(events), isEmpty);
      });
    });

    test('only counts while the room is connected', () {
      run((async, alice, share, events) {
        reportFrames(alice, share, 0);
        h
            .pcOf(alice)
            .emitConnectionState(
              RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
            );
        async.elapse(const Duration(seconds: 10));
        expect(alice.currentConnectionState, RoomConnectionState.connecting);
        expect(stalled(events), isEmpty);
        h
            .pcOf(alice)
            .emitConnectionState(
              RTCPeerConnectionState.RTCPeerConnectionStateConnected,
            );
        async.elapse(const Duration(seconds: 7));
        expect(stalled(events), isEmpty);
        async.elapse(const Duration(seconds: 2));
        expect(stalled(events), hasLength(1));
      });
    });

    test('watches each new capture: unmuting re-arms it', () {
      run((async, alice, share, events) {
        reportFrames(alice, share, 0);
        async.elapse(const Duration(seconds: 9));
        expect(stalled(events), hasLength(1));

        share.mute();
        pump(async);
        async.elapse(const Duration(seconds: 20));
        expect(stalled(events), hasLength(1), reason: 'nothing captured');

        share.unmute();
        pump(async);
        reportFrames(alice, share, 0);
        async.elapse(const Duration(seconds: 9));
        expect(stalled(events), hasLength(2));
      });
    });

    test('ends with the share, and can be turned off', () {
      run((async, alice, share, events) {
        reportFrames(alice, share, 0);
        share.unpublish();
        pump(async);
        async.elapse(const Duration(seconds: 20));
        expect(stalled(events), isEmpty);
      });
      run(
        (async, alice, share, events) {
          reportFrames(alice, share, 0);
          async.elapse(const Duration(seconds: 30));
          expect(stalled(events), isEmpty);
        },
        options: const RoomOptions(
          connectEarly: false,
          screenShareStallTimeout: null,
        ),
      );
    });
  });
}
