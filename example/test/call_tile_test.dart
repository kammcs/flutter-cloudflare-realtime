import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/call_tile.dart';
import 'package:cloudflare_realtime_example/device_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for a ParticipantVideoView: counts how often it is created
/// (each creation would be a new renderer, bound again: a blank frame).
class _VideoProbe extends StatefulWidget {
  const _VideoProbe(this.counts);

  final _Counts counts;

  @override
  State<_VideoProbe> createState() => _VideoProbeState();
}

class _Counts {
  int created = 0;
  int disposed = 0;
}

class _VideoProbeState extends State<_VideoProbe> {
  @override
  void initState() {
    super.initState();
    widget.counts.created++;
  }

  @override
  void dispose() {
    widget.counts.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const ColoredBox(color: Colors.black);
}

void main() {
  late StreamController<bool> speaking;
  late _Counts counts;

  setUp(() {
    // Synchronous, so each event is in the next frame.
    speaking = StreamController<bool>.broadcast(sync: true);
    counts = _Counts();
  });

  tearDown(() => speaking.close());

  CallTileData data() => CallTileData(
    id: 'ada',
    label: 'Ada',
    participantId: 'ada',
    speaking: speaking.stream,
    video: _VideoProbe(counts),
  );

  Widget frame(Widget child) => MaterialApp(
    home: Center(child: SizedBox(width: 320, height: 180, child: child)),
  );

  testWidgets('the video is created once, whatever the highlight does', (
    tester,
  ) async {
    await tester.pumpWidget(frame(CallTile(data: data())));
    expect(counts.created, 1);

    // Speaking on and off (the active-speaker events), as during a call.
    for (var i = 0; i < 4; i++) {
      speaking.add(true);
      await tester.pump();
      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
      speaking.add(false);
      await tester.pump();
      expect(find.byIcon(Icons.graphic_eq), findsNothing);
    }
    // Becoming the dominant speaker, the stats overlay, a thumbnail.
    await tester.pumpWidget(frame(CallTile(data: data(), dominant: true)));
    speaking.add(true);
    await tester.pump();
    await tester.pumpWidget(
      frame(CallTile(data: data(), showStats: true, pinned: true)),
    );
    await tester.pumpWidget(frame(CallTile(data: data(), compact: true)));

    expect(counts.created, 1, reason: 'no new video view, so no new renderer');
    expect(counts.disposed, 0);
  });

  testWidgets('a tile with a global key keeps its video when it moves to '
      'another layout', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      frame(
        GridView.extent(
          maxCrossAxisExtent: 320,
          children: [CallTile(key: key, data: data())],
        ),
      ),
    );
    // The stage layout: the same tile, elsewhere in the tree.
    await tester.pumpWidget(
      frame(
        Column(
          children: [
            Expanded(
              child: GestureDetector(
                child: CallTile(key: key, data: data()),
              ),
            ),
          ],
        ),
      ),
    );
    expect(counts.created, 1);
    expect(counts.disposed, 0);
  });

  test('deviceLabel marks the system default once', () {
    const sonar = MediaDevice(
      deviceId: '{0.0.1.00000000}.{1013}',
      kind: MediaDeviceKind.audioInput,
      label: 'Sonar - Microphone',
      isDefault: true,
    );
    expect(deviceLabel(sonar, 0), 'Sonar - Microphone (system default)');
    const chromeDefault = MediaDevice(
      deviceId: 'default',
      kind: MediaDeviceKind.audioInput,
      label: 'Default - Headset',
      isDefault: true,
    );
    expect(deviceLabel(chromeDefault, 0), 'Default - Headset');
    const unnamed = MediaDevice(deviceId: '', kind: MediaDeviceKind.audioInput);
    expect(deviceLabel(unnamed, 1), 'Device 2');
  });

  test('the level meter spans -60 to 0 dBFS', () {
    expect(MicLevelMeter.fill(0), 0);
    expect(MicLevelMeter.fill(1), 1);
    expect(MicLevelMeter.fill(0.1), closeTo(2 / 3, 0.001)); // -20 dBFS
    expect(MicLevelMeter.fill(0.01), closeTo(1 / 3, 0.001)); // -40 dBFS
  });
}
