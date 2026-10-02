import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/session/track_name.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        MediaStreamTrack,
        RTCIceConnectionState,
        RTCPeerConnectionState,
        RTCSignalingState;

import '../support/sdp_fixtures.dart';
import '../support/session_harness.dart';

TracksRequest _tracksRequest(BrokerCall call) => call.request! as TracksRequest;

List<Map<String, Object?>> _tracksJson(BrokerCall call) => [
  for (final t in (call.request as dynamic).tracks as List<TrackObject>)
    t.toJson(),
];

void main() {
  late SessionHarness h;

  setUp(() => h = SessionHarness());

  group('connect', () {
    test('requests the session and ICE servers, then creates the PC', () async {
      final session = await h.connect(
        options: const SfuSessionOptions(correlationId: 'corr'),
      );

      expect(session.sessionId, 'session-1');
      expect(h.broker.operations, ['sessions/new', 'generate-ice-servers']);
      final request = h.broker.calls.first.request! as NewSessionRequest;
      expect(request.correlationId, 'corr');
      expect(request.sessionDescription, isNull);
      expect(h.pc.configuration, {
        'iceServers': [
          {'urls': 'stun:stun.cloudflare.com:3478'},
        ],
        'bundlePolicy': 'max-bundle',
        'sdpSemantics': 'unified-plan',
      });
      expect(session.currentConnectionState, SfuConnectionState.initial);
      expect(h.pc.log, isEmpty, reason: 'nothing negotiated until a push');
    });

    test('uses configured ICE servers without asking the broker', () async {
      await h.connect(
        options: const SfuSessionOptions(
          iceServers: [
            {'urls': 'stun:example.test:3478'},
          ],
        ),
      );
      expect(h.broker.operations, ['sessions/new']);
      expect(h.pc.configuration['iceServers'], [
        {'urls': 'stun:example.test:3478'},
      ]);
    });

    test('forgets the new session if the ICE servers fail', () async {
      h.broker.onGetIceServers = () async =>
          throw const BrokerNetworkException(operation: 'generate-ice-servers');
      await expectLater(h.connect(), throwsA(isA<BrokerNetworkException>()));
      expect(h.broker.forgotten, ['session-1']);
      expect(h.peerConnections.created, isEmpty);
    });

    test('throws the broker error when sessions/new fails', () async {
      h.broker.onNewSession = (_) async =>
          throw const BrokerUnauthorizedException(operation: 'sessions/new');
      await expectLater(
        h.connect(),
        throwsA(isA<BrokerUnauthorizedException>()),
      );
      expect(h.peerConnections.created, isEmpty);
    });
  });

  group('publish', () {
    test('pushes with addTransceiver, offer, tracks/new, answer', () async {
      final session = await h.connect();
      final track = FakeMediaStreamTrack(kind: 'audio');

      final pub = await session.publish(
        track,
        options: const PublishOptions(trackName: 'mic'),
      );

      expect(h.pc.log, [
        'addTransceiver(audio)',
        'createOffer',
        'setLocalDescription(offer)',
        'setRemoteDescription(answer)',
      ]);
      final call = h.broker.callsTo('tracks/new').single;
      expect(call.sessionId, 'session-1');
      expect(_tracksRequest(call).sessionDescription!.sdp, 'offer-1');
      expect(_tracksJson(call), [
        {'location': 'local', 'mid': '0', 'trackName': 'mic'},
      ]);
      expect(h.pc.remoteDescription!.sdp, 'answer:offer-1');

      expect(pub.trackName, 'mic');
      expect(pub.kind, 'audio');
      expect(pub.state, SfuTrackState.active);
      expect(pub.mid, '0');
      expect(pub.session, same(session));
      expect(pub.sessionId, 'session-1');
      expect(pub.track, same(track));
      expect(session.publications, [pub]);
      final t = h.pc.transceivers.single;
      expect(t.direction, 'sendonly');
      expect(t.sendEncodings, isEmpty, reason: 'no encodings for audio');
    });

    test('video defaults to a/b/c simulcast encodings', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));

      final encodings = h.pc.transceivers.single.sendEncodings;
      expect(encodings, SimulcastPresets.h720);
      expect([for (final e in encodings) e.rid], ['a', 'b', 'c']);
      expect(
        [for (final e in encodings) e.scaleResolutionDownBy],
        [null, 2, 4],
      );
      expect(encodings.every((e) => e.maxBitrate != null), isTrue);
      expect(pub.sendEncodings, SimulcastPresets.h720);
    });

    test('takes encodings as a parameter', () async {
      final session = await h.connect();
      await session.publish(
        FakeMediaStreamTrack(kind: 'video'),
        options: const PublishOptions(
          sendEncodings: [SendEncoding(maxBitrate: 800000)],
        ),
      );
      expect(h.pc.transceivers.single.sendEncodings, const [
        SendEncoding(maxBitrate: 800000),
      ]);
    });

    test('prefers VP8 on Windows', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = await h.connect();
      await session.publish(FakeMediaStreamTrack(kind: 'video'));
      await session.publish(FakeMediaStreamTrack(kind: 'audio'));

      expect(h.pc.transceivers[0].codecPreferences, ['video/VP8']);
      expect(h.pc.transceivers[1].codecPreferences, isNull);
      expect(
        h.pc.log.indexOf('setCodecPreferences(video, video/VP8)'),
        lessThan(h.pc.log.indexOf('createOffer')),
      );
    });

    test('leaves codecs alone elsewhere unless configured', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final session = await h.connect(
        options: const SfuSessionOptions(
          defaults: SfuSessionDefaults(videoCodecPreferences: ['video/H264']),
        ),
      );
      await session.publish(FakeMediaStreamTrack(kind: 'video'));
      await session.publish(
        FakeMediaStreamTrack(kind: 'video'),
        options: const PublishOptions(codecPreferences: []),
      );
      expect(h.pc.transceivers[0].codecPreferences, ['video/H264']);
      expect(h.pc.transceivers[1].codecPreferences, isNull);
      expect(defaultVideoCodecPreferences(), ['video/VP8']);
    });

    test('generates unique UUID track names', () async {
      final session = await h.connect();
      final a = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final b = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final uuid = RegExp(
        r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
      );
      expect(a.trackName, matches(uuid));
      expect(b.trackName, matches(uuid));
      expect(a.trackName, isNot(b.trackName));
      expect(generateTrackName(), matches(uuid));
    });

    test('rejects a duplicate track name on the same session', () async {
      final session = await h.connect();
      await session.publish(
        FakeMediaStreamTrack(kind: 'audio'),
        options: const PublishOptions(trackName: 'mic'),
      );
      expect(
        () => session.publish(
          FakeMediaStreamTrack(kind: 'audio'),
          options: const PublishOptions(trackName: 'mic'),
        ),
        throwsStateError,
      );
    });
  });

  group('op queue', () {
    test('batches pushes in the same turn into one tracks/new', () async {
      final session = await h.connect();
      final futures = [
        session.publish(
          FakeMediaStreamTrack(kind: 'audio'),
          options: const PublishOptions(trackName: 'mic'),
        ),
        session.publish(
          FakeMediaStreamTrack(kind: 'video'),
          options: const PublishOptions(trackName: 'cam'),
        ),
      ];
      final pubs = await Future.wait(futures);

      expect(h.broker.callsTo('tracks/new'), hasLength(1));
      expect(_tracksJson(h.broker.callsTo('tracks/new').single), [
        {'location': 'local', 'mid': '0', 'trackName': 'mic'},
        {'location': 'local', 'mid': '1', 'trackName': 'cam'},
      ]);
      expect(h.pc.log, [
        'addTransceiver(audio)',
        'addTransceiver(video)',
        'setCodecPreferences(video, video/VP8)',
        'createOffer',
        'setLocalDescription(offer)',
        'setRemoteDescription(answer)',
      ]);
      expect(pubs.map((p) => p.mid), ['0', '1']);
    });

    test('batches pulls in the same turn into one tracks/new', () async {
      final session = await h.connect();
      final subs = await Future.wait([
        session.subscribe(remoteSessionId: 'peer-1', trackName: 'cam'),
        session.subscribe(remoteSessionId: 'peer-2', trackName: 'mic'),
      ]);
      expect(h.broker.callsTo('tracks/new'), hasLength(1));
      expect(h.broker.callsTo('renegotiate'), hasLength(1));
      expect(subs.map((s) => s.mid), ['r1', 'r2']);
    });

    test('pushes and pulls in the same turn go out as two serialized '
        'requests', () async {
      final session = await h.connect();
      final gate = Completer<void>();
      final order = <String>[];
      h.broker.onNewTracks = (sessionId, request) async {
        final isPush = request.sessionDescription != null;
        order.add(isPush ? 'push start' : 'pull start');
        if (isPush) await gate.future;
        order.add(isPush ? 'push end' : 'pull end');
        return h.broker.defaultNewTracks(sessionId, request);
      };

      final pub = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final sub = session.subscribe(remoteSessionId: 'peer', trackName: 't');
      await pumpEventQueue();
      expect(order, ['push start'], reason: 'the pull waits for the push');

      gate.complete();
      await Future.wait([pub, sub]);
      expect(order, ['push start', 'push end', 'pull start', 'pull end']);
      final requests = h.broker.callsTo('tracks/new').map(_tracksRequest);
      expect(requests.map((r) => r.tracks.single.location), [
        TrackLocation.local,
        TrackLocation.remote,
      ]);
    });

    test('operations in separate turns are separate batches', () async {
      final session = await h.connect();
      await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      expect(h.broker.callsTo('tracks/new'), hasLength(2));
      expect(h.pc.log.where((e) => e == 'createOffer'), hasLength(2));
    });

    test('a failing request does not wedge the queue', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (_, _) async =>
          throw const BrokerException(operation: 'tracks/new', statusCode: 500);
      final failed = session.publish(
        FakeMediaStreamTrack(kind: 'audio'),
        options: const PublishOptions(trackName: 'a'),
      );
      await expectLater(failed, throwsA(isA<BrokerException>()));
      expect(session.publications, isEmpty);

      h.broker.onNewTracks = null;
      final pub = await session.publish(
        FakeMediaStreamTrack(kind: 'audio'),
        options: const PublishOptions(trackName: 'a'),
      );
      expect(pub.state, SfuTrackState.active);
      expect(session.isUsable, isTrue);
    });

    test('a failing PC call fails the batch but not the queue', () async {
      final session = await h.connect();
      h.pc.failNext('createOffer', 'native error');
      final failed = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      await expectLater(failed, throwsA('native error'));
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      expect(pub.state, SfuTrackState.active);
    });

    test('a request-level error in a 2xx fails every track', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (_, _) async => const TracksResponse(
        errorCode: 'invalid_request',
        errorDescription: 'bad',
      );
      final a = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final b = session.publish(FakeMediaStreamTrack(kind: 'video'));
      await Future.wait([
        expectLater(a, throwsA(isA<SfuRequestException>())),
        expectLater(
          b,
          throwsA(
            isA<SfuRequestException>().having(
              (e) => e.errorCode,
              'errorCode',
              'invalid_request',
            ),
          ),
        ),
      ]);
      expect(h.pc.log, isNot(contains('setRemoteDescription(answer)')));
    });
  });

  group('per-track errors', () {
    test('fail only that publication, not the batch', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (sessionId, request) async {
        final ok = await h.broker.defaultNewTracks(sessionId, request);
        return TracksResponse(
          sessionDescription: ok.sessionDescription,
          tracks: [
            ok.tracks[0],
            TrackResult(
              mid: ok.tracks[1].mid,
              trackName: ok.tracks[1].trackName,
              errorCode: 'invalid_track',
              errorDescription: 'nope',
            ),
          ],
        );
      };
      final good = session.publish(
        FakeMediaStreamTrack(kind: 'audio'),
        options: const PublishOptions(trackName: 'good'),
      );
      final bad = session.publish(
        FakeMediaStreamTrack(kind: 'video'),
        options: const PublishOptions(trackName: 'bad'),
      );

      final badFails = expectLater(
        bad,
        throwsA(
          isA<SfuTrackException>()
              .having((e) => e.trackName, 'trackName', 'bad')
              .having((e) => e.errorCode, 'errorCode', 'invalid_track'),
        ),
      );
      final pub = await good;
      await badFails;
      expect(pub.state, SfuTrackState.active);
      expect(session.publications.map((p) => p.trackName), ['good']);
      await pumpEventQueue();
      expect(h.pc.transceivers[1].stopped, isTrue);
      expect(h.pc.transceivers[0].stopped, isFalse);
    });

    test('a missing result fails that publication', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (sessionId, request) async {
        final ok = await h.broker.defaultNewTracks(sessionId, request);
        return TracksResponse(
          sessionDescription: ok.sessionDescription,
          tracks: [ok.tracks.first],
        );
      };
      final a = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final b = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final bFails = expectLater(
        b,
        throwsA(isA<SfuTrackException>().having((e) => e.errorCode, 'c', null)),
      );
      await a;
      await bFails;
    });

    test('fail only that subscription, not the batch', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (sessionId, request) async {
        final ok = await h.broker.defaultNewTracks(sessionId, request);
        return TracksResponse(
          requiresImmediateRenegotiation: true,
          sessionDescription: ok.sessionDescription,
          tracks: [
            ok.tracks[0],
            const TrackResult(
              trackName: 'gone',
              sessionId: 'peer',
              errorCode: 'not_found',
            ),
          ],
        );
      };
      final good = session.subscribe(remoteSessionId: 'peer', trackName: 'ok');
      final bad = session.subscribe(remoteSessionId: 'peer', trackName: 'gone');

      final badFails = expectLater(
        bad,
        throwsA(
          isA<SfuTrackException>().having((e) => e.errorCode, 'c', 'not_found'),
        ),
      );
      final sub = await good;
      await badFails;
      expect(sub.state, SfuTrackState.active);
      expect(sub.track, isNotNull);
      expect(session.subscriptions, [sub]);
    });
  });

  group('subscribe', () {
    test('pulls, renegotiates and maps the mid to the remote track', () async {
      final session = await h.connect();
      final sub = await session.subscribe(
        remoteSessionId: 'peer',
        trackName: 'cam',
        preferredRid: 'b',
      );

      expect(h.broker.operations.skip(2), ['tracks/new', 'renegotiate']);
      final pull = _tracksRequest(h.broker.callsTo('tracks/new').single);
      expect(pull.sessionDescription, isNull);
      expect(_tracksJson(h.broker.callsTo('tracks/new').single), [
        {
          'location': 'remote',
          'sessionId': 'peer',
          'trackName': 'cam',
          'simulcast': {'preferredRid': 'b', 'ridNotAvailable': 'asciibetical'},
        },
      ]);
      expect(h.pc.log, [
        'setRemoteDescription(offer)',
        'createAnswer',
        'setLocalDescription(answer)',
        'transceiverForMid(r1)',
      ]);
      final renegotiate =
          h.broker.callsTo('renegotiate').single.request! as RenegotiateRequest;
      expect(renegotiate.sessionDescription.type, SdpType.answer);
      expect(renegotiate.sessionDescription.sdp, 'answer-1');

      expect(sub.state, SfuTrackState.active);
      expect(sub.mid, 'r1');
      expect(sub.preferredRid, 'b');
      expect(sub.remoteSessionId, 'peer');
      expect(sub.track, same(h.pc.byMid('r1')!.receiverTrack));
      expect(await sub.trackStream.first, same(sub.track));
    });

    test('sends no simulcast block without a preferred rid', () async {
      final session = await h.connect();
      await session.subscribe(remoteSessionId: 'peer', trackName: 'mic');
      expect(_tracksJson(h.broker.callsTo('tracks/new').single), [
        {'location': 'remote', 'sessionId': 'peer', 'trackName': 'mic'},
      ]);
    });

    test('passes priorityOrdering and ridNotAvailable', () async {
      final session = await h.connect();
      await session.subscribe(
        remoteSessionId: 'peer',
        trackName: 'cam',
        preferredRid: 'a',
        priorityOrdering: SimulcastOrdering.asciibetical,
        ridNotAvailable: SimulcastOrdering.none,
      );
      expect(
        _tracksJson(h.broker.callsTo('tracks/new').single).single['simulcast'],
        {
          'preferredRid': 'a',
          'priorityOrdering': 'asciibetical',
          'ridNotAvailable': 'none',
        },
      );
    });

    test('skips renegotiation when the SFU does not ask for it', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (sessionId, request) async {
        final ok = await h.broker.defaultNewTracks(sessionId, request);
        // Pretend the transceiver already exists (as for a reused mid).
        await h.pc.setRemoteDescription(ok.sessionDescription!);
        h.pc.log.clear();
        return TracksResponse(tracks: ok.tracks);
      };
      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 't');
      expect(h.broker.callsTo('renegotiate'), isEmpty);
      expect(h.pc.log, ['transceiverForMid(r1)']);
      expect(sub.state, SfuTrackState.active);
    });

    test('fails when the transceiver never appears', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (sessionId, request) async {
        final ok = await h.broker.defaultNewTracks(sessionId, request);
        return TracksResponse(
          requiresImmediateRenegotiation: true,
          sessionDescription: h.broker.sfuOffer(const []),
          tracks: ok.tracks,
        );
      };
      await expectLater(
        session.subscribe(remoteSessionId: 'p', trackName: 't'),
        throwsA(isA<SfuTrackException>()),
      );
    });

    test('a renegotiate error fails the batch', () async {
      final session = await h.connect();
      h.broker.onRenegotiate = (_, _) async =>
          const RenegotiateResponse(errorCode: 'bad_sdp');
      await expectLater(
        session.subscribe(remoteSessionId: 'p', trackName: 't'),
        throwsA(isA<SfuRequestException>()),
      );
      final sub = await (() {
        h.broker.onRenegotiate = null;
        return session.subscribe(remoteSessionId: 'p', trackName: 't');
      })();
      expect(sub.state, SfuTrackState.active);
    });
  });

  group('setPreferredRid', () {
    test('sends tracks/update with the mid and keeps orderings', () async {
      final session = await h.connect();
      final sub = await session.subscribe(
        remoteSessionId: 'peer',
        trackName: 'cam',
        preferredRid: 'a',
      );
      await sub.setPreferredRid('c');

      final update =
          h.broker.callsTo('tracks/update').single.request!
              as UpdateTracksRequest;
      expect(
        [for (final t in update.tracks) t.toJson()],
        [
          {
            'location': 'remote',
            'mid': 'r1',
            'sessionId': 'peer',
            'trackName': 'cam',
            'simulcast': {
              'preferredRid': 'c',
              'ridNotAvailable': 'asciibetical',
            },
          },
        ],
      );
      expect(sub.preferredRid, 'c');
    });

    test('batches updates, last rid per subscription wins', () async {
      final session = await h.connect();
      final a = await session.subscribe(remoteSessionId: 'p', trackName: 'a');
      final b = await session.subscribe(remoteSessionId: 'p', trackName: 'b');
      await Future.wait([
        a.setPreferredRid('b'),
        b.setPreferredRid('c'),
        a.setPreferredRid('a'),
      ]);
      final update =
          h.broker.callsTo('tracks/update').single.request!
              as UpdateTracksRequest;
      expect(update.tracks.map((t) => (t.mid, t.simulcast!.preferredRid)), [
        ('r1', 'a'),
        ('r2', 'c'),
      ]);
      expect(a.preferredRid, 'a');
      expect(b.preferredRid, 'c');
    });

    test('a per-track error keeps the previous rid', () async {
      final session = await h.connect();
      final sub = await session.subscribe(
        remoteSessionId: 'p',
        trackName: 't',
        preferredRid: 'a',
      );
      h.broker.onUpdateTracks = (_, request) async => TracksResponse(
        tracks: [
          TrackResult(mid: request.tracks.single.mid, errorCode: 'bad_rid'),
        ],
      );
      await expectLater(
        sub.setPreferredRid('z'),
        throwsA(isA<SfuTrackException>()),
      );
      expect(sub.preferredRid, 'a');
    });

    test('renegotiates when the update asks for it', () async {
      final session = await h.connect();
      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 't');
      h.broker.onUpdateTracks = (sessionId, request) async {
        final ok = await h.broker.defaultUpdateTracks(sessionId, request);
        return TracksResponse(
          requiresImmediateRenegotiation: true,
          sessionDescription: h.broker.sfuOffer(const []),
          tracks: ok.tracks,
        );
      };
      await sub.setPreferredRid('b');
      expect(h.broker.operations.last, 'renegotiate');
    });
    group('while the SFU is not forwarding the track yet', () {
      TracksResponse notForwarding(UpdateTracksRequest request) =>
          TracksResponse(
            tracks: [
              TrackResult(
                mid: request.tracks.single.mid,
                errorCode: 'update_track_error',
                errorDescription:
                    'The track is not configured for simulcast, no updates '
                    'applicable.',
              ),
            ],
          );

      test('retries until the SFU accepts the update', () {
        fakeAsync((async) {
          late RemoteTrackSubscription sub;
          h.connect().then(
            (s) => s
                .subscribe(remoteSessionId: 'p', trackName: 't')
                .then((r) => sub = r),
          );
          async.flushMicrotasks();
          async.elapse(Duration.zero);

          var rejections = 2;
          h.broker.onUpdateTracks = (sessionId, request) async =>
              rejections-- > 0
              ? notForwarding(request)
              : h.broker.defaultUpdateTracks(sessionId, request);
          var done = false;
          sub.setPreferredRid('c').then((_) => done = true);
          async.elapse(const Duration(milliseconds: 50));
          expect(h.broker.callsTo('tracks/update'), hasLength(1));
          expect(done, isFalse);

          async.elapse(const Duration(milliseconds: 100)); // 1st retry.
          expect(h.broker.callsTo('tracks/update'), hasLength(2));
          async.elapse(const Duration(milliseconds: 200)); // 2nd retry.
          expect(h.broker.callsTo('tracks/update'), hasLength(3));
          expect(done, isTrue);
          expect(sub.preferredRid, 'c');
        });
      });

      test('gives up after layerUpdateRetryTimeout', () {
        fakeAsync((async) {
          late RemoteTrackSubscription sub;
          h
              .connect(
                options: const SfuSessionOptions(
                  layerUpdateRetryTimeout: Duration(milliseconds: 250),
                ),
              )
              .then(
                (s) => s
                    .subscribe(remoteSessionId: 'p', trackName: 't')
                    .then((r) => sub = r),
              );
          async.flushMicrotasks();
          async.elapse(Duration.zero);

          h.broker.onUpdateTracks = (_, request) async =>
              notForwarding(request);
          Object? error;
          sub.setPreferredRid('c').catchError((Object e) => error = e);
          async.elapse(const Duration(seconds: 5));
          // 100 + 200 ms of retries reach the 250 ms budget.
          expect(h.broker.callsTo('tracks/update'), hasLength(3));
          expect(error, isA<SfuTrackException>());
          expect(sub.preferredRid, isNull);
        });
      });

      test('does not retry other errors', () async {
        final session = await h.connect();
        final sub = await session.subscribe(
          remoteSessionId: 'p',
          trackName: 't',
        );
        h.broker.onUpdateTracks = (_, request) async => TracksResponse(
          tracks: [
            TrackResult(
              mid: request.tracks.single.mid,
              errorCode: 'update_track_error',
              errorDescription: 'something else',
            ),
          ],
        );
        await expectLater(
          sub.setPreferredRid('c'),
          throwsA(isA<SfuTrackException>()),
        );
        expect(h.broker.callsTo('tracks/update'), hasLength(1));
      });

      test('a newer rid supersedes a pending retry', () {
        fakeAsync((async) {
          late RemoteTrackSubscription sub;
          h.connect().then(
            (s) => s
                .subscribe(remoteSessionId: 'p', trackName: 't')
                .then((r) => sub = r),
          );
          async.flushMicrotasks();
          async.elapse(Duration.zero);

          var rejections = 1;
          h.broker.onUpdateTracks = (sessionId, request) async =>
              rejections-- > 0
              ? notForwarding(request)
              : h.broker.defaultUpdateTracks(sessionId, request);
          var first = false;
          sub.setPreferredRid('c').then((_) => first = true);
          async.elapse(const Duration(milliseconds: 50));
          sub.setPreferredRid('a');
          async.elapse(const Duration(seconds: 1));

          final rids = [
            for (final call in h.broker.callsTo('tracks/update'))
              (call.request! as UpdateTracksRequest)
                  .tracks
                  .single
                  .simulcast!
                  .preferredRid,
          ];
          expect(rids, ['c', 'a'], reason: 'c is not sent again');
          expect(first, isTrue);
          expect(sub.preferredRid, 'a');
        });
      });
    });
  });

  group('close', () {
    group("the session's last live m-lines", () {
      // What libwebrtc reports as the local description: SDP with m-lines.
      SessionDescription sdp(List<(String, String)> mLines) =>
          SessionDescription.answer(
            [
              'v=0',
              for (final (mid, port) in mLines) ...[
                'm=video $port UDP/TLS/RTP/SAVPF 96',
                'a=mid:$mid',
              ],
              '',
            ].join('\r\n'),
          );

      test('close with force, parking the transceivers', () async {
        final session = await h.connect();
        final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
        final sub = await session.subscribe(
          remoteSessionId: 'p',
          trackName: 't',
        );
        h.pc.currentLocalDescription = sdp([('0', '9'), ('r1', '9')]);
        h.pc.log.clear();

        await Future.wait([pub.unpublish(), sub.unsubscribe()]);

        // No stop and no offer: rejecting every m-line fails with
        // max-bundle, or drops the transport.
        expect(h.pc.log, ['replaceTrack(null)']);
        expect(h.pc.transceivers.where((t) => t.stopped), isEmpty);
        final close =
            h.broker.callsTo('tracks/close').single.request!
                as CloseTracksRequest;
        expect(close.toJson(), {
          'tracks': [
            {'mid': '0'},
            {'mid': 'r1'},
          ],
          'force': true,
        });
        expect(pub.state, SfuTrackState.closed);
        expect(sub.state, SfuTrackState.closed);
        expect(session.publications, isEmpty);
        expect(session.subscriptions, isEmpty);
      });

      test('negotiate when another m-line stays live', () async {
        final session = await h.connect();
        final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
        await session.publish(FakeMediaStreamTrack(kind: 'audio'));
        // mid 1 stays; a rejected m-line (port 0) doesn't count.
        h.pc.currentLocalDescription = sdp([
          ('0', '9'),
          ('1', '9'),
          ('2', '0'),
        ]);
        h.pc.log.clear();

        await pub.unpublish();

        expect(h.pc.log, [
          'stop(0)',
          'createOffer',
          'setLocalDescription(offer)',
          'setRemoteDescription(answer)',
        ]);
        final close =
            h.broker.callsTo('tracks/close').single.request!
                as CloseTracksRequest;
        expect(close.force, isFalse);
      });

      test('a DataChannel m-line keeps the negotiated close', () async {
        final session = await h.connect();
        final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
        h.pc.currentLocalDescription = SessionDescription.answer(
          'v=0\r\n'
          'm=video 9 UDP/TLS/RTP/SAVPF 96\r\na=mid:0\r\n'
          'm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:1\r\n',
        );

        await pub.unpublish();

        final close =
            h.broker.callsTo('tracks/close').single.request!
                as CloseTracksRequest;
        expect(close.force, isFalse);
        expect(h.pc.byMid('0')!.stopped, isTrue);
      });
    });

    test(
      'unpublish stops the transceiver and negotiates tracks/close',
      () async {
        final session = await h.connect();
        final track = FakeMediaStreamTrack(kind: 'audio');
        final pub = await session.publish(track);
        h.pc.log.clear();

        await pub.unpublish();

        expect(h.pc.log, [
          'stop(0)',
          'createOffer',
          'setLocalDescription(offer)',
          'setRemoteDescription(answer)',
        ]);
        final close =
            h.broker.callsTo('tracks/close').single.request!
                as CloseTracksRequest;
        expect(close.toJson(), {
          'tracks': [
            {'mid': '0'},
          ],
          'force': false,
          'sessionDescription': {'type': 'offer', 'sdp': 'offer-2'},
        });
        expect(pub.state, SfuTrackState.closed);
        expect(pub.session, isNull);
        expect(session.publications, isEmpty);
        expect(track.stopped, isFalse, reason: 'capture belongs to the app');
      },
    );

    test('batches unpublish and unsubscribe into one tracks/close', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 't');

      await Future.wait([pub.unpublish(), sub.unsubscribe()]);

      final close =
          h.broker.callsTo('tracks/close').single.request!
              as CloseTracksRequest;
      expect(close.mids, ['0', 'r1']);
      expect(h.pc.byMid('r1')!.stopped, isTrue);
      expect(sub.state, SfuTrackState.closed);
      expect(sub.track, isNull);
      expect(session.subscriptions, isEmpty);
    });

    test('renegotiates when the close response asks for it', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      h.broker.onCloseTracks = (_, request) async => TracksResponse(
        requiresImmediateRenegotiation: true,
        sessionDescription: h.broker.sfuOffer(const []),
        tracks: [for (final mid in request.mids) TrackResult(mid: mid)],
      );
      h.pc.log.clear();
      await pub.unpublish();
      expect(h.pc.log, [
        'stop(0)',
        'createOffer',
        'setLocalDescription(offer)',
        'rollback(local)', // Withdraw our offer to answer the SFU's.
        'setRemoteDescription(offer)',
        'createAnswer',
        'setLocalDescription(answer)',
      ]);
      expect(h.broker.operations.last, 'renegotiate');
    });

    test('close_track_error counts as closed; other errors throw', () async {
      final session = await h.connect();
      final a = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final b = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      h.broker.onCloseTracks = (_, request) async => TracksResponse(
        sessionDescription: SessionDescription.answer('x'),
        tracks: [
          TrackResult(mid: request.mids[0], errorCode: 'close_track_error'),
          TrackResult(mid: request.mids[1], errorCode: 'internal'),
        ],
      );
      final closeA = a.unpublish();
      final closeB = expectLater(
        b.unpublish(),
        throwsA(isA<SfuTrackException>()),
      );
      await closeA;
      await closeB;
      expect(b.state, SfuTrackState.closed);
    });

    test('unpublishing right after publishing runs after the push', () async {
      final session = await h.connect();
      final pubFuture = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      await pumpEventQueue(times: 1);
      final pub = session.publications.single;
      final unpublished = pub.unpublish();
      await pubFuture;
      await unpublished;
      expect(h.broker.operations.skip(2), ['tracks/new', 'tracks/close']);
      expect(pub.state, SfuTrackState.closed);
    });
  });

  group('replaceTrack', () {
    test('swaps the sender track without renegotiation', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
      final callsBefore = h.broker.calls.length;
      h.pc.log.clear();

      final next = FakeMediaStreamTrack(kind: 'video', id: 'next');
      await pub.replaceTrack(next);

      expect(h.pc.log, ['replaceTrack(next)']);
      expect(h.broker.calls, hasLength(callsBefore));
      expect(h.pc.transceivers.single.sentTrack, same(next));
      expect(pub.track, same(next));
    });

    test('rejects a track of another kind', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
      expect(
        () => pub.replaceTrack(FakeMediaStreamTrack(kind: 'audio')),
        throwsArgumentError,
      );
    });

    test('null mutes and a track unmutes, keeping the mid', () async {
      final session = await h.connect();
      final first = FakeMediaStreamTrack(kind: 'audio', id: 'first');
      final pub = await session.publish(first);
      final callsBefore = h.broker.calls.length;
      h.pc.log.clear();

      await pub.replaceTrack(null);
      expect(pub.track, isNull);
      expect(h.pc.transceivers.single.sentTrack, isNull);
      expect(pub.mid, '0');
      expect(pub.state, SfuTrackState.active);

      await pub.replaceTrack(first);
      expect(h.pc.transceivers.single.sentTrack, same(first));
      expect(h.pc.log, ['replaceTrack(null)', 'replaceTrack(first)']);
      expect(h.broker.calls, hasLength(callsBefore));
      expect(pub.mid, '0');
    });

    test('a burst of replacements settles on the latest track', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
      final a = FakeMediaStreamTrack(kind: 'video', id: 'a');
      final b = FakeMediaStreamTrack(kind: 'video', id: 'b');
      await Future.wait([
        pub.replaceTrack(a),
        pub.replaceTrack(null),
        pub.replaceTrack(b),
      ]);
      expect(pub.track, same(b));
      expect(h.pc.transceivers.single.sentTrack, same(b));
    });

    test('a replacement while not on a session is used by republish', () async {
      final first = await h.connect();
      final pub = await first.publish(FakeMediaStreamTrack(kind: 'audio'));
      await first.close();
      await pub.replaceTrack(null);
      final second = await h.connect();
      await second.republish(pub);
      expect(h.pc.transceivers.single.sentTrack, isNull);
      expect(h.pc.log.first, 'addTransceiver(audio)');
    });

    test('setEncodings updates the sender without renegotiation', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'video'));
      h.pc.log.clear();
      final encodings = [
        for (final e in SimulcastPresets.h720)
          e.rid == 'a' ? e.copyWith(active: false) : e,
      ];
      await pub.setEncodings(encodings);
      expect(h.pc.log, ['setEncodings']);
      expect(h.pc.transceivers.single.sendEncodings, encodings);
      expect(pub.sendEncodings, encodings);
    });
  });

  group('publishTrackStream', () {
    test('pushes the current track and follows later ones', () async {
      final session = await h.connect();
      final source = StreamController<MediaStreamTrack?>.broadcast();
      final camera = FakeMediaStreamTrack(kind: 'video', id: 'camera');
      final published = session.publishTrackStream(
        source.stream,
        kind: 'video',
        options: const PublishOptions(trackName: 'cam'),
      );
      source.add(camera); // Before the push goes out, as a replay would.
      final pub = await published;

      expect(pub.trackName, 'cam');
      expect(pub.track, same(camera));
      final t = h.pc.transceivers.single;
      expect(t.sentTrack, same(camera));
      expect(t.sendEncodings, SimulcastPresets.h720);
      final callsBefore = h.broker.calls.length;

      final usb = FakeMediaStreamTrack(kind: 'video', id: 'usb');
      source
        ..add(usb) // Device change.
        ..add(FakeMediaStreamTrack(kind: 'audio')); // Wrong kind: ignored.
      await pumpEventQueue();
      expect(t.sentTrack, same(usb));

      source.add(null); // Muted.
      await pumpEventQueue();
      expect(t.sentTrack, isNull);
      expect(pub.mid, '0');
      expect(h.broker.calls, hasLength(callsBefore));

      await pub.unpublish();
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('pushes without a track when the source starts muted', () async {
      final session = await h.connect();
      final source = StreamController<MediaStreamTrack?>();
      final pub = await session.publishTrackStream(
        source.stream,
        kind: 'audio',
      );
      expect(pub.state, SfuTrackState.active);
      expect(pub.track, isNull);
      expect(h.pc.log.first, 'addTransceiver(audio)');
      expect(h.pc.transceivers.single.sentTrack, isNull);

      final mic = FakeMediaStreamTrack(kind: 'audio', id: 'mic');
      source.add(mic);
      await pumpEventQueue();
      expect(h.pc.transceivers.single.sentTrack, same(mic));
      await pub.unpublish();
    });

    test('stops following the source when the push fails', () async {
      final session = await h.connect();
      h.broker.onNewTracks = (_, _) async =>
          throw const BrokerNetworkException(operation: 'tracks/new');
      final source = StreamController<MediaStreamTrack?>.broadcast();
      await expectLater(
        session.publishTrackStream(source.stream, kind: 'video'),
        throwsA(isA<BrokerNetworkException>()),
      );
      expect(source.hasListener, isFalse);
      await source.close();
    });

    test('rejects an unknown kind', () async {
      final session = await h.connect();
      expect(
        () => session.publishTrackStream(const Stream.empty(), kind: 'data'),
        throwsArgumentError,
      );
    });
  });

  group('whenSending', () {
    test('polls sender stats until media flows', () {
      fakeAsync((async) {
        LocalTrackPublication? pub;
        h.connect().then(
          (s) => s
              .publish(FakeMediaStreamTrack(kind: 'video'))
              .then((p) => pub = p),
        );
        async.elapse(Duration.zero);
        async.flushMicrotasks();
        expect(pub, isNotNull);

        var sending = false;
        pub!.whenSending().then((_) => sending = true);
        async.elapse(const Duration(milliseconds: 200));
        expect(sending, isFalse);
        final t = h.pc.transceivers.single;
        expect(t.statsPolls, greaterThan(1));

        t.sentMedia = true;
        async.elapse(const Duration(milliseconds: 100));
        expect(sending, isTrue);
      });
    });

    test('throws once the publication is closed', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final sending = pub.whenSending();
      await pub.unpublish();
      await expectLater(sending, throwsA(isA<SfuSessionException>()));
    });
  });

  group('connection state', () {
    test('maps the PC state and replays the current value', () async {
      final session = await h.connect();
      final states = <SfuConnectionState>[];
      final sub = session.connectionState.listen(states.add);
      await pumpEventQueue();

      h.pc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
      );
      h.pc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      h.pc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
      );
      h.pc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      );
      await pumpEventQueue();
      expect(states, [
        SfuConnectionState.initial,
        SfuConnectionState.connecting,
        SfuConnectionState.connected,
        SfuConnectionState.disconnected,
        SfuConnectionState.connected,
      ]);
      expect(await session.connectionState.first, SfuConnectionState.connected);

      await session.close();
      await pumpEventQueue();
      expect(states.last, SfuConnectionState.closed);
      await sub.cancel();
    });
  });

  group('session failure', () {
    test('SessionGoneException surfaces as a failure event', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final failures = <SfuSessionFailure>[];
      session.failures.listen(failures.add);

      const gone = SessionGoneException(
        operation: 'tracks/new',
        sessionId: 'session-1',
        statusCode: 410,
        errorCode: 'session_error',
      );
      h.broker.onNewTracks = (_, _) async => throw gone;
      // A pull names another session, so ours is confirmed gone first.
      h.broker.goneSessions.add(session.sessionId);
      await expectLater(
        session.subscribe(remoteSessionId: 'p', trackName: 't'),
        throwsA(same(gone)),
      );
      await pumpEventQueue();
      expect(h.broker.callsTo('sessions/{id}').single.sessionId, 'session-1');

      expect(failures, [
        isA<SfuSessionGone>().having((f) => f.exception, 'exception', gone),
      ]);
      expect(session.failure, isA<SfuSessionGone>());
      expect(session.currentConnectionState, SfuConnectionState.failed);
      expect(session.isUsable, isFalse);
      expect(pub.state, SfuTrackState.interrupted);
      expect(pub.session, isNull);
      expect(pub.error, isA<SfuSessionFailedException>());

      // Later operations fail fast, without calling the broker.
      final callCount = h.broker.calls.length;
      expect(
        () => session.publish(FakeMediaStreamTrack(kind: 'audio')),
        throwsA(isA<SfuSessionFailedException>()),
      );
      expect(h.broker.calls, hasLength(callCount));

      // A late listener still sees the failure.
      expect(await session.failures.toList(), [same(session.failure)]);
    });

    group('a gone session reported by a pull', () {
      const gone = SessionGoneException(
        operation: 'tracks/new',
        sessionId: 'session-1',
        statusCode: 410,
        errorCode: 'session_error',
        errorDescription: 'Session is not ready or does not exist',
      );

      test('fails only the pulls when our session is alive', () async {
        final session = await h.connect();
        final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
        final alive = await session.subscribe(
          remoteSessionId: 'p1',
          trackName: 'alive',
        );
        h.broker.onNewTracks = (_, _) async => throw gone;

        final first = session.subscribe(remoteSessionId: 'old', trackName: 'a');
        final second = session.subscribe(remoteSessionId: 'p1', trackName: 'b');
        await Future.wait([
          expectLater(
            first,
            throwsA(
              isA<SfuTrackException>()
                  .having((e) => e.operation, 'operation', 'tracks/new')
                  .having((e) => e.trackName, 'trackName', 'a')
                  .having((e) => e.errorCode, 'errorCode', 'session_error')
                  .having(
                    (e) => e.errorDescription,
                    'errorDescription',
                    gone.errorDescription,
                  ),
            ),
          ),
          expectLater(
            second,
            throwsA(
              isA<SfuTrackException>().having(
                (e) => e.trackName,
                'trackName',
                'b',
              ),
            ),
          ),
        ]);

        // One confirmation for the batch; the session carries on.
        expect(h.broker.callsTo('sessions/{id}'), hasLength(1));
        expect(session.failure, isNull);
        expect(session.isUsable, isTrue);
        expect(pub.state, SfuTrackState.active);
        expect(alive.state, SfuTrackState.active);
        expect(session.subscriptions, [same(alive)]);

        // The next pull works.
        h.broker.onNewTracks = null;
        final later = await session.subscribe(
          remoteSessionId: 'p2',
          trackName: 'c',
        );
        expect(later.state, SfuTrackState.active);
      });

      test('a bare 410 gives the per-track error session_error', () async {
        final session = await h.connect();
        h.broker.onNewTracks = (_, _) async => throw const SessionGoneException(
          operation: 'tracks/new',
          statusCode: 410,
        );
        await expectLater(
          session.subscribe(remoteSessionId: 'old', trackName: 'a'),
          throwsA(
            isA<SfuTrackException>().having(
              (e) => e.errorCode,
              'errorCode',
              'session_error',
            ),
          ),
        );
        expect(session.isUsable, isTrue);
      });

      test('fails the session when the broker refuses it (403)', () async {
        final session = await h.connect();
        h.broker
          ..onNewTracks = ((_, _) async => throw gone)
          ..onGetSessionState = (_) async =>
              throw const BrokerForbiddenException(operation: 'sessions/{id}');
        await expectLater(
          session.subscribe(remoteSessionId: 'p', trackName: 't'),
          throwsA(same(gone)),
        );
        expect(session.failure, isA<SfuSessionGone>());
      });

      test('keeps the session when the confirmation itself fails', () async {
        final session = await h.connect();
        h.broker
          ..onNewTracks = ((_, _) async => throw gone)
          ..onGetSessionState = (_) async =>
              throw const BrokerNetworkException(operation: 'sessions/{id}');
        await expectLater(
          session.subscribe(remoteSessionId: 'p', trackName: 't'),
          throwsA(isA<SfuTrackException>()),
        );
        expect(session.isUsable, isTrue);
      });

      test('pushes, updates and closes fail the session unconfirmed', () async {
        for (final operation in ['push', 'update', 'close']) {
          final h = SessionHarness();
          final session = await h.connect();
          final pub = await session.publish(
            FakeMediaStreamTrack(kind: 'audio'),
          );
          final sub = await session.subscribe(
            remoteSessionId: 'p',
            trackName: 't',
            preferredRid: 'b',
          );
          h.broker
            ..onNewTracks = ((_, _) async => throw gone)
            ..onUpdateTracks = ((_, _) async => throw gone)
            ..onCloseTracks = ((_, _) async => throw gone);
          final Future<void> call = switch (operation) {
            'push' => session.publish(FakeMediaStreamTrack(kind: 'audio')),
            'update' => session.setPreferredRid(sub, 'a'),
            _ => session.unpublish(pub),
          };
          await expectLater(call, throwsA(same(gone)), reason: operation);
          expect(session.failure, isA<SfuSessionGone>(), reason: operation);
          expect(h.broker.callsTo('sessions/{id}'), isEmpty, reason: operation);
        }
      });
    });

    test('queued operations fail once the session is gone', () async {
      final session = await h.connect();
      final gate = Completer<void>();
      h.broker.onNewTracks = (_, _) async {
        await gate.future;
        throw const SessionGoneException(operation: 'tracks/new');
      };
      final first = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      await pumpEventQueue();
      final second = session.subscribe(remoteSessionId: 'p', trackName: 't');
      gate.complete();
      await Future.wait([
        expectLater(first, throwsA(isA<SessionGoneException>())),
        expectLater(second, throwsA(isA<SfuSessionFailedException>())),
      ]);
      expect(h.broker.callsTo('tracks/new'), hasLength(1));
    });

    test('PC failure surfaces as a failure event', () async {
      final session = await h.connect();
      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 't');
      final failure = session.failures.first;

      h.pc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );

      expect(
        await failure,
        isA<SfuPeerConnectionFailed>().having(
          (f) => f.kind,
          'kind',
          PeerConnectionFailureKind.connectionFailed,
        ),
      );
      expect(session.currentConnectionState, SfuConnectionState.failed);
      expect(sub.state, SfuTrackState.interrupted);
      expect(sub.track, isNotNull, reason: 'keeps the last track');
    });

    test('ICE failure surfaces as a failure event', () async {
      final session = await h.connect();
      h.pc.emitIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );
      expect(
        (session.failure! as SfuPeerConnectionFailed).kind,
        PeerConnectionFailureKind.iceFailed,
      );
    });

    test('ICE disconnected for too long surfaces as a failure', () {
      fakeAsync((async) {
        late SfuSession session;
        h.connect().then((s) => session = s);
        async.flushMicrotasks();

        h.pc.emitIceConnectionState(
          RTCIceConnectionState.RTCIceConnectionStateDisconnected,
        );
        async.elapse(const Duration(seconds: 5));
        h.pc.emitIceConnectionState(
          RTCIceConnectionState.RTCIceConnectionStateConnected,
        );
        async.elapse(const Duration(seconds: 10));
        expect(session.failure, isNull, reason: 'recovered within 7 s');

        h.pc.emitIceConnectionState(
          RTCIceConnectionState.RTCIceConnectionStateDisconnected,
        );
        async.elapse(const Duration(milliseconds: 6999));
        expect(session.failure, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(
          (session.failure! as SfuPeerConnectionFailed).kind,
          PeerConnectionFailureKind.iceDisconnectedTimeout,
        );
      });
    });

    test('unpublishing on a failed session only changes local state', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      h.pc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      await pub.unpublish();
      expect(pub.state, SfuTrackState.closed);
      expect(h.broker.callsTo('tracks/close'), isEmpty);
    });
  });

  group('signaling recovery', () {
    const stable = RTCSignalingState.RTCSignalingStateStable;

    final pushFailures = <String, Future<TracksResponse> Function()>{
      'a 5xx': () async =>
          throw const BrokerException(operation: 'tracks/new', statusCode: 503),
      'a 403': () async =>
          throw const BrokerForbiddenException(operation: 'tracks/new'),
      'a network error': () async =>
          throw const BrokerNetworkException(operation: 'tracks/new'),
      'a request-level errorCode': () async =>
          const TracksResponse(errorCode: 'invalid_request'),
      'no answer': () async => const TracksResponse(),
    };

    for (final MapEntry(key: name, value: failure) in pushFailures.entries) {
      test('a push failing with $name rolls back, and a pull then '
          'renegotiates', () async {
        final session = await h.connect();
        h.broker.onNewTracks = (_, _) => failure();
        await expectLater(
          session.publish(FakeMediaStreamTrack(kind: 'video')),
          throwsA(anything),
        );

        expect(h.pc.log, [
          'addTransceiver(video)',
          'setCodecPreferences(video, video/VP8)',
          'createOffer',
          'setLocalDescription(offer)',
          'rollback(local)',
          'stop(null)', // The failed push's transceiver, mid released.
        ]);
        expect(h.pc.currentSignalingState, stable);
        expect(session.isUsable, isTrue);
        final failed = h.pc.transceivers.single;
        expect(failed.stopped, isTrue);

        h.broker.onNewTracks = null;
        final sub = await session.subscribe(
          remoteSessionId: 'p',
          trackName: 't',
        );
        expect(sub.state, SfuTrackState.active);
        expect(h.pc.currentSignalingState, stable);

        // A later offer doesn't carry the failed transceiver.
        await session.publish(FakeMediaStreamTrack(kind: 'audio'));
        expect(h.pc.offeredSenders.last, isNot(contains(failed)));
        expect(h.pc.offeredSenders.last, hasLength(1));
      });
    }

    test('a close failing at the broker rolls back, and a pull then '
        'renegotiates', () async {
      final session = await h.connect();
      final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      h.broker.onCloseTracks = (_, _) async => throw const BrokerException(
        operation: 'tracks/close',
        statusCode: 500,
      );
      h.pc.log.clear();

      await expectLater(pub.unpublish(), throwsA(isA<BrokerException>()));
      expect(h.pc.log, [
        'stop(0)',
        'createOffer',
        'setLocalDescription(offer)',
        'rollback(local)',
      ]);
      expect(h.pc.currentSignalingState, stable);
      expect(pub.state, SfuTrackState.closed);

      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 't');
      expect(sub.state, SfuTrackState.active);
    });

    test('a failure after applying an SFU offer rolls it back', () async {
      final session = await h.connect();
      h.pc.failNext('createAnswer', 'answer failed');
      await expectLater(
        session.subscribe(remoteSessionId: 'p', trackName: 'a'),
        throwsA('answer failed'),
      );
      expect(h.pc.log.sublist(h.pc.log.length - 3), [
        'setRemoteDescription(offer)',
        'createAnswer',
        'rollback(remote)',
      ]);
      expect(h.pc.currentSignalingState, stable);
      expect(h.pc.byMid('r1'), isNull, reason: 'withdrawn with the offer');

      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 'b');
      expect(sub.state, SfuTrackState.active);
    });

    test('a failed renegotiate call leaves a usable, stable session', () async {
      final session = await h.connect();
      h.broker.onRenegotiate = (_, _) async => throw const BrokerException(
        operation: 'renegotiate',
        statusCode: 500,
      );
      await expectLater(
        session.subscribe(remoteSessionId: 'p', trackName: 'a'),
        throwsA(isA<BrokerException>()),
      );
      // The local answer was already applied, so there is nothing to undo.
      expect(h.pc.log.where((e) => e.startsWith('rollback')), isEmpty);
      expect(h.pc.currentSignalingState, stable);

      h.broker.onRenegotiate = null;
      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 'b');
      expect(sub.state, SfuTrackState.active);
    });

    test('a failed rollback fails the session as signalingStuck', () async {
      final session = await h.connect();
      final failures = <SfuSessionFailure>[];
      session.failures.listen(failures.add);
      h.broker.onNewTracks = (_, _) async =>
          throw const BrokerException(operation: 'tracks/new', statusCode: 500);
      h.pc.failNext('rollback', 'rollback not supported');

      await expectLater(
        session.publish(FakeMediaStreamTrack(kind: 'audio')),
        throwsA(isA<BrokerException>()),
      );
      await pumpEventQueue();

      expect(
        failures.single,
        isA<SfuPeerConnectionFailed>().having(
          (f) => f.kind,
          'kind',
          PeerConnectionFailureKind.signalingStuck,
        ),
      );
      expect(session.currentConnectionState, SfuConnectionState.failed);
      expect(
        () => session.subscribe(remoteSessionId: 'p', trackName: 't'),
        throwsA(isA<SfuSessionFailedException>()),
      );
    });

    test('a per-track push error stops that transceiver; republish starts '
        'clean', () async {
      final first = await h.connect();
      final pub = await first.publish(
        FakeMediaStreamTrack(kind: 'video'),
        options: const PublishOptions(trackName: 'cam'),
      );
      await first.close();
      final session = await h.connect();

      h.broker.onNewTracks = (sessionId, request) async {
        final ok = await h.broker.defaultNewTracks(sessionId, request);
        return TracksResponse(
          sessionDescription: ok.sessionDescription,
          tracks: [
            TrackResult(mid: ok.tracks.single.mid, errorCode: 'invalid_track'),
          ],
        );
      };
      await expectLater(
        session.republish(pub),
        throwsA(isA<SfuTrackException>()),
      );
      final rejected = h.pc.transceivers.single;
      expect(rejected.stopped, isTrue);
      expect(pub.state, SfuTrackState.failed);
      expect(pub.mid, isNull);
      expect(h.pc.currentSignalingState, stable);

      h.broker.onNewTracks = null;
      await session.republish(pub);
      expect(pub.state, SfuTrackState.active);
      final fresh = h.pc.transceivers.last;
      expect(fresh, isNot(same(rejected)));
      expect(h.pc.offeredSenders.last, [fresh]);
    });
  });

  group('replacing the session', () {
    test('republish and resubscribe move tracks to a new session', () async {
      final first = await h.connect();
      final firstPc = h.pc;
      final pub = await first.publish(
        FakeMediaStreamTrack(kind: 'video'),
        options: const PublishOptions(trackName: 'cam'),
      );
      final sub = await first.subscribe(
        remoteSessionId: 'peer-old',
        trackName: 'their-cam',
        preferredRid: 'b',
      );
      final oldTrack = sub.track;
      final tracks = <MediaStreamTrack>[];
      sub.trackStream.listen(tracks.add);

      firstPc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      expect(pub.state, SfuTrackState.interrupted);
      expect(sub.state, SfuTrackState.interrupted);

      // M5 would do this: new session, re-push, re-pull.
      final second = await h.connect();
      await first.close();
      final swapped = FakeMediaStreamTrack(kind: 'video', id: 'swapped');
      await pub.replaceTrack(swapped); // While not on any session.
      await second.republish(pub);
      await second.resubscribe(sub, remoteSessionId: 'peer-new');

      expect(pub.state, SfuTrackState.active);
      expect(pub.sessionId, 'session-2');
      expect(pub.trackName, 'cam');
      expect(h.pc.transceivers.first.sentTrack, same(swapped));
      expect(sub.state, SfuTrackState.active);
      expect(sub.remoteSessionId, 'peer-new');
      expect(sub.track, isNot(same(oldTrack)));
      final pull = h.broker.callsTo('tracks/new').last;
      expect(_tracksJson(pull).single, {
        'location': 'remote',
        'sessionId': 'peer-new',
        'trackName': 'their-cam',
        'simulcast': {'preferredRid': 'b', 'ridNotAvailable': 'asciibetical'},
      });
      await pumpEventQueue();
      expect(tracks, [oldTrack, sub.track]);
      expect(firstPc.closed, isTrue);
      expect(h.broker.forgotten, ['session-1']);
    });

    test('republish is refused while still on a session', () async {
      final a = await h.connect();
      final b = await h.connect();
      final pub = await a.publish(FakeMediaStreamTrack(kind: 'audio'));
      expect(() => b.republish(pub), throwsStateError);
    });

    test('a failed republish leaves the publication retryable', () async {
      final first = await h.connect();
      final pub = await first.publish(
        FakeMediaStreamTrack(kind: 'audio'),
        options: const PublishOptions(trackName: 'mic'),
      );
      await first.close();
      final second = await h.connect();

      h.broker.onNewTracks = (_, _) async =>
          throw const BrokerNetworkException(operation: 'tracks/new');
      await expectLater(
        second.republish(pub),
        throwsA(isA<BrokerNetworkException>()),
      );
      expect(pub.state, SfuTrackState.failed);
      expect(pub.error, isA<BrokerNetworkException>());
      expect(pub.session, isNull);

      h.broker.onNewTracks = null;
      await second.republish(pub);
      expect(pub.state, SfuTrackState.active);
      expect(pub.error, isNull);
    });
  });

  group('close()', () {
    test(
      'closes the PC, fails queued operations and forgets the session',
      () async {
        final session = await h.connect();
        final pub = await session.publish(FakeMediaStreamTrack(kind: 'audio'));
        final gate = Completer<void>();
        h.broker.onNewTracks = (sessionId, request) async {
          await gate.future;
          return h.broker.defaultNewTracks(sessionId, request);
        };
        final inFlight = session.subscribe(
          remoteSessionId: 'p',
          trackName: 'a',
        );
        await pumpEventQueue();
        final queued = session.subscribe(remoteSessionId: 'p', trackName: 'b');

        await session.close();
        gate.complete();

        await Future.wait([
          expectLater(inFlight, throwsA(isA<SfuSessionClosedException>())),
          expectLater(queued, throwsA(isA<SfuSessionClosedException>())),
        ]);
        expect(h.pc.closed, isTrue);
        expect(h.broker.forgotten, ['session-1']);
        expect(session.isClosed, isTrue);
        expect(session.currentConnectionState, SfuConnectionState.closed);
        expect(pub.state, SfuTrackState.interrupted);
        expect(session.failure, isNull);
        expect(await session.failures.toList(), isEmpty);
        expect(
          () => session.publish(FakeMediaStreamTrack(kind: 'audio')),
          throwsA(isA<SfuSessionClosedException>()),
        );
        await session.close(); // Idempotent.
      },
    );
  });

  // The SFU renumbers a pushed codec to the BUNDLE's number once the
  // session has pulled a video, but leaves its RTX `apt` as offered, which
  // libwebrtc (and the fake) rejects. Seen pushing an iOS screen share after
  // the microphone and a pulled camera.
  group("the SFU's RTX payload types", () {
    test(
      'a push after a pull applies the answer with its apt repaired',
      () async {
        final session = await h.connect();
        await session.subscribe(remoteSessionId: 'p', trackName: 'cam');
        h.broker.onNewTracks = (sessionId, request) async {
          final ok = await h.broker.defaultNewTracks(sessionId, request);
          // What libwebrtc holds as the local description by now.
          h.pc.currentLocalDescription = SessionDescription.offer(
            pushAfterPullOffer,
          );
          return TracksResponse(
            sessionDescription: SessionDescription.answer(pushAfterPullAnswer),
            tracks: ok.tracks,
          );
        };

        final pub = await session.publish(
          FakeMediaStreamTrack(kind: 'video'),
          options: const PublishOptions(sendEncodings: []),
        );

        expect(pub.state, SfuTrackState.active);
        expect(session.failure, isNull);
        final applied = h.pc.remoteDescription!;
        expect(applied.type, SdpType.answer);
        expect(
          applied.sdp,
          contains(
            'm=video 9 UDP/TLS/RTP/SAVPF 96 101\r\na=mid:2\r\n'
            'a=rtpmap:96 VP8/90000\r\na=rtpmap:101 rtx/90000\r\n'
            'a=fmtp:101 apt=96\r\n',
          ),
        );
      },
    );

    test('an SFU offer is repaired before it is answered', () async {
      final session = await h.connect();
      final sub = await session.subscribe(remoteSessionId: 'p', trackName: 't');
      h.pc.currentLocalDescription = SessionDescription.offer(
        pushAfterPullOffer,
      );
      h.broker.onUpdateTracks = (sessionId, request) async {
        final ok = await h.broker.defaultUpdateTracks(sessionId, request);
        return TracksResponse(
          requiresImmediateRenegotiation: true,
          sessionDescription: SessionDescription.offer(pushAfterPullAnswer),
          tracks: ok.tracks,
        );
      };

      await sub.setPreferredRid('b');

      expect(h.broker.operations.last, 'renegotiate');
      expect(h.pc.remoteDescription!.type, SdpType.offer);
      expect(h.pc.remoteDescription!.sdp, contains('a=fmtp:101 apt=96\r\n'));
      expect(session.failure, isNull);
    });

    test('a close answer is repaired too', () async {
      final session = await h.connect();
      await session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final video = await session.publish(FakeMediaStreamTrack(kind: 'video'));
      h.broker.onCloseTracks = (sessionId, request) async {
        final ok = await h.broker.defaultCloseTracks(sessionId, request);
        h.pc.currentLocalDescription = SessionDescription.offer(
          pushAfterPullOffer,
        );
        return TracksResponse(
          sessionDescription: SessionDescription.answer(pushAfterPullAnswer),
          tracks: ok.tracks,
        );
      };

      await video.unpublish();

      expect(video.state, SfuTrackState.closed);
      expect(h.pc.remoteDescription!.sdp, contains('a=fmtp:101 apt=96\r\n'));
      expect(session.failure, isNull);
    });
  });
}
