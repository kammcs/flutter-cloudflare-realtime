import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/layer_pausing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

const _abc = ['a', 'b', 'c'];

void main() {
  group('layersToSend', () {
    test('keeps the lowest layer up to the highest wish', () {
      expect(layersToSend(ladder: _abc, wishes: ['c']), {'c'});
      expect(layersToSend(ladder: _abc, wishes: ['b']), {'b', 'c'});
      expect(layersToSend(ladder: _abc, wishes: ['c', 'a']), _abc.toSet());
      expect(layersToSend(ladder: _abc, wishes: ['b', 'c', 'b']), {'b', 'c'});
    });

    test('with no wish, only the floor', () {
      expect(layersToSend(ladder: _abc, wishes: const []), {'c'});
      expect(layersToSend(ladder: _abc, wishes: const [], minActiveLayers: 2), {
        'b',
        'c',
      });
      expect(
        layersToSend(ladder: _abc, wishes: ['c'], minActiveLayers: 5),
        _abc.toSet(),
      );
    });

    test('a participant that wants everything (null) keeps every layer', () {
      expect(layersToSend(ladder: _abc, wishes: ['c', null]), _abc.toSet());
    });

    test('an unknown RID wants everything; a dropped one the lowest', () {
      expect(layersToSend(ladder: _abc, wishes: ['z']), _abc.toSet());
      // A 360p capture: the encoder sends only a and b, so c means b.
      expect(layersToSend(ladder: ['a', 'b'], wishes: ['c'], allRids: _abc), {
        'b',
      });
      expect(layersToSend(ladder: ['a', 'b'], wishes: ['c']), {'a', 'b'});
    });

    test('an empty ladder sends nothing to pause', () {
      expect(layersToSend(ladder: const [], wishes: ['a']), isEmpty);
    });
  });

  group('LayerPauser', () {
    late List<Set<String>> applied;
    LayerPauser pauser({Duration delay = const Duration(seconds: 5)}) {
      applied = [];
      return LayerPauser(
        pauseDelay: delay,
        apply: (paused) async => applied.add(paused),
      );
    }

    test('pauses an unwanted layer only after the delay', () {
      fakeAsync((async) {
        final p = pauser();
        var changes = 0;
        p.onChanged = () => changes++;
        p.update(layers: _abc.toSet(), send: {'c'});
        async.flushMicrotasks();
        expect(p.paused, isEmpty);
        expect(p.pending, {'a', 'b'});
        async.elapse(const Duration(milliseconds: 4999));
        expect(p.paused, isEmpty);
        async.elapse(const Duration(milliseconds: 1));
        expect(p.paused, {'a', 'b'});
        expect(applied, [
          {'a', 'b'},
        ]);
        expect(changes, 1);
        p.dispose();
      });
    });

    test('resumes at once when a layer is wanted again', () {
      fakeAsync((async) {
        final p = pauser();
        p.update(layers: _abc.toSet(), send: {'c'});
        async.elapse(const Duration(seconds: 5));
        p.update(layers: _abc.toSet(), send: {'b', 'c'});
        async.flushMicrotasks();
        expect(p.paused, {'a'});
        expect(applied.last, {'a'});
        p.update(layers: _abc.toSet(), send: _abc.toSet());
        async.flushMicrotasks();
        expect(p.paused, isEmpty);
        expect(applied.last, isEmpty);
        p.dispose();
      });
    });

    test('a layer wanted again within the delay is never paused', () {
      fakeAsync((async) {
        final p = pauser();
        p.update(layers: _abc.toSet(), send: {'c'});
        async.elapse(const Duration(seconds: 3));
        p.update(layers: _abc.toSet(), send: _abc.toSet());
        async.elapse(const Duration(seconds: 10));
        expect(p.paused, isEmpty);
        expect(applied, isEmpty);
        p.dispose();
      });
    });

    test('each layer waits from when it became unwanted', () {
      fakeAsync((async) {
        final p = pauser();
        p.update(layers: _abc.toSet(), send: {'b', 'c'});
        async.elapse(const Duration(seconds: 3));
        p.update(layers: _abc.toSet(), send: {'c'});
        async.elapse(const Duration(seconds: 2));
        expect(p.paused, {'a'});
        async.elapse(const Duration(seconds: 3));
        expect(p.paused, {'a', 'b'});
        p.dispose();
      });
    });

    test('resumeAll and layers that are no longer pausable', () {
      fakeAsync((async) {
        final p = pauser();
        p.update(layers: _abc.toSet(), send: {'c'});
        async.elapse(const Duration(seconds: 5));
        // The ladder shrank (a smaller capture): only b and c are known.
        p.update(layers: {'b', 'c'}, send: {'c'});
        async.flushMicrotasks();
        expect(p.paused, {'b'});
        p.resumeAll();
        async.flushMicrotasks();
        expect(p.paused, isEmpty);
        expect(applied.last, isEmpty);
        p.dispose();
      });
    });

    test('applies serially, ending on the latest set, and retries after an '
        'error on reapply', () {
      fakeAsync((async) {
        final calls = <Set<String>>[];
        var fail = true;
        final p = LayerPauser(
          pauseDelay: Duration.zero,
          apply: (paused) async {
            calls.add(paused);
            await Future<void>.delayed(const Duration(milliseconds: 10));
            if (fail) throw StateError('closed');
          },
        );
        p.update(layers: _abc.toSet(), send: {'c'});
        async.elapse(Duration.zero);
        p.update(layers: _abc.toSet(), send: {'b', 'c'});
        async.elapse(const Duration(milliseconds: 100));
        expect(calls, [
          {'a', 'b'},
          {'a'},
        ]);
        fail = false;
        p.reapply();
        async.elapse(const Duration(milliseconds: 100));
        expect(calls.last, {'a'});
        expect(calls, hasLength(3));
        p.dispose();
      });
    });

    test('does nothing after dispose', () {
      fakeAsync((async) {
        final p = pauser();
        p.update(layers: _abc.toSet(), send: {'c'});
        p.dispose();
        async.elapse(const Duration(seconds: 10));
        expect(p.paused, isEmpty);
        expect(applied, isEmpty);
      });
    });
  });

  test('LayerPausingOptions: defaults (reporting, no pausing), on, '
      'equality', () {
    const options = LayerPausingOptions();
    expect(options.enabled, isFalse);
    expect(options.reportDemand, isTrue);
    expect(options.minActiveLayers, 1);
    expect(options.pauseDelay, const Duration(seconds: 5));
    expect(LayerPausingOptions.on.enabled, isTrue);
    expect(LayerPausingOptions.on.reportDemand, isTrue);
    expect(const LayerPausingOptions(), options);
    expect(const LayerPausingOptions().hashCode, options.hashCode);
    expect(LayerPausingOptions.on, isNot(options));
    expect(options.toString(), contains('pauseDelay'));
  });

  test('VideoCodec preferences fall back to VP8', () {
    expect(VideoCodec.vp8.codecPreferences, ['video/VP8']);
    expect(VideoCodec.h264.codecPreferences, ['video/H264', 'video/VP8']);
    expect(VideoCodec.av1.codecPreferences.last, 'video/VP8');
    expect(VideoCodec.vp9.mimeType, 'video/VP9');
  });
}
