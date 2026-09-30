import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/room/room_audio_levels.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;

import '../support/session_harness.dart';

/// An audio `inbound-rtp` report without `audioLevel`, so the level comes
/// from the growth of the energy counters between polls.
StatsReport _energy(String mid, double energy, double duration) =>
    StatsReport('inbound-audio', 'inbound-rtp', 0, {
      'kind': 'audio',
      'mid': mid,
      'totalAudioEnergy': energy,
      'totalSamplesDuration': duration,
    });

void main() {
  late SessionHarness h;

  setUp(() {
    h = SessionHarness();
    h.broker.trackKinds['ann-1/m'] = 'audio';
  });

  test('follows a replaced session: reads the new peer connection, maps '
      'only its pulls, and starts its energy baselines afresh', () async {
    final first = await h.connect();
    final firstPc = h.pc;
    final firstPull = await first.subscribe(
      remoteSessionId: 'ann-1',
      trackName: 'm',
    );
    final second = await h.connect();
    final secondPc = h.pc;
    final secondPull = await second.subscribe(
      remoteSessionId: 'ann-1',
      trackName: 'm',
    );
    expect(firstPull.mid, isNot(secondPull.mid));

    var current = first;
    final source = RoomAudioLevelSource(
      session: () => current,
      remoteAudio: () => [
        (participantId: 'ann', subscription: firstPull),
        (participantId: 'ann', subscription: secondPull),
      ],
    );

    firstPc.stats = [_energy(firstPull.mid!, 1.0, 10)];
    expect(await source.getAudioLevels(), isEmpty, reason: 'no baseline');
    firstPc.stats = [_energy(firstPull.mid!, 1.09, 11)];
    expect((await source.getAudioLevels())['ann'], closeTo(0.3, 1e-9));
    expect(source.boundSession, same(first));

    // The session is replaced. The new connection reports the same stats ID
    // with unrelated counters: mixing them with the old baseline would read
    // as a shout. It also reports the old pull's mid, which is not the
    // old pull there.
    current = second;
    secondPc.stats = [
      _energy(secondPull.mid!, 5.0, 12),
      StatsReport('other', 'inbound-rtp', 0, {
        'kind': 'audio',
        'mid': firstPull.mid,
        'audioLevel': 0.9,
      }),
    ];
    final firstCalls = firstPc.statsCalls;
    expect(await source.getAudioLevels(), isEmpty);
    expect(source.boundSession, same(second));
    expect(firstPc.statsCalls, firstCalls, reason: 'the old PC is left');
    expect(secondPc.statsCalls, 1);

    secondPc.stats = [_energy(secondPull.mid!, 5.04, 13)];
    expect((await source.getAudioLevels())['ann'], closeTo(0.2, 1e-9));

    // rebind() starts afresh on the same session too.
    source.rebind();
    expect(source.boundSession, isNull);
    secondPc.stats = [_energy(secondPull.mid!, 5.2, 14)];
    expect(await source.getAudioLevels(), isEmpty);

    await first.close();
    await second.close();
  });

  test('reads nothing without audio, or on a closed session', () async {
    final session = await h.connect();
    final pc = h.pc;
    var tracks = <RoomAudioTrack>[];
    final source = RoomAudioLevelSource(
      session: () => session,
      remoteAudio: () => tracks,
      localParticipantId: 'me',
      localTrackId: () => null,
    );
    expect(await source.getAudioLevels(), isEmpty);
    expect(pc.statsCalls, 0);

    final pull = await session.subscribe(
      remoteSessionId: 'ann-1',
      trackName: 'm',
    );
    tracks = [(participantId: 'ann', subscription: pull)];
    pc.stats = [
      StatsReport('in', 'inbound-rtp', 0, {
        'kind': 'audio',
        'mid': pull.mid,
        'audioLevel': 0.5,
      }),
      // Local audio without a microphone track (screen-share audio, say)
      // is not the local participant speaking.
      StatsReport('src', 'media-source', 0, {
        'kind': 'audio',
        'trackIdentifier': 'screen-audio',
        'audioLevel': 0.8,
      }),
    ];
    expect(await source.getAudioLevels(), {'ann': 0.5});

    await session.close();
    expect(await source.getAudioLevels(), isEmpty);
    expect(pc.statsCalls, 1);
  });

  test('SfuSession.getStats reads the peer connection, until closed', () async {
    final session = await h.connect();
    h.pc.stats = [StatsReport('x', 'transport', 0, {})];
    expect((await session.getStats()).single.id, 'x');
    await session.close();
    await expectLater(
      session.getStats(),
      throwsA(isA<SfuSessionClosedException>()),
    );
  });
}
