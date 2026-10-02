// Publisher-side call quality (M12, design.md §6.2, §6.3): layer demand
// reported through signaling, layers paused when no one pulls them, the
// captured size announced, and the room's video codec.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import '../support/room_harness.dart';

const _quiet = RoomOptions(connectEarly: false, activeSpeaker: null);

/// Alice's default here: pausing on (it is off by default).
const _pausing = RoomOptions(
  connectEarly: false,
  activeSpeaker: null,
  layerPausing: LayerPausingOptions.on,
);

/// Runs [body] on fake time with two joined rooms, `alice` (publishing)
/// and `bob`.
void _run(
  void Function(
    FakeAsync async,
    RoomHarness h,
    Room alice,
    Room bob,
    void Function() pump,
  )
  body, {
  RoomOptions alice = _pausing,
  RoomOptions bob = _quiet,
  MediaPlatform platform = MediaPlatform.android,
}) {
  fakeAsync((async) {
    void pump() {
      for (var i = 0; i < 60; i++) {
        async.elapse(Duration.zero);
      }
    }

    final h = RoomHarness(
      media: FakeMediaBackend(platform: platform, devices: [cam1, mic1]),
    );
    late Room a;
    late Room b;
    h.join('alice', options: alice).then((r) => a = r);
    pump();
    h.join('bob', options: bob).then((r) => b = r);
    pump();
    body(async, h, a, b, pump);
    a.leave();
    b.leave();
    pump();
  });
}

/// Alice's camera transceiver.
FakeTransceiver _camera(RoomHarness h, Room alice) => h
    .pcOf(alice)
    .transceivers
    .firstWhere((t) => t.kind == 'video' && t.direction == 'sendonly');

/// The RIDs Alice's camera sends now.
Set<String> _active(RoomHarness h, Room alice) => {
  for (final e in _camera(h, alice).sendEncodings)
    if (e.active && e.rid != null) e.rid!,
};

LocalMediaPublication _publishCamera(
  Room alice,
  void Function() pump, {
  List<SendEncoding>? encodings,
  VideoCodec? codec,
}) {
  LocalMediaPublication? published;
  alice.localParticipant
      .publishCamera(encodings: encodings, codec: codec)
      .then((p) => published = p);
  pump();
  return published!;
}

