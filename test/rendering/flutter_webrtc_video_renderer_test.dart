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

  test('detaches the stream, then releases the renderer at once', () async {
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
    // No wait since flutter_webrtc 1.6.2+hotfix.4 (docs/design.md §4.3,
    // Releasing a native renderer).
    expect(release.$3 - detach.$3, lessThan(const Duration(milliseconds: 200)));
  });

  test('releases a renderer that never showed a stream at once, with no '
      'detach', () async {
    final renderer = FlutterWebrtcVideoRenderer();
    await renderer.initialize();
    await renderer.setStream(null);
    final start = clock.elapsed;
    await renderer.dispose();
    expect(rendererCalls(), ['videoRendererDispose']);
    final release = calls.firstWhere((c) => c.$1 == 'videoRendererDispose');
    expect(release.$3 - start, lessThan(const Duration(milliseconds: 200)));
  });

  // Each videoRendererSetSrcObject blocks the platform thread on Darwin
  // (docs/design.md §4.3, Rendering).
  test('sets nothing the native renderer already has', () async {
    final renderer = FlutterWebrtcVideoRenderer();
    await renderer.initialize();
    final stream = _FakeStream();
    await renderer.setStream(stream);
    await renderer.setStream(stream);
    await pumpEventQueue();
    expect(rendererCalls(), ['videoRendererSetSrcObject']);

    await renderer.setStream(null);
    await renderer.setStream(null);
    expect(rendererCalls(), [
      'videoRendererSetSrcObject',
      'videoRendererSetSrcObject',
    ]);
    // Detached already: dispose doesn't detach again.
    await renderer.dispose();
    expect(rendererCalls(), [
      'videoRendererSetSrcObject',
      'videoRendererSetSrcObject',
      'videoRendererDispose',
    ]);
  });

  test('releases a renderer detached just now at once', () async {
    final renderer = FlutterWebrtcVideoRenderer();
    await renderer.initialize();
    await renderer.setStream(_FakeStream());
    await renderer.setStream(null);
    final detach = calls.lastWhere((c) => c.$1 == 'videoRendererSetSrcObject');
    await renderer.dispose();
    final release = calls.lastWhere((c) => c.$1 == 'videoRendererDispose');
    expect(release.$3 - detach.$3, lessThan(const Duration(milliseconds: 200)));
  });

  test('releases an uninitialized renderer without native calls', () async {
    await FlutterWebrtcVideoRenderer().dispose();
    expect(rendererCalls(), isEmpty);
  });
}
