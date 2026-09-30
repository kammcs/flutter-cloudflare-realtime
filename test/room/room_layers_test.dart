import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/room_harness.dart';

const _cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);

/// A 720p camera sending `a`/`b`/`c`.
final _cam720 = _cam.copyWith(
  simulcast: SimulcastInfo(
    rids: const ['a', 'b', 'c'],
    width: 1280,
    height: 720,
    scaleDownBy: const [1, 2, 4],
  ),
);

/// Physical tile sizes: with a 720p ladder, `c` up to 270 lines, `b` up to
/// 540, `a` above.
const _thumb = TileDemand(width: 320, height: 180);
const _gallery = TileDemand(width: 854, height: 480);
const _stage = TileDemand(width: 1920, height: 1080);
const _hidden = TileDemand(width: 854, height: 480, visible: false);

/// Runs [body] on fake time with a joined room `bob` and a presence-only
/// publisher `ann` (session `ann-1`).
void _run(
  void Function(
    FakeAsync async,
    RoomHarness h,
    Room bob,
    void Function() pump,
    void Function(Map<String, TrackInfo>) announce,
  )
  body, {
  RoomOptions options = const RoomOptions(),
}) {
  fakeAsync((async) {
    void pump() {
      for (var i = 0; i < 40; i++) {
        async.elapse(Duration.zero);
      }
    }

    final h = RoomHarness();
    late Room bob;
    h.join('bob', options: options).then((r) => bob = r);
    pump();
    final ann = InMemorySignaling(h.hub);
    var joined = false;
    void announce(Map<String, TrackInfo> tracks) {
      for (final MapEntry(key: name, value: info) in tracks.entries) {
        h.broker.trackKinds['ann-1/$name'] = info.kind.name;
      }
      final state = ParticipantState(
        participantId: 'ann',
        sessionId: 'ann-1',
        tracks: tracks,
      );
      if (joined) {
        ann.update(state);
      } else {
        joined = true;
        ann.join('room', state);
      }
      pump();
    }

    body(async, h, bob, pump, announce);
    bob.leave();
    ann.dispose();
    pump();
  });
}

/// The RIDs `room` sent with `tracks/update`, in order.
List<String> _updates(RoomHarness h, Room room) => [
  for (final call in h.callsOf(room, 'tracks/update'))
    for (final t in (call.request! as UpdateTracksRequest).tracks)
      t.simulcast!.preferredRid,
];

