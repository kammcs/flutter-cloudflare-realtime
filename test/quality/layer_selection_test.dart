import 'dart:ui' show Size;

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/layer_selection.dart';
import 'package:cloudflare_realtime/src/quality/simulcast_ladder.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SimulcastLadder', () {
    test('h720 is a=720, b=360, c=180', () {
      expect(SimulcastLadder.h720.layers, const [
        SimulcastLayerSpec(rid: 'a', width: 1280, height: 720),
        SimulcastLayerSpec(rid: 'b', width: 640, height: 360),
        SimulcastLayerSpec(rid: 'c', width: 320, height: 180),
      ]);
      expect(SimulcastLadder.h720.highest.rid, 'a');
      expect(SimulcastLadder.h720.lowest.rid, 'c');
      expect(SimulcastLadder.h720.rankOf('b'), 1);
      expect(SimulcastLadder.h720.rankOf('z'), isNull);
      expect(SimulcastLadder.h720.layer('c')!.height, 180);
    });

    test('the encoder layer limit drops the lowest layers', () {
      expect(SimulcastLadder.maxLayersFor(1920, 1080), 3);
      expect(SimulcastLadder.maxLayersFor(960, 540), 3);
      expect(SimulcastLadder.maxLayersFor(640, 360), 2);
      expect(SimulcastLadder.maxLayersFor(480, 270), 2);
      expect(SimulcastLadder.maxLayersFor(320, 180), 1);

      final h360 = SimulcastLadder.fromPreset(VideoPreset.h360);
      expect(h360.layers.map((l) => '${l.rid}:${l.height}'), [
        'a:360',
        'b:180',
      ]);
      final h180 = SimulcastLadder.fromPreset(VideoPreset.h180);
      expect(h180.layers.map((l) => l.rid), ['a']);
    });

    test('the limit can be turned off', () {
      final ladder = SimulcastLadder.fromPreset(
        VideoPreset.h360,
        applyEncoderLayerLimit: false,
      );
      expect(ladder.layers.map((l) => l.height), [360, 180, 90]);
    });

    test('equality', () {
      expect(
        SimulcastLadder.fromPreset(VideoPreset.h720),
        SimulcastLadder.h720,
      );
      expect(
        SimulcastLadder.fromPreset(VideoPreset.h1080),
        isNot(SimulcastLadder.h720),
      );
    });
  });

  group('TileDemand', () {
    test('converts logical size to physical pixels', () {
      final demand = TileDemand.fromLogicalSize(const Size(320, 180), 2);
      expect(demand, const TileDemand(width: 640, height: 360));
      expect(demand.needsVideo, isTrue);
    });

    test('hidden or empty tiles need no video', () {
      expect(TileDemand.hidden.needsVideo, isFalse);
      expect(
        const TileDemand(width: 100, height: 100, visible: false).needsVideo,
        isFalse,
      );
      expect(const TileDemand(width: 0, height: 100).needsVideo, isFalse);
      expect(
        const TileDemand(width: double.infinity, height: 100).needsVideo,
        isFalse,
      );
    });
  });

  group('SimulcastLayerPolicy', () {
    const policy = SimulcastLayerPolicy();
    final ladder = SimulcastLadder.h720;

    String? pick(double w, double h, {String? current, bool visible = true}) =>
        policy
            .choose(
              TileDemand(width: w, height: h, visible: visible),
              ladder,
              currentRid: current,
            )
            .rid;

    test('maps tile sizes to layers', () {
      expect(pick(1920, 1080), 'a'); // Full-screen stage.
      expect(pick(1280, 720), 'a');
      expect(pick(960, 540), 'b'); // 2×2 gallery on a 1080p screen.
      expect(pick(640, 360), 'b');
      expect(pick(480, 270), 'c');
      expect(pick(320, 180), 'c');
      expect(pick(160, 90), 'c'); // Thumbnail.
      expect(pick(961, 541), 'a');
    });

    test('uses physical pixels, so high-DPI screens pull more', () {
      final logical = const Size(320, 180);
      expect(
        policy.choose(TileDemand.fromLogicalSize(logical, 1), ladder).rid,
        'c',
      );
      expect(
        policy.choose(TileDemand.fromLogicalSize(logical, 3), ladder).rid,
        'b',
      );
    });

    test('a wide tile needs the lines its width implies', () {
      // 1280 wide at 16:9 is 720 lines, even in a 200-pixel-high strip.
      expect(pick(1280, 200), 'a');
      // A tall portrait tile is driven by its height.
      expect(pick(300, 700), 'a');
    });

    test('hidden or empty tiles are paused', () {
      expect(
        policy.choose(TileDemand.hidden, ladder),
        const LayerPreference.paused(),
      );
      expect(pick(1280, 720, visible: false), isNull);
      expect(pick(0, 0), isNull);
    });

    test('upgrades immediately', () {
      expect(pick(960, 541, current: 'b'), 'a');
      expect(pick(640, 300, current: 'c'), 'b');
    });

    test('downgrades only past the hysteresis band', () {
      // The switch-up point for a is above 540 lines; the band reaches down
      // to 459 (540 × 0.85).
      expect(pick(960, 540, current: 'a'), 'a');
      expect(pick(890, 500, current: 'a'), 'a');
      expect(pick(800, 450, current: 'a'), 'b');
      expect(pick(400, 240, current: 'b'), 'b'); // c's band ends at 229.5.
      expect(pick(400, 225, current: 'b'), 'c');
      // A big drop skips layers.
      expect(pick(160, 90, current: 'a'), 'c');
    });

    test('a resize that wobbles around a boundary does not churn', () {
      String? current;
      final picks = <String?>[];
      for (final h in const <double>[545, 535, 545, 530, 541, 520]) {
        current = pick(h * 16 / 9, h, current: current);
        picks.add(current);
      }
      expect(picks, ['a', 'a', 'a', 'a', 'a', 'a']);
    });

    test('an unknown current layer is ignored', () {
      expect(pick(640, 360, current: 'z'), 'b');
    });

    test('never asks for a layer the publisher does not send', () {
      final h360 = SimulcastLadder.fromPreset(VideoPreset.h360); // a, b.
      expect(
        policy.choose(const TileDemand(width: 160, height: 90), h360).rid,
        'b',
      );
      expect(
        policy.choose(const TileDemand(width: 1920, height: 1080), h360).rid,
        'a',
      );
      final single = SimulcastLadder.fromPreset(VideoPreset.h180);
      expect(
        policy.choose(const TileDemand(width: 10, height: 10), single).rid,
        'a',
      );
    });

    test('maxUpscale 1 never upscales', () {
      const strict = SimulcastLayerPolicy(
        LayerSelectionOptions(maxUpscale: 1.0),
      );
      expect(
        strict.choose(const TileDemand(width: 640, height: 361), ladder).rid,
        'a',
      );
      expect(
        strict.choose(const TileDemand(width: 640, height: 360), ladder).rid,
        'b',
      );
    });

    test('builds the simulcast request object', () {
      final config = policy.simulcastConfig('b');
      expect(config.preferredRid, 'b');
      expect(config.ridNotAvailable, SimulcastOrdering.asciibetical);
      expect(config.priorityOrdering, isNull);
      expect(config.toJson(), {
        'preferredRid': 'b',
        'ridNotAvailable': 'asciibetical',
      });

      const bandwidthAware = SimulcastLayerPolicy(
        LayerSelectionOptions(priorityOrdering: SimulcastOrdering.asciibetical),
      );
      expect(bandwidthAware.simulcastConfig('a').toJson(), {
        'preferredRid': 'a',
        'priorityOrdering': 'asciibetical',
        'ridNotAvailable': 'asciibetical',
      });
    });
  });

  test('LayerSelectionOptions defaults', () {
    const config = LayerSelectionOptions();
    expect(config.maxUpscale, 1.5);
    expect(config.downgradeHysteresis, 0.15);
    expect(config.debounce, const Duration(milliseconds: 300));
    expect(config.ridNotAvailable, SimulcastOrdering.asciibetical);
    expect(config.priorityOrdering, isNull);
    expect(config, const LayerSelectionOptions());
  });

  test('LayerPreference', () {
    expect(const LayerPreference.rid('a').isPaused, isFalse);
    expect(const LayerPreference.paused().isPaused, isTrue);
    expect(const LayerPreference.rid('a'), const LayerPreference.rid('a'));
    expect(
      const LayerPreference.rid('a'),
      isNot(const LayerPreference.paused()),
    );
  });
}
