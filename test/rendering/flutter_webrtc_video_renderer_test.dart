import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

class _FakeStream implements MediaStream {
  @override
  String get id => 'stream-1';

  @override
  String get ownerTag => 'local';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const plugin = MethodChannel('FlutterWebRTC.Method');
  const texture = MethodChannel('FlutterWebRTC/Texture7');

  late List<(String, Object?, Duration)> calls;
  late Stopwatch clock;

  setUp(() {
    calls = [];
    clock = Stopwatch()..start();
    messenger.setMockMethodCallHandler(plugin, (call) async {
      calls.add((call.method, call.arguments, clock.elapsed));
      return switch (call.method) {
        'createVideoRenderer' => {'textureId': 7},
        _ => null,
      };
    });
    messenger.setMockMethodCallHandler(texture, (_) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(plugin, null);
    messenger.setMockMethodCallHandler(texture, null);
  });

  List<String> rendererCalls() => [
    for (final (method, _, _) in calls)
      if (method.startsWith('videoRenderer')) method,
  ];

  test('detaches the stream, waits, then releases the renderer', () async {
    final renderer = FlutterWebrtcVideoRenderer();
    await renderer.initialize();
    await renderer.setStream(_FakeStream());
    await pumpEventQueue();
    await renderer.dispose();

    expect(rendererCalls(), [
      'videoRendererSetSrcObject',
      'videoRendererSetSrcObject',
      'videoRendererDispose',
    ]);
    final detach = calls.lastWhere((c) => c.$1 == 'videoRendererSetSrcObject');
    expect((detach.$2! as Map)['streamId'], '', reason: 'no stream');
    final release = calls.lastWhere((c) => c.$1 == 'videoRendererDispose');
    // The frames' main-queue blocks run before the native renderer goes
    // (docs/design.md §4.3, Releasing a native renderer).
    expect(
      release.$3 - detach.$3,
      greaterThanOrEqualTo(const Duration(milliseconds: 200)),
    );
  });

  test('releases a renderer that never showed a stream at once', () async {
    final renderer = FlutterWebrtcVideoRenderer();
    await renderer.initialize();
    await renderer.dispose();
    expect(rendererCalls(), [
      'videoRendererSetSrcObject',
      'videoRendererDispose',
    ]);
    final detach = calls.firstWhere((c) => c.$1 == 'videoRendererSetSrcObject');
    final release = calls.firstWhere((c) => c.$1 == 'videoRendererDispose');
    expect(release.$3 - detach.$3, lessThan(const Duration(milliseconds: 200)));
  });

  test('releases an uninitialized renderer without native calls', () async {
    await FlutterWebrtcVideoRenderer().dispose();
    expect(rendererCalls(), isEmpty);
  });
}
