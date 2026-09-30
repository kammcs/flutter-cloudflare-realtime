import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/audio/remote_audio_sink.dart';
import 'package:cloudflare_realtime/src/audio/remote_audio_sink_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStreamTrack;

import '../support/room_harness.dart';

const _mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);
const _cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);

Future<void> _settle() => pumpEventQueue(times: 50);

/// Records what the room asks of its sink, and lets the test play the
/// browser (blocking playback, then allowing it).
class _FakeAudioSink implements RemoteAudioSink {
  _FakeAudioSink(this.onBlockedChanged);

  final AudioBlockedListener onBlockedChanged;

  /// What plays now, by publication ID.
  final Map<String, MediaStreamTrack> playing = {};

  /// `attach(id)` and `detach(id)` calls, in order.
  final List<String> calls = [];

  /// Whether `play()` is refused, like a browser before a user gesture.
  bool refuse = false;
  bool _blocked = false;
  int resumes = 0;
  String? outputDevice;
  bool disposed = false;

  @override
  void attach(String id, MediaStreamTrack track) {
    calls.add('attach($id)');
    playing[id] = track;
    if (refuse) _setBlocked(true);
  }

  @override
  void detach(String id) {
    calls.add('detach($id)');
    playing.remove(id);
    if (playing.isEmpty) _setBlocked(false);
  }

  @override
  Future<bool> resume() async {
    resumes++;
    refuse = false;
    _setBlocked(false);
    return true;
  }

  @override
  bool get supportsOutputSelection => true;

  @override
  Future<void> setOutputDevice(String deviceId) async =>
      outputDevice = deviceId;

  @override
  void dispose() {
    disposed = true;
    playing.clear();
  }

  void _setBlocked(bool blocked) {
    if (blocked == _blocked) return;
    _blocked = blocked;
    onBlockedChanged(blocked);
  }
}

void main() {
  late RoomHarness h;
  late List<_FakeAudioSink> sinks;

  setUp(() {
    h = RoomHarness();
    sinks = [];
    debugRemoteAudioSinkFactory = (onBlockedChanged) {
      final sink = _FakeAudioSink(onBlockedChanged);
      sinks.add(sink);
      return sink;
    };
  });

  tearDown(() => debugRemoteAudioSinkFactory = null);

  /// Joins `dave`, a signaling-only publisher, with [tracks] on [sessionId].
  Future<InMemorySignaling> joinDave(
    String sessionId,
    Map<String, TrackInfo> tracks,
  ) async {
    for (final MapEntry(key: name, value: info) in tracks.entries) {
      h.broker.trackKinds['$sessionId/$name'] = info.kind.name;
    }
    final dave = InMemorySignaling(h.hub);
    await dave.join(
      'room',
      ParticipantState(
        participantId: 'dave',
        sessionId: sessionId,
        tracks: tracks,
      ),
    );
    return dave;
  }

  test('plays each pulled audio track, never video, and stops it on '
      'unsubscribe, unpublish and leave', () async {
    final alice = await h.join('alice');
    final dave = await joinDave('dave-1', {
      'dave-mic': _mic,
      'dave-screen-audio': const TrackInfo(
        kind: TrackKind.audio,
        source: TrackSource.screenAudio,
      ),
      'dave-cam': _cam,
    });
    await _settle();
    final sink = sinks.single;
    final daveP = alice.participant('dave')!;
    await daveP.camera!.subscribe();
    await _settle();

    final mic = daveP.microphone!;
    final screenAudio = daveP.screenAudio!;
    expect(sink.playing.keys, unorderedEquals([mic.id, screenAudio.id]));
    expect(sink.playing[mic.id], same(mic.currentTrack!.track));

    await mic.unsubscribe();
    await _settle();
    expect(sink.playing.keys, [screenAudio.id]);
    await mic.subscribe();
    await _settle();
    expect(sink.playing[mic.id], same(mic.currentTrack!.track));

    // Unpublished: its audio stops.
    await dave.update(
      ParticipantState(
        participantId: 'dave',
        sessionId: 'dave-1',
        tracks: const {'dave-mic': _mic, 'dave-cam': _cam},
      ),
    );
    await _settle();
    expect(sink.playing.keys, [mic.id]);

    await alice.leave();
    expect(sink.disposed, isTrue);
    expect(sink.playing, isEmpty);
    expect(alice.audioPlaybackBlocked, isFalse);
    dave.dispose();
  });

  test('a publisher on a new session: the new track replaces the old one '
      'under the same ID', () async {
    final alice = await h.join('alice');
    final dave = await joinDave('dave-1', {'dave-mic': _mic});
    await _settle();
    final sink = sinks.single;
    final mic = alice.participant('dave')!.microphone!;
    final first = sink.playing[mic.id];
    expect(first, isNotNull);

    h.broker.trackKinds['dave-2/dave-mic'] = 'audio';
    await dave.update(
      ParticipantState(
        participantId: 'dave',
        sessionId: 'dave-2',
        tracks: const {'dave-mic': _mic},
      ),
    );
    await _settle();
    expect(sink.playing[mic.id], same(mic.currentTrack!.track));
    expect(sink.playing[mic.id], isNot(same(first)));
    await alice.leave();
    dave.dispose();
  });

  test('blocked playback is reported until startAudio()', () async {
    final alice = await h.join('alice');
    final states = <bool>[];
    alice.audioPlaybackBlockedChanges.listen(states.add);
    final sink = sinks.single..refuse = true;

    final dave = await joinDave('dave-1', {'dave-mic': _mic});
    await _settle();
    expect(alice.audioPlaybackBlocked, isTrue);

    expect(await alice.startAudio(), isTrue);
    expect(sink.resumes, 1);
    expect(alice.audioPlaybackBlocked, isFalse);
    await _settle();
    expect(states, [false, true, false]);

    await alice.leave();
    await _settle();
    expect(await alice.startAudio(), isTrue, reason: 'no-op after leave');
    dave.dispose();
  });

  test('audio output selection goes to the sink', () async {
    final alice = await h.join('alice');
    expect(alice.canSelectAudioOutput, isTrue);
    await alice.setAudioOutputDevice('speaker-2');
    expect(sinks.single.outputDevice, 'speaker-2');
    await alice.leave();
    expect(() => alice.setAudioOutputDevice('x'), throwsStateError);
  });

  test('the native sink plays nothing itself and is never blocked', () async {
    debugRemoteAudioSinkFactory = null;
    const sink = NativeRemoteAudioSink();
    sink
      ..attach('p/t', FakeMediaStreamTrack(kind: 'audio'))
      ..detach('p/t');
    expect(await sink.resume(), isTrue);

    final alice = await h.join('alice');
    final dave = await joinDave('dave-1', {'dave-mic': _mic});
    await _settle();
    expect(alice.audioPlaybackBlocked, isFalse);
    expect(await alice.startAudio(), isTrue);
    await alice.leave();
    dave.dispose();
  });
}
