import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/room/participant_diff.dart';
import 'package:flutter_test/flutter_test.dart';

const _cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);
const _mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);
const _screen = TrackInfo(kind: TrackKind.video, source: TrackSource.screen);

ParticipantState _p(
  String id, {
  String? session = 'default',
  Map<String, TrackInfo> tracks = const {},
  Map<String, Object?>? metadata,
}) => ParticipantState(
  participantId: id,
  sessionId: session == 'default' ? 's-$id' : session,
  tracks: tracks,
  metadata: metadata,
);

List<String> _ids(List<ParticipantState> states) => [
  for (final s in states) s.participantId,
];

void main() {
  test('an unchanged list is an empty diff', () {
    final list = [
      _p('a', tracks: {'cam': _cam}),
      _p('b'),
    ];
    expect(diffParticipants(list, [...list]).isEmpty, isTrue);
    expect(diffParticipants(const [], const []).isEmpty, isTrue);
  });

  test('joins and leaves, in list order', () {
    final diff = diffParticipants(
      [_p('a'), _p('b'), _p('c')],
      [_p('d'), _p('b'), _p('e')],
    );
    expect(_ids(diff.joined), ['d', 'e']);
    expect(_ids(diff.left), ['a', 'c']);
    expect(diff.updated, isEmpty);
  });

  test('ignores participants without a session', () {
    final diff = diffParticipants(
      [_p('a', session: null)],
      [_p('a', session: null), _p('b', session: null)],
    );
    expect(diff.isEmpty, isTrue);
  });

  test('getting a session is a join; losing it is a leave', () {
    final joined = diffParticipants(
      [_p('a', session: null)],
      [_p('a', session: 's1')],
    );
    expect(_ids(joined.joined), ['a']);

    final left = diffParticipants(
      [_p('a', session: 's1')],
      [_p('a', session: null)],
    );
    expect(_ids(left.left), ['a']);
    expect(left.left.single.sessionId, 's1', reason: 'the last usable state');
  });

  test('a session change is an update', () {
    final diff = diffParticipants(
      [
        _p('a', session: 's1', tracks: {'cam': _cam}),
      ],
      [
        _p('a', session: 's2', tracks: {'cam': _cam}),
      ],
    );
    final change = diff.updated.single;
    expect(change.sessionChanged, isTrue);
    expect(change.addedTracks, isEmpty);
    expect(change.removedTracks, isEmpty);
    expect(change.changedTracks, isEmpty);
    expect(change.previous.sessionId, 's1');
    expect(change.current.sessionId, 's2');
  });

  test('tracks added, removed and changed', () {
    final diff = diffParticipants(
      [
        _p('a', tracks: {'cam': _cam, 'mic': _mic, 'share': _screen}),
      ],
      [
        _p(
          'a',
          tracks: {
            'cam': _cam,
            'mic': _mic.copyWith(muted: true),
            'cam2': _cam,
          },
        ),
      ],
    );
    final change = diff.updated.single;
    expect(change.sessionChanged, isFalse);
    expect(change.addedTracks, {'cam2': _cam});
    expect(change.removedTracks, {'share': _screen});
    expect(change.changedTracks, {'mic': _mic.copyWith(muted: true)});
    expect(change.metadataChanged, isFalse);
  });

  test('a track that changes kind or source is replaced', () {
    final change = diffParticipants(
      [
        _p('a', tracks: {'t': _cam}),
      ],
      [
        _p('a', tracks: {'t': _screen}),
      ],
    ).updated.single;
    expect(change.removedTracks, {'t': _cam});
    expect(change.addedTracks, {'t': _screen});
    expect(change.changedTracks, isEmpty);
  });

  test('simulcast hints count as a track change', () {
    final withLayers = _cam.copyWith(
      simulcast: SimulcastInfo(rids: const ['a', 'b']),
    );
    final change = diffParticipants(
      [
        _p('a', tracks: {'cam': _cam}),
      ],
      [
        _p('a', tracks: {'cam': withLayers}),
      ],
    ).updated.single;
    expect(change.changedTracks, {'cam': withLayers});
  });

  test('metadata changes are compared deeply', () {
    final same = diffParticipants(
      [
        _p(
          'a',
          metadata: {
            'name': 'Ada',
            'roles': ['host'],
          },
        ),
      ],
      [
        _p(
          'a',
          metadata: {
            'name': 'Ada',
            'roles': ['host'],
          },
        ),
      ],
    );
    expect(same.isEmpty, isTrue);

    final changed = diffParticipants(
      [
        _p('a', metadata: {'name': 'Ada'}),
      ],
      [
        _p('a', metadata: {'name': 'Grace'}),
      ],
    );
    expect(changed.updated.single.metadataChanged, isTrue);
  });

  test('duplicate participant IDs: the later entry wins', () {
    final diff = diffParticipants(
      [_p('a', session: 's1')],
      [_p('a', session: 's1'), _p('a', session: 's2')],
    );
    expect(diff.updated.single.current.sessionId, 's2');
  });

  test('four participants: join, publish, mute, reconnect, leave', () {
    var list = <ParticipantState>[];
    ParticipantsDiff step(List<ParticipantState> next) {
      final diff = diffParticipants(list, next);
      list = next;
      return diff;
    }

    var diff = step([_p('a'), _p('b'), _p('c'), _p('d')]);
    expect(_ids(diff.joined), ['a', 'b', 'c', 'd']);

    diff = step([
      _p('a', tracks: {'a-mic': _mic, 'a-cam': _cam}),
      _p('b', tracks: {'b-mic': _mic}),
      _p('c'),
      _p('d'),
    ]);
    expect([for (final u in diff.updated) u.participantId], ['a', 'b']);
    expect(diff.updated.first.addedTracks.keys, ['a-mic', 'a-cam']);

    diff = step([
      _p('a', tracks: {'a-mic': _mic.copyWith(muted: true), 'a-cam': _cam}),
      _p('b', tracks: {'b-mic': _mic}),
      _p('c', session: 's-c2'),
      _p('d'),
    ]);
    expect(diff.updated[0].changedTracks.keys, ['a-mic']);
    expect(diff.updated[1].participantId, 'c');
    expect(diff.updated[1].sessionChanged, isTrue);

    diff = step([
      _p('a', tracks: {'a-mic': _mic.copyWith(muted: true)}),
      _p('b', tracks: {'b-mic': _mic}),
      _p('c', session: 's-c2'),
    ]);
    expect(diff.updated.single.removedTracks.keys, ['a-cam']);
    expect(_ids(diff.left), ['d']);
  });
}
