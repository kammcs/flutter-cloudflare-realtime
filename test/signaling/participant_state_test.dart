import 'dart:convert';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const camera = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);
  const mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);

  group('TrackInfo', () {
    test('value equality', () {
      expect(
        const TrackInfo(kind: TrackKind.video, source: TrackSource.camera),
        camera,
      );
      expect(camera.hashCode, camera.copyWith().hashCode);
      expect(camera, isNot(mic));
      expect(camera, isNot(camera.copyWith(source: TrackSource.screen)));
    });

    test('copyWith replaces fields', () {
      expect(
        camera.copyWith(kind: TrackKind.audio, source: TrackSource.screenAudio),
        const TrackInfo(kind: TrackKind.audio, source: TrackSource.screenAudio),
      );
    });

    test('toJson uses enum names', () {
      expect(camera.toJson(), {'kind': 'video', 'source': 'camera'});
      expect(
        const TrackInfo(
          kind: TrackKind.audio,
          source: TrackSource.screenAudio,
        ).toJson(),
        {'kind': 'audio', 'source': 'screenAudio'},
      );
    });

    test('round-trips every kind and source', () {
      for (final kind in TrackKind.values) {
        for (final source in TrackSource.values) {
          final info = TrackInfo(kind: kind, source: source);
          expect(TrackInfo.fromJson(info.toJson()), info);
        }
      }
    });

    test('muted is omitted when false and read back', () {
      final muted = mic.copyWith(muted: true);
      expect(mic.muted, isFalse);
      expect(mic.toJson(), isNot(contains('muted')));
      expect(muted.toJson(), {
        'kind': 'audio',
        'source': 'microphone',
        'muted': true,
      });
      expect(TrackInfo.fromJson(muted.toJson()), muted);
      expect(muted, isNot(mic));
      expect(muted.copyWith(muted: false), mic);
      expect(muted.toString(), contains('muted'));
    });

    test('muted is optional and read tolerantly (older peers)', () {
      expect(
        TrackInfo.fromJson({'kind': 'audio', 'source': 'microphone'}).muted,
        isFalse,
      );
      expect(
        TrackInfo.fromJson({
          'kind': 'audio',
          'source': 'microphone',
          'muted': 'yes',
        }).muted,
        isFalse,
      );
    });

    test('simulcast round-trips and is omitted when null', () {
      final info = camera.copyWith(
        simulcast: SimulcastInfo(
          rids: const ['a', 'b', 'c'],
          width: 1280,
          height: 720,
          scaleDownBy: const [1, 2, 4],
        ),
      );
      expect(camera.toJson(), isNot(contains('simulcast')));
      expect(info.toJson(), {
        'kind': 'video',
        'source': 'camera',
        'simulcast': {
          'rids': ['a', 'b', 'c'],
          'width': 1280,
          'height': 720,
          'scaleDownBy': [1, 2, 4],
        },
      });
      // Through a JSON string, as an adapter would carry it.
      final decoded = jsonDecode(jsonEncode(info.toJson()));
      expect(TrackInfo.fromJson(decoded as Map<String, Object?>), info);
      expect(info.copyWith(clearSimulcast: true), camera);
      expect(info.hashCode, info.copyWith().hashCode);
    });

    test('a malformed simulcast hint is ignored, not an error', () {
      TrackInfo parse(Object? simulcast) => TrackInfo.fromJson({
        'kind': 'video',
        'source': 'camera',
        'simulcast': simulcast,
      });
      expect(parse('abc').simulcast, isNull);
      expect(parse({'rids': []}).simulcast, isNull);
      expect(
        parse({
          'rids': ['a', 1],
        }).simulcast,
        isNull,
      );
      final partial = parse({
        'rids': ['a', 'b'],
        'height': 'tall',
        'width': -3,
        'scaleDownBy': [1],
      }).simulcast!;
      expect(partial.rids, ['a', 'b']);
      expect(partial.width, isNull);
      expect(partial.height, isNull);
      expect(partial.scaleDownBy, isNull);
      expect(
        parse({
          'rids': ['a'],
          'height': 360.4,
        }).simulcast,
        SimulcastInfo(rids: const ['a'], height: 360),
      );
    });

    test('an unknown source reads as custom', () {
      expect(
        TrackInfo.fromJson({'kind': 'video', 'source': 'hologram'}),
        const TrackInfo(kind: TrackKind.video, source: TrackSource.custom),
      );
    });

    test('rejects malformed input', () {
      expect(
        () => TrackInfo.fromJson({'kind': 'smell', 'source': 'camera'}),
        throwsFormatException,
      );
      expect(
        () => TrackInfo.fromJson({'source': 'camera'}),
        throwsFormatException,
      );
      expect(
        () => TrackInfo.fromJson({'kind': 'video'}),
        throwsFormatException,
      );
      expect(
        () => TrackInfo.fromJson({'kind': 1, 'source': 'camera'}),
        throwsFormatException,
      );
    });
  });

  group('ParticipantState', () {
    final full = ParticipantState(
      participantId: 'alice',
      sessionId: 'session-1',
      tracks: const {'cam': camera, 'mic': mic},
      metadata: const {
        'displayName': 'Alice',
        'roles': ['host'],
        'prefs': {'theme': 'dark'},
      },
    );

    test('defaults: no session, no tracks, no metadata', () {
      final state = ParticipantState(participantId: 'bob');
      expect(state.sessionId, isNull);
      expect(state.tracks, isEmpty);
      expect(state.metadata, isNull);
    });

    test('value equality, including nested metadata', () {
      final copy = ParticipantState(
        participantId: 'alice',
        sessionId: 'session-1',
        tracks: {'mic': mic, 'cam': camera},
        metadata: {
          'displayName': 'Alice',
          'roles': ['host'],
          'prefs': {'theme': 'dark'},
        },
      );
      expect(copy, full);
      expect(copy.hashCode, full.hashCode);
    });

    test('differs when any field differs', () {
      expect(full.copyWith(participantId: 'bob'), isNot(full));
      expect(full.copyWith(sessionId: 'session-2'), isNot(full));
      expect(full.copyWith(clearSessionId: true), isNot(full));
      expect(full.copyWith(tracks: {'cam': camera}), isNot(full));
      expect(
        full.copyWith(
          tracks: {
            'cam': camera.copyWith(source: TrackSource.screen),
            'mic': mic,
          },
        ),
        isNot(full),
      );
      expect(
        full.copyWith(
          tracks: {'cam': camera, 'mic': mic.copyWith(muted: true)},
        ),
        isNot(full),
      );
      expect(
        full.copyWith(
          metadata: {
            'displayName': 'Alice',
            'roles': ['guest'],
            'prefs': {'theme': 'dark'},
          },
        ),
        isNot(full),
      );
      expect(full.copyWith(clearMetadata: true), isNot(full));
    });

    test('copyWith keeps unspecified fields', () {
      expect(full.copyWith(), full);
      final moved = full.copyWith(sessionId: 'session-2');
      expect(moved.sessionId, 'session-2');
      expect(moved.participantId, 'alice');
      expect(moved.tracks, full.tracks);
      expect(moved.metadata, full.metadata);
    });

    test('copyWith can clear nullable fields', () {
      final cleared = full.copyWith(clearSessionId: true, clearMetadata: true);
      expect(cleared.sessionId, isNull);
      expect(cleared.metadata, isNull);
      expect(cleared.tracks, full.tracks);
    });

    test('clear flags win over new values', () {
      final cleared = full.copyWith(
        sessionId: 'x',
        clearSessionId: true,
        metadata: {'a': 1},
        clearMetadata: true,
      );
      expect(cleared.sessionId, isNull);
      expect(cleared.metadata, isNull);
    });

    test('maps are unmodifiable copies', () {
      final tracks = {'cam': camera};
      final metadata = <String, Object?>{'a': 1};
      final state = ParticipantState(
        participantId: 'p',
        tracks: tracks,
        metadata: metadata,
      );
      tracks['mic'] = mic;
      metadata['b'] = 2;
      expect(state.tracks.keys, ['cam']);
      expect(state.metadata, {'a': 1});
      expect(() => state.tracks['mic'] = mic, throwsUnsupportedError);
      expect(() => state.metadata!['b'] = 2, throwsUnsupportedError);
    });

    test('toJson produces the documented wire shape', () {
      expect(full.toJson(), {
        'participantId': 'alice',
        'sessionId': 'session-1',
        'tracks': {
          'cam': {'kind': 'video', 'source': 'camera'},
          'mic': {'kind': 'audio', 'source': 'microphone'},
        },
        'metadata': {
          'displayName': 'Alice',
          'roles': ['host'],
          'prefs': {'theme': 'dark'},
        },
      });
    });

    test('toJson keeps a null sessionId and omits null metadata', () {
      expect(ParticipantState(participantId: 'bob').toJson(), {
        'participantId': 'bob',
        'sessionId': null,
        'tracks': <String, Object?>{},
      });
    });

    test('round-trips through a JSON string', () {
      for (final state in [
        full,
        ParticipantState(participantId: 'bob'),
        full.copyWith(clearSessionId: true, tracks: {}),
      ]) {
        final decoded = jsonDecode(jsonEncode(state.toJson()));
        expect(
          ParticipantState.fromJson(decoded as Map<String, Object?>),
          state,
        );
      }
    });

    test('fromJson ignores unknown keys', () {
      expect(
        ParticipantState.fromJson({
          'participantId': 'bob',
          'sessionId': null,
          'tracks': <String, Object?>{},
          'futureField': 42,
        }),
        ParticipantState(participantId: 'bob'),
      );
    });

    test('fromJson accepts untyped maps, as jsonDecode returns them', () {
      final Map<String, Object?> json = {
        'participantId': 'bob',
        'tracks': <dynamic, dynamic>{
          'cam': <dynamic, dynamic>{'kind': 'video', 'source': 'camera'},
        },
        'metadata': <dynamic, dynamic>{'n': 1},
      };
      expect(
        ParticipantState.fromJson(json),
        ParticipantState(
          participantId: 'bob',
          tracks: const {'cam': camera},
          metadata: const {'n': 1},
        ),
      );
    });

    test('fromJson rejects malformed input', () {
      Map<String, Object?> valid() => {
        'participantId': 'bob',
        'sessionId': 's',
        'tracks': <String, Object?>{},
      };
      final bad = <Map<String, Object?>>[
        valid()..remove('participantId'),
        valid()..['participantId'] = 7,
        valid()..['sessionId'] = 7,
        valid()..remove('tracks'),
        valid()..['tracks'] = ['cam'],
        valid()..['tracks'] = {'cam': 'video'},
        valid()
          ..['tracks'] = {
            'cam': {'kind': 'smell', 'source': 'camera'},
          },
        valid()
          ..['tracks'] = {
            1: {'kind': 'video', 'source': 'camera'},
          },
        valid()..['metadata'] = 'x',
        valid()..['metadata'] = {1: 'x'},
      ];
      for (final json in bad) {
        expect(
          () => ParticipantState.fromJson(json),
          throwsFormatException,
          reason: '$json',
        );
      }
    });

    test('toString names the participant', () {
      expect(full.toString(), contains('alice'));
    });
  });
}
