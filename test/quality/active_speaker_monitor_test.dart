import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/quality/active_speaker_monitor.dart';
import 'package:cloudflare_realtime/src/quality/audio_level_source.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// Returns [levels], or waits on [gate] when set, or throws [error].
class _FakeSource implements AudioLevelSource {
  Map<String, double> levels = {};
  Completer<void>? gate;
  Object? error;
  int calls = 0;

  @override
  Future<Map<String, double>> getAudioLevels() async {
    calls++;
    final g = gate;
    if (g != null) await g.future;
    if (error case final e?) throw e;
    return Map.of(levels);
  }
}

const _config = ActiveSpeakerOptions(smoothingTimeConstant: Duration.zero);
const _tick = Duration(milliseconds: 250);

void main() {
  test('polls on the interval and publishes speakers', () {
    fakeAsync((async) {
      final source = _FakeSource()..levels = {'a': 0.3, 'me': 0.0};
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        localParticipantId: 'me',
        clock: () => async.elapsed,
      );
      final speakers = <List<String>>[];
      final dominant = <String?>[];
      monitor.speakers.listen(speakers.add);
      monitor.dominantSpeaker.listen(dominant.add);

      monitor.start();
      expect(monitor.isRunning, isTrue);
      async.elapse(_tick);
      expect(source.calls, 1);
      expect(monitor.currentSpeakers, isEmpty);
      async.elapse(_tick);
      expect(source.calls, 2);
      expect(monitor.currentSpeakers, ['a']);
      expect(monitor.currentDominantSpeaker, 'a');

      async.elapse(_tick * 4); // Same state: no repeats.
      expect(speakers, [
        <String>[],
        ['a'],
      ]);
      expect(dominant, [null, 'a']);

      unawaited(monitor.dispose());
      async.flushMicrotasks();
    });
  });

  test('skips a tick while a poll is still running', () {
    fakeAsync((async) {
      final source = _FakeSource()..gate = Completer<void>();
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        clock: () => async.elapsed,
      )..start();
      async.elapse(_tick * 4);
      expect(source.calls, 1);
      source.gate!.complete();
      source.gate = null;
      async.flushMicrotasks();
      async.elapse(_tick);
      expect(source.calls, 2);
      unawaited(monitor.dispose());
      async.flushMicrotasks();
    });
  });

  test('a failing poll is skipped, and polling goes on', () {
    fakeAsync((async) {
      final source = _FakeSource()
        ..levels = {'a': 0.3}
        ..error = StateError('pc closed');
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        clock: () => async.elapsed,
      )..start();
      async.elapse(_tick * 3);
      expect(source.calls, 3);
      expect(monitor.currentSpeakers, isEmpty);
      source.error = null;
      async.elapse(_tick * 2);
      expect(monitor.currentSpeakers, ['a']);
      unawaited(monitor.dispose());
      async.flushMicrotasks();
    });
  });

  test('the muted hint follows localMuted', () {
    fakeAsync((async) {
      final source = _FakeSource()..levels = {'me': 0.3};
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        localParticipantId: 'me',
        clock: () => async.elapsed,
      );
      final hints = <bool>[];
      monitor.localSpeakingWhileMuted.listen(hints.add);
      monitor
        ..localMuted = true
        ..start();
      expect(monitor.localMuted, isTrue);
      async.elapse(_tick * 3);
      expect(monitor.currentSpeakers, isEmpty);
      expect(monitor.snapshot.localSpeakingWhileMuted, isTrue);
      monitor.localMuted = false;
      async.elapse(_tick * 2);
      expect(monitor.currentSpeakers, ['me']);
      expect(hints, [false, true, false]);
      unawaited(monitor.dispose());
      async.flushMicrotasks();
    });
  });

  test('stop clears the outputs; start resumes', () {
    fakeAsync((async) {
      final source = _FakeSource()..levels = {'a': 0.3};
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        clock: () => async.elapsed,
      )..start();
      async.elapse(_tick * 2);
      expect(monitor.currentSpeakers, ['a']);
      monitor.stop();
      expect(monitor.isRunning, isFalse);
      expect(monitor.currentSpeakers, isEmpty);
      expect(monitor.currentDominantSpeaker, isNull);
      final calls = source.calls;
      async.elapse(_tick * 4);
      expect(source.calls, calls);
      monitor.start();
      async.elapse(_tick * 2);
      expect(monitor.currentSpeakers, ['a']);
      unawaited(monitor.dispose());
      async.flushMicrotasks();
    });
  });

  test('removeParticipant forwards to the detector', () {
    fakeAsync((async) {
      final source = _FakeSource()..levels = {'a': 0.3};
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        clock: () => async.elapsed,
      )..start();
      async.elapse(_tick * 2);
      expect(monitor.currentDominantSpeaker, 'a');
      source.levels = {};
      monitor.removeParticipant('a');
      async.elapse(_tick);
      expect(monitor.currentSpeakers, isEmpty);
      expect(monitor.currentDominantSpeaker, isNull);
      unawaited(monitor.dispose());
      async.flushMicrotasks();
    });
  });

  test('dispose stops polling', () {
    fakeAsync((async) {
      final source = _FakeSource();
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        clock: () => async.elapsed,
      )..start();
      unawaited(monitor.dispose());
      async.flushMicrotasks();
      expect(monitor.isRunning, isFalse);
      async.elapse(_tick * 4);
      expect(source.calls, 0);
      monitor.start(); // No effect after dispose.
      expect(monitor.isRunning, isFalse);
    });
  });

  // Real async: fake_async doesn't deliver Stream.multi done events.
  test('dispose closes the streams', () async {
    final monitor = ActiveSpeakerMonitor(source: _FakeSource());
    final done = [
      monitor.speakers.drain<void>(),
      monitor.dominantSpeaker.drain<void>(),
      monitor.localSpeakingWhileMuted.drain<void>(),
      monitor.snapshots.drain<void>(),
    ];
    await monitor.dispose();
    await Future.wait(done);
  });

  test('a poll that finishes after dispose is dropped', () {
    fakeAsync((async) {
      final source = _FakeSource()
        ..levels = {'a': 0.3}
        ..gate = Completer<void>();
      final monitor = ActiveSpeakerMonitor(
        source: source,
        config: _config,
        clock: () => async.elapsed,
      )..start();
      async.elapse(_tick);
      unawaited(monitor.dispose());
      source.gate!.complete();
      async.flushMicrotasks(); // Would throw if it set a closed StateStream.
      expect(monitor.currentSpeakers, isEmpty);
    });
  });
}