void main() {
  group('layer demand and pausing', () {
    test('a subscriber reports its layer; the publisher pauses the layers '
        'above it after the delay and resumes them at once', () {
      _run((async, h, alice, bob, pump) {
        final published = _publishCamera(alice, pump);
        final name = published.trackName;
        final cam = bob.participant('alice')!.camera!;
        expect(h.announced('bob')!.layerDemand, isEmpty);

        cam.setPreferredLayer(SimulcastLayer.low);
        cam.subscribe();
        pump();
        expect(h.announced('bob')!.layerDemand, {name: 'c'});
        expect(_active(h, alice), {'a', 'b', 'c'});

        // Not before the pause delay (5 s by default).
        async.elapse(const Duration(seconds: 4));
        pump();
        expect(_active(h, alice), {'a', 'b', 'c'});
        expect(published.pausedLayers, isEmpty);
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(_active(h, alice), {'c'});
        expect(published.pausedLayers, {'a', 'b'});
        // Pausing changes the encodings only: same publication, same rids.
        expect(published.publication.sendEncodings.map((e) => e.rid), [
          'a',
          'b',
          'c',
        ]);

        // Bob wants the top layer: announced, and resumed at once.
        final changes = <Set<String>>[];
        published.pausedLayersChanges.listen(changes.add);
        cam.setPreferredLayer(SimulcastLayer.high);
        pump();
        expect(h.announced('bob')!.layerDemand, {name: 'a'});
        expect(_active(h, alice), {'a', 'b', 'c'});
        expect(changes.last, isEmpty);

        // Bob stops pulling: the track leaves his demand, and Alice goes
        // back to her lowest layer after the delay.
        cam.unsubscribe();
        pump();
        expect(h.announced('bob')!.layerDemand, isEmpty);
        async.elapse(const Duration(seconds: 5));
        pump();
        expect(_active(h, alice), {'c'});
      });
    });

    test('views: a hidden view keeps the lowest layer; a released pull '
        'leaves the demand', () {
      _run(
        (async, h, alice, bob, pump) {
          final published = _publishCamera(alice, pump);
          final cam = bob.participant('alice')!.camera!;
          bob.layerReporter.reportDemand(
            cam.id,
            'view',
            const TileDemand(width: 1920, height: 1080),
          );
          final lease = cam.retain();
          pump();
          expect(h.announced('bob')!.layerDemand, {published.trackName: 'a'});

          bob.layerReporter.reportDemand(
            cam.id,
            'view',
            const TileDemand(width: 1920, height: 1080, visible: false),
          );
          async.elapse(const Duration(milliseconds: 300));
          pump();
          expect(h.announced('bob')!.layerDemand, {published.trackName: 'c'});

          // Released after RoomOptions.hiddenVideoLinger (1 s here).
          async.elapse(const Duration(seconds: 1));
          pump();
          expect(h.announced('bob')!.layerDemand, isEmpty);
          lease.release();
          pump();
        },
        bob: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          hiddenVideoLinger: Duration(seconds: 1),
        ),
      );
    });

    test('a participant that does not report demand keeps every layer', () {
      _run((async, h, alice, bob, pump) {
        // Carol is an older client: no layerDemand in her state.
        final carol = InMemorySignaling(h.hub);
        carol.join(
          'room',
          ParticipantState(participantId: 'carol', sessionId: 'carol-1'),
        );
        pump();
        _publishCamera(alice, pump);
        async.elapse(const Duration(seconds: 10));
        pump();
        expect(_active(h, alice), {'a', 'b', 'c'});

        // Once she leaves, only Bob counts, and he pulls nothing.
        carol.leave();
        pump();
        async.elapse(const Duration(seconds: 5));
        pump();
        expect(_active(h, alice), {'c'});
        carol.dispose();
      });
    });

    test('an unknown RID in the demand keeps every layer', () {
      _run((async, h, alice, bob, pump) {
        final published = _publishCamera(alice, pump);
        final carol = InMemorySignaling(h.hub);
        carol.join(
          'room',
          ParticipantState(
            participantId: 'carol',
            sessionId: 'carol-1',
            layerDemand: {published.trackName: 'q'},
          ),
        );
        pump();
        async.elapse(const Duration(seconds: 10));
        pump();
        expect(_active(h, alice), {'a', 'b', 'c'});
        carol.dispose();
      });
    });

    test('minActiveLayers keeps more layers on', () {
      _run(
        (async, h, alice, bob, pump) {
          final published = _publishCamera(alice, pump);
          async.elapse(const Duration(seconds: 5));
          pump();
          expect(published.pausedLayers, {'a'});
          expect(_active(h, alice), {'b', 'c'});
        },
        alice: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          layerPausing: LayerPausingOptions(enabled: true, minActiveLayers: 2),
        ),
      );
    });

    test('by default nothing is paused, and demand is reported', () {
      _run(
        (async, h, alice, bob, pump) {
          final published = _publishCamera(alice, pump);
          bob.participant('alice')!.camera!
            ..setPreferredLayer(SimulcastLayer.low)
            ..subscribe();
          pump();
          async.elapse(const Duration(seconds: 10));
          pump();
          expect(h.pcOf(alice).log, isNot(contains('setEncodings')));
          expect(published.pausedLayers, isEmpty);
          expect(h.announced('alice')!.layerDemand, isEmpty);
        },
        alice: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          layerPausing: LayerPausingOptions(),
        ),
      );
    });

    test('without reportDemand nothing is announced, and publishers keep '
        'every layer', () {
      _run(
        (async, h, alice, bob, pump) {
          _publishCamera(alice, pump);
          bob.participant('alice')!.camera!
            ..setPreferredLayer(SimulcastLayer.low)
            ..subscribe();
          pump();
          expect(h.announced('bob')!.layerDemand, isNull);
          async.elapse(const Duration(seconds: 10));
          pump();
          expect(_active(h, alice), {'a', 'b', 'c'});
        },
        bob: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          layerPausing: LayerPausingOptions(reportDemand: false),
        ),
      );
    });

    test('paused layers stay paused on a new session, and resume there', () {
      _run((async, h, alice, bob, pump) {
        h.autoConnect = true;
        final published = _publishCamera(alice, pump);
        final cam = bob.participant('alice')!.camera!
          ..setPreferredLayer(SimulcastLayer.low)
          ..subscribe();
        pump();
        async.elapse(const Duration(seconds: 5));
        pump();
        expect(_active(h, alice), {'c'});

        final before = alice.session;
        alice.debugSimulateConnectionFailure();
        async.elapse(const Duration(seconds: 3));
        pump();
        expect(alice.session, isNot(same(before)));
        expect(published.publication.state, SfuTrackState.active);
        expect(_active(h, alice), {'c'}, reason: 'republished as paused');

        cam.setPreferredLayer(SimulcastLayer.high);
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(_active(h, alice), {'a', 'b', 'c'});
      });
    });

    test('a single-encoding video is never paused', () {
      _run((async, h, alice, bob, pump) {
        final published = _publishCamera(alice, pump, encodings: const []);
        async.elapse(const Duration(seconds: 10));
        pump();
        expect(published.simulcast, isNull);
        expect(published.pausedLayers, isEmpty);
        expect(h.pcOf(alice).log, isNot(contains('setEncodings')));
      });
    });
  });

  group('captured size', () {
    test('is announced from the track, then from the stats', () {
      _run((async, h, alice, bob, pump) {
        h.media.videoSettings = {'width': 960, 'height': 720};
        final published = _publishCamera(alice, pump);
        final announced = h.announced('alice')!.tracks[published.trackName]!;
        expect(announced.simulcast!.width, 960);
        expect(announced.simulcast!.height, 720);

        // The phone is held upright: it sends portrait.
        final trackId = published.publication.track!.id;
        h.pcOf(alice).stats = [
          StatsReport('ms', 'media-source', 0, {
            'kind': 'video',
            'trackIdentifier': trackId,
            'width': 720,
            'height': 1280,
          }),
        ];
        async.elapse(const Duration(seconds: 3));
        pump();
        final portrait = h.announced('alice')!.tracks[published.trackName]!;
        expect(portrait.simulcast, published.simulcast);
        expect(portrait.simulcast!.width, 720);
        expect(portrait.simulcast!.height, 1280);
        expect(portrait.simulcast!.rids, ['a', 'b', 'c']);
        expect(bob.participant('alice')!.camera!.simulcast!.height, 1280);
      });
    });

    test("a small capture pauses by the encoder's ladder", () {
      _run((async, h, alice, bob, pump) {
        final published = _publishCamera(alice, pump);
        h.pcOf(alice).stats = [
          StatsReport('ms', 'media-source', 0, {
            'kind': 'video',
            'trackIdentifier': published.publication.track!.id,
            'width': 640,
            'height': 360,
          }),
        ];
        async.elapse(const Duration(seconds: 3));
        pump();
        expect(published.simulcast!.height, 360);
        // Bob asks for c, which a 360p encoder doesn't send: b stands in,
        // and c is left as it is.
        bob.participant('alice')!.camera!
          ..setPreferredLayer(SimulcastLayer.low)
          ..subscribe();
        pump();
        async.elapse(const Duration(seconds: 5));
        pump();
        expect(published.pausedLayers, {'a'});
        expect(_active(h, alice), {'b', 'c'});
      });
    });

    test('is kept while muted, and re-read after a new track', () {
      _run((async, h, alice, bob, pump) {
        final published = _publishCamera(alice, pump);
        h.pcOf(alice).statsProvider = () => [
          if (published.publication.track case final track?)
            StatsReport('ms', 'media-source', 0, {
              'kind': 'video',
              'trackIdentifier': track.id,
              'width': 1280,
              'height': 960,
            }),
        ];
        published.mute();
        pump();
        async.elapse(const Duration(seconds: 6));
        pump();
        expect(published.simulcast!.height, 720, reason: 'nothing sent');
        published.unmute();
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        expect(published.simulcast!.height, 960);
      });
    });
  });

  group('video codec', () {
    List<String>? codecs(RoomHarness h, Room alice) =>
        _camera(h, alice).codecPreferences;

    test('defaults to the session preference (VP8)', () {
      _run((async, h, alice, bob, pump) {
        final published = _publishCamera(alice, pump);
        expect(codecs(h, alice), ['video/VP8']);
        expect(published.videoCodec, isNull);
      });
    });

    test('RoomOptions.videoCodec, with VP8 as the fallback', () {
      _run(
        (async, h, alice, bob, pump) {
          final published = _publishCamera(alice, pump);
          expect(codecs(h, alice), ['video/H264', 'video/VP8']);
          expect(published.videoCodec, VideoCodec.h264);
        },
        alice: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          videoCodec: VideoCodec.h264,
        ),
      );
    });

    test('a publish can override it', () {
      _run(
        (async, h, alice, bob, pump) {
          final published = _publishCamera(alice, pump, codec: VideoCodec.vp8);
          expect(codecs(h, alice), ['video/VP8']);
          expect(published.videoCodec, VideoCodec.vp8);
        },
        alice: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          videoCodec: VideoCodec.av1,
        ),
      );
    });

    test('Windows sends VP8 instead of H.264, and says so', () {
      _run(
        (async, h, alice, bob, pump) {
          final events = <RoomEvent>[];
          alice.events.listen(events.add);
          final published = _publishCamera(alice, pump);
          expect(codecs(h, alice), ['video/VP8']);
          expect(published.videoCodec, VideoCodec.vp8);
          expect(
            events.whereType<RoomErrorEvent>().map((e) => e.operation),
            contains('videoCodec'),
          );
        },
        platform: MediaPlatform.windows,
        alice: const RoomOptions(
          connectEarly: false,
          activeSpeaker: null,
          videoCodec: VideoCodec.h264,
        ),
      );
    });
  });
}
