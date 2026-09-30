import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

class _Call {
  _Call(this.kind, this.subscriptionId, this.viewKey, [this.demand]);

  final String kind;
  final String subscriptionId;
  final Object viewKey;
  final TileDemand? demand;

  @override
  String toString() => '$kind($subscriptionId, $demand)';
}

class _RecordingReporter implements LayerDemandReporter {
  final calls = <_Call>[];

  List<TileDemand?> get demands => [
    for (final c in calls)
      if (c.kind == 'report') c.demand,
  ];

  @override
  void reportDemand(String subscriptionId, Object viewKey, TileDemand demand) {
    calls.add(_Call('report', subscriptionId, viewKey, demand));
  }

  @override
  void removeView(String subscriptionId, Object viewKey) {
    calls.add(_Call('remove', subscriptionId, viewKey));
  }
}

Widget _host({
  required LayerDemandReporter reporter,
  String subscriptionId = 'sub',
  Size size = const Size(320, 180),
  double dpr = 2,
  bool visible = true,
  bool tickers = true,
  bool show = true,
}) => MediaQuery(
  data: MediaQueryData(devicePixelRatio: dpr),
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: TickerMode(
      enabled: tickers,
      child: Center(
        child: show
            ? SizedBox.fromSize(
                size: size,
                child: SimulcastLayerReporter(
                  reporter: reporter,
                  subscriptionId: subscriptionId,
                  visible: visible,
                  child: const SizedBox.expand(),
                ),
              )
            : const SizedBox.shrink(),
      ),
    ),
  ),
);

void main() {
  late _RecordingReporter reporter;

  setUp(() => reporter = _RecordingReporter());

  testWidgets('reports the physical size after the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(_host(reporter: reporter));
    expect(reporter.demands, [const TileDemand(width: 640, height: 360)]);
    expect(reporter.calls.single.subscriptionId, 'sub');
  });

  testWidgets('re-reports on resize, but not on an unchanged rebuild', (
    tester,
  ) async {
    await tester.pumpWidget(_host(reporter: reporter));
    await tester.pumpWidget(_host(reporter: reporter));
    await tester.pump();
    expect(reporter.demands, hasLength(1));

    await tester.pumpWidget(
      _host(reporter: reporter, size: const Size(160, 90)),
    );
    expect(reporter.demands.last, const TileDemand(width: 320, height: 180));
    expect(reporter.demands, hasLength(2));
  });

  testWidgets('re-reports when the device-pixel ratio changes', (tester) async {
    await tester.pumpWidget(_host(reporter: reporter));
    await tester.pumpWidget(_host(reporter: reporter, dpr: 1));
    expect(reporter.demands.last, const TileDemand(width: 320, height: 180));
  });

  testWidgets('reports hidden when not visible', (tester) async {
    await tester.pumpWidget(_host(reporter: reporter));
    await tester.pumpWidget(_host(reporter: reporter, visible: false));
    final last = reporter.demands.last!;
    expect(last.visible, isFalse);
    expect(last.needsVideo, isFalse);
    await tester.pumpWidget(_host(reporter: reporter));
    expect(reporter.demands.last!.visible, isTrue);
  });

  testWidgets('reports hidden when tickers are off (covered route)', (
    tester,
  ) async {
    await tester.pumpWidget(_host(reporter: reporter, tickers: false));
    expect(reporter.demands.single!.visible, isFalse);
    await tester.pumpWidget(_host(reporter: reporter));
    expect(reporter.demands.last!.visible, isTrue);
  });

  testWidgets('removes its view on dispose', (tester) async {
    await tester.pumpWidget(_host(reporter: reporter));
    final key = reporter.calls.single.viewKey;
    await tester.pumpWidget(_host(reporter: reporter, show: false));
    final remove = reporter.calls.last;
    expect(remove.kind, 'remove');
    expect(remove.subscriptionId, 'sub');
    expect(remove.viewKey, same(key));
  });

  testWidgets('moves to a new subscription ID', (tester) async {
    await tester.pumpWidget(_host(reporter: reporter));
    await tester.pumpWidget(_host(reporter: reporter, subscriptionId: 'next'));
    expect(reporter.calls.map((c) => '${c.kind}:${c.subscriptionId}'), [
      'report:sub',
      'remove:sub',
      'report:next',
    ]);
  });

  testWidgets('moves to a new reporter', (tester) async {
    final other = _RecordingReporter();
    await tester.pumpWidget(_host(reporter: reporter));
    await tester.pumpWidget(_host(reporter: other));
    expect(reporter.calls.map((c) => c.kind), ['report', 'remove']);
    expect(other.demands, [const TileDemand(width: 640, height: 360)]);
  });

  testWidgets('two views of one subscription use distinct keys', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            for (final size in const [Size(100, 50), Size(200, 100)])
              SizedBox.fromSize(
                size: size,
                child: SimulcastLayerReporter(
                  reporter: reporter,
                  subscriptionId: 'sub',
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        ),
      ),
    );
    expect(reporter.calls, hasLength(2));
    expect(reporter.calls[0].viewKey, isNot(same(reporter.calls[1].viewKey)));
  });
}
