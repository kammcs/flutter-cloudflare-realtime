import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/simulcast_ladder.dart';
import 'package:cloudflare_realtime/src/room/simulcast_hint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('simulcastInfoFor', () {
    test('describes the default h720 layers, highest first', () {
      final info = simulcastInfoFor(
        SimulcastPresets.h720.reversed.toList(),
        width: 1280,
        height: 720,
      );
      expect(
        info,
        SimulcastInfo(
          rids: const ['a', 'b', 'c'],
          width: 1280,
          height: 720,
          scaleDownBy: const [1, 2, 4],
        ),
      );
    });

    test('a single encoding is not simulcast', () {
      expect(simulcastInfoFor(const []), isNull);
      expect(simulcastInfoFor(const [SendEncoding(maxBitrate: 1)]), isNull);
      expect(simulcastInfoFor(const [SendEncoding(rid: 'a')]), isNull);
    });

    test('inactive layers are left out', () {
      final info = simulcastInfoFor([
        ...SimulcastPresets.h720.take(2),
        SimulcastPresets.h720.last.copyWith(active: false),
      ]);
      expect(info!.rids, ['a', 'b']);
      expect(info.height, isNull);
    });
  });

  group('SimulcastLayer', () {
    test('maps to a/b/c, or by rank among advertised rids', () {
      expect(SimulcastLayer.high.rid, 'a');
      expect(SimulcastLayer.medium.rid, 'b');
      expect(SimulcastLayer.low.rid, 'c');
      expect(SimulcastLayer.low.ridIn(const ['a', 'b']), 'b');
      expect(SimulcastLayer.medium.ridIn(const ['a', 'b']), 'b');
      expect(SimulcastLayer.high.ridIn(const ['x', 'y', 'z']), 'x');
      expect(SimulcastLayer.medium.ridIn(const []), 'b');
    });
  });

  group('simulcastLadderFor', () {
    test('builds the publisher ladder for layer selection', () {
      final ladder = simulcastLadderFor(
        SimulcastInfo(rids: const ['a', 'b', 'c'], width: 1280, height: 720),
      );
      expect(ladder, SimulcastLadder.h720);
    });

    test('assumes 16:9 and 1/2/4 when not told, with the encoder limit', () {
      final ladder = simulcastLadderFor(
        SimulcastInfo(rids: const ['a', 'b', 'c'], height: 360),
      )!;
      // 640x360 sends two layers under libwebrtc's legacy limit.
      expect(ladder.layers, const [
        SimulcastLayerSpec(rid: 'a', width: 640, height: 360),
        SimulcastLayerSpec(rid: 'b', width: 320, height: 180),
      ]);
    });

    test('needs a size', () {
      expect(simulcastLadderFor(SimulcastInfo(rids: const ['a', 'b'])), isNull);
    });
  });
}