void main() {
  test('pulls carry ridNotAvailable: asciibetical and no priorityOrdering', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      cam.subscribe();
      pump();
      final pull = h
          .callsOf(bob, 'tracks/new')
          .map((c) => c.request! as TracksRequest)
          .where((r) => r.sessionDescription == null)
          .single;
      final simulcast = pull.tracks.single.simulcast!;
      expect(simulcast.preferredRid, 'b', reason: 'defaultVideoLayer');
      expect(simulcast.ridNotAvailable, SimulcastOrdering.asciibetical);
      expect(simulcast.priorityOrdering, isNull);
      expect(cam.currentRid, 'b');
    });
  });

  test('the layer follows the biggest visible view, debounced', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      final reporter = bob.layerReporter;

      // The first report is applied at once, so the pull starts right.
      reporter.reportDemand(cam.id, 'thumb', _thumb);
      final lease = cam.retain();
      pump();
      expect(h.pullsOf(bob), ['ann-1/c@c']);
      expect(cam.layerState.automaticRid, 'c');

      // A second, bigger view of the same track wins.
      reporter.reportDemand(cam.id, 'stage', _stage);
      pump();
      expect(_updates(h, bob), isEmpty, reason: 'debounced');
      async.elapse(const Duration(milliseconds: 300));
      pump();
      expect(_updates(h, bob), ['a']);
      expect(cam.currentRid, 'a');

      // The stage view shrinks to a gallery tile, well below the
      // hysteresis band (on `a`, `b` is picked only at 459 lines or fewer).
      reporter.reportDemand(
        cam.id,
        'stage',
        const TileDemand(width: 640, height: 360),
      );
      async.elapse(const Duration(milliseconds: 300));
      pump();
      expect(_updates(h, bob), ['a', 'b']);

      // Only the thumbnail is left.
      reporter.removeView(cam.id, 'stage');
      async.elapse(const Duration(milliseconds: 300));
      pump();
      expect(_updates(h, bob), ['a', 'b', 'c']);
      expect(cam.layerState.currentRid, 'c');
      expect(h.pullsOf(bob), hasLength(1), reason: 'one pull throughout');
      lease.release();
    });
  });

  test('a layer changed while the pull is in flight is applied after it', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      cam.subscribe(); // Pulled at the default layer, b.
      bob.layerReporter.reportDemand(cam.id, 'v', _stage); // Now a.
      pump();
      expect(h.pullsOf(bob), ['ann-1/c@b']);
      expect(_updates(h, bob), ['a']);
      expect(cam.currentRid, 'a');
    });
  });

  test('hidden views drop to the lowest layer, and the pull is released '
      'after the linger', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      final reporter = bob.layerReporter;
      reporter.reportDemand(cam.id, 'v', _gallery);
      final lease = cam.retain();
      pump();
      expect(h.pullsOf(bob), ['ann-1/c@b']);

      // Scrolled away: the lowest layer once the change stands.
      reporter.reportDemand(cam.id, 'v', _hidden);
      async.elapse(const Duration(milliseconds: 300));
      pump();
      expect(_updates(h, bob), ['c']);
      expect(cam.layerState.hidden, isTrue);
      expect(cam.layerState.targetRid, 'c');
      expect(cam.isSubscribed, isTrue);

      // Still hidden after the linger: the pull is released.
      async.elapse(const Duration(seconds: 4));
      pump();
      expect(h.closesOf(bob), isEmpty);
      async.elapse(const Duration(seconds: 1));
      pump();
      expect(h.closesOf(bob), hasLength(1));
      expect(cam.isSubscribed, isFalse);
      expect(cam.layerState.released, isTrue);
      expect(cam.currentTrack, isNull);

      // Back on screen: pulled again at once, at the right layer.
      reporter.reportDemand(cam.id, 'v', _stage);
      pump();
      expect(h.pullsOf(bob), ['ann-1/c@b', 'ann-1/c@a']);
      expect(cam.isSubscribed, isTrue);
      expect(cam.layerState.released, isFalse);
      expect(cam.currentTrack, isNotNull);
      lease.release();
    });
  });

  test('a view that is visible again within the linger keeps the pull', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      final reporter = bob.layerReporter;
      reporter.reportDemand(cam.id, 'v', _gallery);
      final lease = cam.retain();
      pump();

      reporter.reportDemand(cam.id, 'v', _hidden);
      async.elapse(const Duration(seconds: 2));
      pump();
      reporter.reportDemand(cam.id, 'v', _gallery);
      pump();
      async.elapse(const Duration(seconds: 10));
      pump();
      expect(_updates(h, bob), ['c', 'b']);
      expect(h.closesOf(bob), isEmpty);
      expect(h.pullsOf(bob), hasLength(1));
      lease.release();
    });
  });

  test('an explicit subscribe keeps a hidden track pulled at its lowest '
      'layer', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      cam.subscribe();
      bob.layerReporter.reportDemand(cam.id, 'v', _hidden);
      pump();
      async.elapse(const Duration(seconds: 10));
      pump();
      expect(cam.isSubscribed, isTrue);
      expect(h.closesOf(bob), isEmpty);
      expect(cam.currentRid, 'c');
    });
  });

  test('a released lease waits out the grace period', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;

      // Unmount and remount within the grace: nothing is closed or pulled
      // again.
      final first = cam.retain();
      pump();
      first.release();
      async.elapse(const Duration(milliseconds: 200));
      final second = cam.retain();
      pump();
      async.elapse(const Duration(seconds: 1));
      pump();
      expect(h.pullsOf(bob), hasLength(1));
      expect(h.closesOf(bob), isEmpty);
      expect(cam.isSubscribed, isTrue);

      // A release that isn't followed by a new lease closes the pull after
      // the grace.
      second.release();
      async.elapse(const Duration(milliseconds: 499));
      pump();
      expect(cam.isSubscribed, isTrue);
      expect(h.closesOf(bob), isEmpty);
      async.elapse(const Duration(milliseconds: 1));
      pump();
      expect(cam.isSubscribed, isFalse);
      expect(h.closesOf(bob), hasLength(1));
    });
  });

  test('setPreferredLayer overrides the automatic choice until cleared', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      final reporter = bob.layerReporter;
      final states = <RemoteTrackLayerState>[];
      cam.layerChanges.listen(states.add);
      reporter.reportDemand(cam.id, 'v', _thumb);
      final lease = cam.retain();
      pump();
      expect(cam.currentRid, 'c');

      cam.setPreferredLayer(SimulcastLayer.high);
      pump();
      expect(_updates(h, bob), ['a']);
      expect(cam.preferredLayer, SimulcastLayer.high);

      // View changes don't move a manual layer.
      reporter.reportDemand(cam.id, 'v', _gallery);
      async.elapse(const Duration(milliseconds: 300));
      pump();
      expect(_updates(h, bob), ['a']);
      expect(cam.layerState.automaticRid, 'b');
      expect(cam.layerState.targetRid, 'a');

      // Cleared: back to the automatic choice.
      cam.clearPreferredLayer();
      pump();
      expect(_updates(h, bob), ['a', 'b']);
      expect(cam.preferredLayer, isNull);

      // `null` clears too.
      cam.setPreferredLayer(SimulcastLayer.low);
      pump();
      cam.setPreferredLayer(null);
      pump();
      expect(_updates(h, bob), ['a', 'b', 'c', 'b']);
      expect(
        states.last,
        const RemoteTrackLayerState(
          currentRid: 'b',
          targetRid: 'b',
          automaticRid: 'b',
        ),
      );
      lease.release();
    });
  });

  test('the ladder comes from the simulcast hint, and follows it', () {
    _run((async, h, bob, pump, announce) {
      // A 360p publisher: the encoder sends only `a` and `b`.
      final cam360 = _cam.copyWith(
        simulcast: SimulcastInfo(
          rids: const ['a', 'b', 'c'],
          width: 640,
          height: 360,
        ),
      );
      announce({'c': cam360});
      final cam = bob.participant('ann')!.camera!;
      final reporter = bob.layerReporter;
      reporter.reportDemand(cam.id, 'v', _thumb);
      final lease = cam.retain();
      pump();
      // A thumbnail gets the lowest layer the publisher sends: `b`
      // (320x180) covers 180 lines.
      expect(h.pullsOf(bob), ['ann-1/c@b']);

      // Hidden: the lowest sent layer is `b`, not `c`.
      reporter.reportDemand(cam.id, 'v', _hidden);
      async.elapse(const Duration(milliseconds: 300));
      pump();
      expect(cam.layerState.targetRid, 'b');
      expect(_updates(h, bob), isEmpty);

      // The publisher moves to 720p: three layers, so `c` exists now.
      announce({'c': _cam720});
      pump();
      expect(cam.layerState.targetRid, 'c');
      expect(_updates(h, bob), ['c']);
      lease.release();
    });
  });

  test('a hint without a size assumes 720p with its rids', () {
    _run((async, h, bob, pump, announce) {
      announce({
        'c': _cam.copyWith(simulcast: SimulcastInfo(rids: const ['h', 'l'])),
      });
      final cam = bob.participant('ann')!.camera!;
      bob.layerReporter.reportDemand(cam.id, 'v', _stage);
      final lease = cam.retain();
      pump();
      expect(h.pullsOf(bob), ['ann-1/c@h']);
      lease.release();
    });
  });

  test('video without simulcast gets no rid, but hidden views still release '
      'the pull', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam});
      final cam = bob.participant('ann')!.camera!;
      final reporter = bob.layerReporter;
      reporter.reportDemand(cam.id, 'v', _stage);
      final lease = cam.retain();
      pump();
      expect(h.pullsOf(bob), ['ann-1/c']);
      expect(cam.layerState.targetRid, isNull);

      reporter.reportDemand(cam.id, 'v', _hidden);
      async.elapse(const Duration(seconds: 6));
      pump();
      expect(_updates(h, bob), isEmpty);
      expect(h.closesOf(bob), hasLength(1));
      lease.release();
    });
  });

  test('the linger and grace are configurable', () {
    _run(
      (async, h, bob, pump, announce) {
        announce({'c': _cam720});
        final cam = bob.participant('ann')!.camera!;
        bob.layerReporter.reportDemand(cam.id, 'v', _hidden);
        final lease = cam.retain();
        pump();
        async.elapse(const Duration(minutes: 1));
        pump();
        expect(cam.isSubscribed, isTrue, reason: 'no linger');
        expect(cam.currentRid, 'c');

        lease.release();
        pump();
        expect(cam.isSubscribed, isFalse, reason: 'no grace');
      },
      options: const RoomOptions(
        hiddenVideoLinger: null,
        leaseReleaseGrace: Duration.zero,
      ),
    );
  });

  test('reports for unknown or audio tracks are ignored', () {
    _run((async, h, bob, pump, announce) {
      announce({
        'm': const TrackInfo(
          kind: TrackKind.audio,
          source: TrackSource.microphone,
        ),
      });
      final mic = bob.participant('ann')!.microphone!;
      bob.layerReporter
        ..reportDemand(mic.id, 'v', _stage)
        ..reportDemand('nobody/x', 'v', _stage)
        ..removeView('nobody/x', 'v');
      async.elapse(const Duration(seconds: 1));
      pump();
      expect(_updates(h, bob), isEmpty);
      expect(mic.layerState.targetRid, isNull);
    });
  });

  test('closing the track cancels its timers', () {
    _run((async, h, bob, pump, announce) {
      announce({'c': _cam720});
      final cam = bob.participant('ann')!.camera!;
      bob.layerReporter.reportDemand(cam.id, 'v', _hidden);
      final lease = cam.retain();
      pump();
      lease.release();
      announce({});
      expect(cam.isClosed, isTrue);
      // Only the active-speaker poll is left.
      expect(async.pendingTimers.where((t) => !t.isPeriodic), isEmpty);
    });
  });
}
