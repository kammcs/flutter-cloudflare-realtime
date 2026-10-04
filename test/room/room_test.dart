import 'dart:async';

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart'
    show RTCIceConnectionState, RTCPeerConnectionState;

import '../support/room_harness.dart';

const _mic = TrackInfo(kind: TrackKind.audio, source: TrackSource.microphone);
const _cam = TrackInfo(kind: TrackKind.video, source: TrackSource.camera);

Future<void> _settle() => pumpEventQueue(times: 50);

/// Records a room's events.
List<RoomEvent> _record(Room room) {
  final events = <RoomEvent>[];
  room.events.listen(events.add);
  return events;
}

/// A signaling participant driven by the test (no SFU session of its own),
/// for states a Room can't produce yet, such as a session change.
class _Puppet {
  _Puppet(this.h, this.id);

  final RoomHarness h;
  final String id;
  late final InMemorySignaling signaling = InMemorySignaling(h.hub);

  Future<void> join(
    String? sessionId, [
    Map<String, TrackInfo> tracks = const {},
  ]) {
    _record(sessionId, tracks);
    return signaling.join(
      'room',
      ParticipantState(participantId: id, sessionId: sessionId, tracks: tracks),
    );
  }

  Future<void> update(
    String? sessionId, [
    Map<String, TrackInfo> tracks = const {},
  ]) {
    _record(sessionId, tracks);
    return signaling.update(
      ParticipantState(participantId: id, sessionId: sessionId, tracks: tracks),
    );
  }

  void _record(String? sessionId, Map<String, TrackInfo> tracks) {
    for (final MapEntry(key: name, value: info) in tracks.entries) {
      h.broker.trackKinds['$sessionId/$name'] = info.kind.name;
    }
  }
}

/// A [Signaling] whose updates fail on demand.
class _FlakySignaling implements Signaling {
  _FlakySignaling(InMemorySignalingHub hub) : _inner = InMemorySignaling(hub);

  final InMemorySignaling _inner;
  bool failUpdates = false;
  int updates = 0;

  @override
  Future<void> join(String roomId, ParticipantState self) =>
      _inner.join(roomId, self);

  @override
  Future<void> update(ParticipantState self) async {
    updates++;
    if (failUpdates) throw StateError('presence is down');
    await _inner.update(self);
  }

  @override
  Stream<List<ParticipantState>> get participants => _inner.participants;

  @override
  Future<void> leave() => _inner.leave();
}

void main() {
  late RoomHarness h;

  setUp(() => h = RoomHarness());

  group('join', () {
    test('creates a broker client and a session, then joins signaling '
        'with the session ID', () async {
      final room = await h.join('alice', metadata: {'displayName': 'Alice'});

      expect(h.brokerRooms, ['room']);
      expect(room.roomId, 'room');
      expect(room.session.sessionId, 'session-1');
      expect(room.localParticipant.participantId, 'alice');
      expect(room.localParticipant.sessionId, 'session-1');
      expect(
        h.announced('alice'),
        ParticipantState(
          participantId: 'alice',
          sessionId: 'session-1',
          metadata: const {'displayName': 'Alice'},
          // It reports what it pulls (nothing yet), so publishers can pause
          // the layers no one pulls.
          layerDemand: const {},
        ),
      );
      expect(room.connectionState, RoomConnectionState.connected);
      expect(room.participants, isEmpty);
      expect(room.failure, isNull);
      await room.leave();
    });

    test('a failed session leaves nothing open', () async {
      h.connectError = const BrokerUnauthorizedException(
        operation: 'sessions/new',
      );
      await expectLater(
        h.join('alice'),
        throwsA(isA<BrokerUnauthorizedException>()),
      );
      expect(h.broker.disposed, isTrue);
      expect(h.hub.roomIds, isEmpty);
    });

    test('a failed signaling join closes the session', () async {
      final alice = await h.join('alice');
      await expectLater(h.join('alice'), throwsStateError);
      expect(h.sessions.peerConnections.last.closed, isTrue);
      expect(h.broker.forgotten, ['session-2']);
      expect(h.hub.participantsIn('room'), hasLength(1));
      await alice.leave();
    });

    test('rejects empty IDs', () {
      expect(
        () => h.realtime.join(
          '',
          signaling: InMemorySignaling(h.hub),
          participantId: 'a',
        ),
        throwsArgumentError,
      );
      expect(
        () => h.realtime.join(
          'room',
          signaling: InMemorySignaling(h.hub),
          participantId: '',
        ),
        throwsArgumentError,
      );
    });
  });

  group('four participants', () {
    test('join, publish, mute, unpublish, reconnect and leave', () async {
      final alice = await h.join('alice', metadata: {'name': 'Alice'});
      final bob = await h.join('bob');
      final carol = await h.join('carol');
      final dave = _Puppet(h, 'dave');
      await dave.join('dave-1', {'dave-mic': _mic, 'dave-cam': _cam});
      await _settle();

      final bobEvents = _record(bob);

      // Everyone sees the others, never themselves.
      List<String> ids(Room r) => [
        for (final p in r.participants) p.participantId,
      ];
      expect(ids(alice), ['bob', 'carol', 'dave']);
      expect(ids(bob), ['alice', 'carol', 'dave']);
      expect(ids(carol), ['alice', 'bob', 'dave']);
      expect(bob.participant('alice')!.metadata, {'name': 'Alice'});
      expect(bob.participant('alice')!.sessionId, 'session-1');

      // Audio is pulled at once; video is not.
      expect(h.pullsOf(bob), ['dave-1/dave-mic']);
      final bobDave = bob.participant('dave')!;
      expect(bobDave.microphone!.isSubscribed, isTrue);
      expect(bobDave.microphone!.track, isNotNull);
      expect(bobDave.camera!.isSubscribed, isFalse);
      expect(bobDave.camera!.track, isNull);

      // Alice publishes a microphone and a camera.
      final mic = await alice.localParticipant.publishMicrophone();
      final cam = await alice.localParticipant.publishCamera();
      await _settle();
      final announced = h.announced('alice')!;
      expect(announced.tracks, {
        mic.trackName: _mic,
        cam.trackName: _cam.copyWith(
          simulcast: SimulcastInfo(
            rids: const ['a', 'b', 'c'],
            width: 1280,
            height: 720,
            scaleDownBy: const [1, 2, 4],
          ),
        ),
      });
      expect(mic.trackName, startsWith('microphone-'));
      expect(cam.trackName, startsWith('camera-'));

      final bobAlice = bob.participant('alice')!;
      expect(bobAlice.microphone!.trackName, mic.trackName);
      expect(bobAlice.camera!.trackName, cam.trackName);
      expect(bobAlice.trackPublications, hasLength(2));
      expect(h.pullsOf(bob), ['dave-1/dave-mic', 'session-1/${mic.trackName}']);
      expect(h.pullsOf(carol), [
        'dave-1/dave-mic',
        'session-1/${mic.trackName}',
      ]);
      expect(bobAlice.microphone!.track!.track.kind, 'audio');
      expect(
        bobEvents.whereType<TrackPublishedEvent>().map((e) => e.publication),
        containsAll([bobAlice.microphone, bobAlice.camera]),
      );

      // Bob opens Alice's camera: pulled at the gallery layer.
      await bobAlice.camera!.subscribe();
      expect(h.pullsOf(bob).last, 'session-1/${cam.trackName}@b');
      final camTrack = bobAlice.camera!.track!;
      expect(camTrack.track.kind, 'video');
      expect(camTrack.stream.getVideoTracks().single, same(camTrack.track));
      expect(
        bobEvents.whereType<TrackSubscribedEvent>().last.publication,
        bobAlice.camera,
      );
      expect(h.pullsOf(carol), hasLength(2), reason: 'carol never asked');

      // Alice mutes her microphone: announced, and Bob keeps the pull.
      await mic.mute();
      await _settle();
      expect(h.announced('alice')!.tracks[mic.trackName]!.muted, isTrue);
      expect(bobAlice.microphone!.isMuted, isTrue);
      expect(bobEvents.whereType<TrackMutedEvent>().single.muted, isTrue);
      expect(bobAlice.microphone!.subscriptionState, SfuTrackState.active);
      await mic.unmute();
      await _settle();
      expect(bobAlice.microphone!.isMuted, isFalse);

      // Alice unpublishes her camera: Bob's pull is closed.
      final camMid = bobAlice.camera!.subscription!.mid!;
      final camPublication = bobAlice.camera!;
      await cam.unpublish();
      await _settle();
      expect(h.announced('alice')!.tracks.keys, [mic.trackName]);
      expect(bobAlice.camera, isNull);
      expect(camPublication.isClosed, isTrue);
      expect(camPublication.track, isNull);
      expect(h.closesOf(bob), [camMid]);
      expect((camTrack.stream as FakeWrappedStream).disposed, isTrue);
      expect(
        bobEvents.whereType<TrackUnpublishedEvent>().single.publication,
        camPublication,
      );

      // Dave reconnects: Bob pulls his microphone from the new session.
      final daveMic = bobDave.microphone!;
      final oldMid = daveMic.subscription!.mid!;
      final oldTrack = daveMic.track!;
      await dave.update('dave-2', {'dave-mic': _mic, 'dave-cam': _cam});
      await _settle();
      expect(bobDave.sessionId, 'dave-2');
      expect(h.closesOf(bob), [camMid, oldMid]);
      expect(h.pullsOf(bob).last, 'dave-2/dave-mic');
      expect(daveMic.subscription!.remoteSessionId, 'dave-2');
      expect(daveMic.track, isNot(oldTrack));
      expect((oldTrack.stream as FakeWrappedStream).disposed, isTrue);
      expect(
        bobEvents.whereType<ParticipantUpdatedEvent>().last.sessionChanged,
        isTrue,
      );
      expect(bobDave.camera!.isSubscribed, isFalse, reason: 'still unasked');

      // Carol leaves: the others see it, and close their pulls of her.
      await carol.leave();
      await _settle();
      expect(ids(alice), ['bob', 'dave']);
      expect(ids(bob), ['alice', 'dave']);
      expect(
        bobEvents
            .whereType<ParticipantLeftEvent>()
            .single
            .participant
            .participantId,
        'carol',
      );

      // Dave leaves: Bob closes his microphone pull.
      final daveMicMid = daveMic.subscription!.mid!;
      await dave.signaling.leave();
      await _settle();
      expect(ids(bob), ['alice']);
      expect(h.closesOf(bob).last, daveMicMid);
      expect(bobDave.isPresent, isFalse);

      await alice.leave();
      await bob.leave();
      await dave.signaling.dispose();
    });
  });

  group('pull-on-subscribe', () {
    late Room bob;
    late _Puppet ann;

    setUp(() async {
      bob = await h.join('bob');
      ann = _Puppet(h, 'ann');
    });

    tearDown(() async {
      await bob.leave();
      await ann.signaling.dispose();
    });

    test('AutoSubscribe.all pulls video too; none pulls nothing', () async {
      final eve = await h.join(
        'eve',
        options: const RoomOptions(
          connectEarly: false,
          autoSubscribe: AutoSubscribe.all,
        ),
      );
      final zed = await h.join(
        'zed',
        options: const RoomOptions(
          connectEarly: false,
          autoSubscribe: AutoSubscribe.none,
        ),
      );
      await ann.join('ann-1', {'m': _mic, 'c': _cam});
      await _settle();
      expect(h.pullsOf(eve), ['ann-1/m', 'ann-1/c']);
      expect(h.pullsOf(zed), isEmpty);
      await eve.leave();
      await zed.leave();
    });

    test('video without a simulcast hint is pulled without a layer; '
        'layers map to rids', () async {
      final layered = _cam.copyWith(
        simulcast: SimulcastInfo(rids: const ['a', 'b']),
      );
      await ann.join('ann-1', {'plain': _cam, 'layered': layered});
      await _settle();
      final plain = bob.participant('ann')!.trackPublication('plain')!;
      final withLayers = bob.participant('ann')!.trackPublication('layered')!;

      await plain.subscribe();
      await withLayers.subscribe();
      expect(h.pullsOf(bob), ['ann-1/plain', 'ann-1/layered@b']);

      await withLayers.setPreferredLayer(SimulcastLayer.high);
      await withLayers.setPreferredLayer(SimulcastLayer.low);
      await _settle();
      final updates = [
        for (final c in h.callsOf(bob, 'tracks/update'))
          for (final t in (c.request! as UpdateTracksRequest).tracks)
            t.simulcast!.preferredRid,
      ];
      // `low` is the lowest advertised layer, `b`.
      expect(updates, ['a', 'b']);
      expect(withLayers.subscription!.preferredRid, 'b');
      expect(withLayers.preferredLayer, SimulcastLayer.low);
    });

    test('the default layer is configurable', () async {
      final eve = await h.join(
        'eve',
        options: const RoomOptions(
          connectEarly: false,
          defaultVideoLayer: SimulcastLayer.low,
        ),
      );
      await ann.join('ann-1', {
        'c': _cam.copyWith(
          simulcast: SimulcastInfo(rids: const ['a', 'b', 'c']),
        ),
      });
      await _settle();
      await eve.participant('ann')!.camera!.subscribe();
      expect(h.pullsOf(eve), ['ann-1/c@c']);
      await eve.leave();
    });

    test('unsubscribe closes the pull; subscribe pulls again', () async {
      await ann.join('ann-1', {'c': _cam});
      await _settle();
      final cam = bob.participant('ann')!.camera!;
      final changes = <bool>[];
      cam.changes.listen((p) => changes.add(p.isSubscribed));

      await cam.subscribe();
      final mid = cam.subscription!.mid!;
      final stream = cam.track!.stream as FakeWrappedStream;
      await cam.unsubscribe();
      expect(cam.isSubscribed, isFalse);
      expect(cam.subscription, isNull);
      expect(cam.track, isNull);
      expect(stream.disposed, isTrue);
      expect(h.closesOf(bob), [mid]);

      await cam.subscribe();
      expect(h.pullsOf(bob), ['ann-1/c', 'ann-1/c']);
      expect(cam.track, isNotNull);
      await _settle();
      expect(changes, containsAllInOrder([true, false, true]));
    });

    test('unwrapping only disposes the wrapper stream: the remote track is '
        'neither removed from it nor stopped', () async {
      // Native flutter_webrtc 1.6: `streamDispose` drops the stream and
      // detaches its tracks without stopping them (Android, Darwin,
      // Windows), while `mediaStreamRemoveTrack` only finds local tracks on
      // Android and Darwin, so it must not be called for a pulled track.
      await ann.join('ann-1', {'c': _cam});
      await _settle();
      final cam = bob.participant('ann')!.camera!;
      await cam.subscribe();
      final renderable = cam.track!;
      final stream = renderable.stream as FakeWrappedStream;
      final track = renderable.track as FakeMediaStreamTrack;

      await cam.unsubscribe();
      await _settle();
      expect(stream.calls, ['dispose']);
      expect(track.stopped, isFalse);

      // Pulling again wraps the new track in a new stream.
      await cam.subscribe();
      expect(cam.track!.stream, isNot(same(stream)));
      expect(h.wrapped, hasLength(2));
    });

    test('leases keep a track pulled until the last one is released', () async {
      // No grace period, so releases take effect at once.
      final eve = await h.join(
        'eve',
        options: const RoomOptions(
          connectEarly: false,
          leaseReleaseGrace: Duration.zero,
        ),
      );
      addTearDown(eve.leave);
      await ann.join('ann-1', {'c': _cam});
      await _settle();
      final cam = eve.participant('ann')!.camera!;

      final first = cam.retain();
      final second = cam.retain();
      await _settle();
      expect(h.pullsOf(eve), ['ann-1/c']);

      await cam.unsubscribe();
      expect(cam.isSubscribed, isTrue, reason: 'leases still hold it');
      first.release();
      first.release();
      await _settle();
      expect(cam.isSubscribed, isTrue);
      expect(h.closesOf(eve), isEmpty);

      second.release();
      await _settle();
      expect(cam.isSubscribed, isFalse);
      expect(h.closesOf(eve), hasLength(1));
      expect(first.isReleased && second.isReleased, isTrue);
    });

    test('ignores participants until they have a session', () async {
      await ann.join(null, {'m': _mic});
      await _settle();
      expect(bob.participants, isEmpty);
      expect(h.pullsOf(bob), isEmpty);

      await ann.update('ann-1', {'m': _mic});
      await _settle();
      expect(bob.participant('ann'), isNotNull);
      expect(h.pullsOf(bob), ['ann-1/m']);

      // Losing the session counts as leaving.
      await ann.update(null, {'m': _mic});
      await _settle();
      expect(bob.participants, isEmpty);
      expect(h.closesOf(bob), hasLength(1));
    });

    test('participants emits on every change', () async {
      final lists = <List<String>>[];
      bob.participantsChanges.listen(
        (list) => lists.add([
          for (final p in list)
            '${p.participantId}:${p.trackPublications.length}',
        ]),
      );
      await ann.join('ann-1');
      await _settle();
      await ann.update('ann-1', {'m': _mic});
      await _settle();
      await ann.signaling.leave();
      await _settle();
      expect(lists, [
        <String>[],
        ['ann:0'],
        ['ann:1'],
        <String>[],
      ]);
    });

    test('a pull error before the publisher sends is retried', () {
      fakeAsync((async) {
        void pump() {
          for (var i = 0; i < 30; i++) {
            async.elapse(Duration.zero);
          }
        }

        late Room eve;
        h
            .join(
              'eve',
              options: const RoomOptions(
                connectEarly: false,
                pullRetry: BackoffOptions(
                  initialDelay: Duration(seconds: 1),
                  maxDelay: Duration(seconds: 1),
                  maxAttempts: 2,
                  maxElapsed: null,
                ),
              ),
            )
            .then((r) => eve = r);
        pump();
        final events = _record(eve);

        var failures = 3;
        h.broker.onNewTracks = (sessionId, request) async {
          if (failures > 0 && request.sessionDescription == null) {
            failures--;
            return TracksResponse(
              tracks: [
                for (final t in request.tracks)
                  TrackResult(
                    trackName: t.trackName,
                    sessionId: t.sessionId,
                    errorCode: 'track_not_found',
                  ),
              ],
            );
          }
          return h.broker.defaultNewTracks(sessionId, request);
        };

        ann.join('ann-1', {'m': _mic.copyWith(muted: true)});
        pump();
        final mic = eve.participant('ann')!.microphone!;
        expect(mic.error, isA<SfuTrackException>());
        expect(mic.track, isNull);

        async.elapse(const Duration(seconds: 1));
        pump();
        async.elapse(const Duration(seconds: 1));
        pump();
        final failed = events.whereType<TrackSubscriptionFailedEvent>();
        expect([for (final e in failed) e.willRetry], [true, true, false]);
        expect(mic.track, isNull, reason: 'retries exhausted');

        // Unmuting is a change worth another try.
        ann.update('ann-1', {'m': _mic});
        pump();
        expect(mic.error, isNull);
        expect(mic.track, isNotNull);
        expect(mic.subscriptionState, SfuTrackState.active);
        expect(events.whereType<TrackSubscribedEvent>(), hasLength(1));

        eve.leave();
        pump();
      });
    });
  });

  group('local participant', () {
    late Room alice;

    setUp(() async => alice = await h.join('alice'));

    tearDown(() => alice.leave());

    test(
      'sends what the source broadcasts, and mutes by sending nothing',
      () async {
        final cam = await alice.localParticipant.publishCamera();
        final pc = h.pcOf(alice);
        final transceiver = pc.transceivers.single;
        expect(transceiver.kind, 'video');
        expect(transceiver.sendEncodings, SimulcastPresets.h720);
        expect(transceiver.sentTrack, same(cam.mediaSource.track!.track));
        expect(cam.isMuted, isFalse);
        expect(cam.ownsMediaSource, isTrue);
        expect(alice.localParticipant.camera, cam);

        await cam.mute();
        await _settle();
        expect(cam.isMuted, isTrue);
        expect(transceiver.sentTrack, isNull);
        expect(cam.mediaSource.isEnabled, isFalse, reason: 'camera light off');
        expect(h.announced('alice')!.tracks[cam.trackName]!.muted, isTrue);

        expect(await cam.unmute(), isTrue);
        await _settle();
        expect(transceiver.sentTrack, isNotNull);
        expect(h.announced('alice')!.tracks[cam.trackName]!.muted, isFalse);
        expect(
          h.callsOf(alice, 'tracks/new'),
          hasLength(1),
          reason: 'muting never renegotiates',
        );
      },
    );

    test(
      'switchCamera moves the published camera, keeping the track',
      () async {
        h.media.setDevices([cam1, cam2, mic1]);
        final cam = await alice.localParticipant.publishCamera();
        final transceiver = h.pcOf(alice).transceivers.single;
        expect(cam.mediaSource.track!.device, cam1);

        expect(await alice.localParticipant.switchCamera(), cam2);
        await _settle();
        expect(cam.mediaSource.track!.device, cam2);
        expect(transceiver.sentTrack, same(cam.mediaSource.track!.track));
        expect(alice.localParticipant.camera, cam);
        expect(
          h.callsOf(alice, 'tracks/new'),
          hasLength(1),
          reason: 'switching never renegotiates',
        );
      },
    );

    test('switchCamera without a published camera throws', () {
      expect(alice.localParticipant.switchCamera, throwsStateError);
    });

    test('publishes muted without capturing', () async {
      final mic = await alice.localParticipant.publishMicrophone(muted: true);
      expect(h.media.userMediaCalls, isEmpty);
      expect(
        h.announced('alice')!.tracks[mic.trackName],
        _mic.copyWith(muted: true),
      );
      expect(h.pcOf(alice).transceivers.single.sentTrack, isNull);

      expect(await mic.setMuted(false), isFalse);
      await _settle();
      expect(h.media.userMediaCalls, hasLength(1));
      expect(h.announced('alice')!.tracks[mic.trackName]!.muted, isFalse);
    });

    test('custom encodings are sent and announced', () async {
      final cam = await alice.localParticipant.publishCamera(
        options: const CameraOptions(preset: VideoPreset.h360),
        encodings: SimulcastPresets.h360,
      );
      expect(
        h.pcOf(alice).transceivers.single.sendEncodings,
        SimulcastPresets.h360,
      );
      expect(cam.simulcast!.height, 360);

      final single = await alice.localParticipant.publishCamera(
        encodings: const [],
      );
      expect(single.simulcast, isNull);
      expect(h.announced('alice')!.tracks[single.trackName]!.simulcast, isNull);
    });

    test('a capture failure throws and announces nothing', () async {
      h.media.userMediaError = 'Unable to getUserMedia: NotAllowedError';
      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(isA<MediaPermissionDeniedException>()),
      );
      expect(alice.localParticipant.trackPublications, isEmpty);
      expect(h.callsOf(alice, 'tracks/new'), isEmpty);
      expect(h.announced('alice')!.tracks, isEmpty);
    });

    test('an SFU rejection throws and disposes the source', () async {
      h.broker.onNewTracks = (sessionId, request) async => TracksResponse(
        sessionDescription: SessionDescription.answer('x'),
        tracks: [
          for (final t in request.tracks)
            TrackResult(
              mid: t.mid,
              trackName: t.trackName,
              errorCode: 'invalid_track',
            ),
        ],
      );
      await expectLater(
        alice.localParticipant.publishMicrophone(),
        throwsA(isA<SfuTrackException>()),
      );
      expect(h.media.streams.single.track.stopped, isTrue);
      expect(h.announced('alice')!.tracks, isEmpty);
    });

    test('unpublish announces, closes and disposes', () async {
      final events = _record(alice);
      final mic = await alice.localParticipant.publishMicrophone();
      final mid = mic.publication.mid!;
      await mic.unpublish();
      await mic.unpublish();
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(h.closesOf(alice), [mid]);
      expect(mic.isPublished, isFalse);
      expect(mic.mediaSource.isDisposed, isTrue);
      expect(() => mic.mute(), throwsStateError);
      await _settle();
      expect(events.whereType<LocalTrackPublishedEvent>(), hasLength(1));
      expect(events.whereType<LocalTrackUnpublishedEvent>(), hasLength(1));
    });

    test('an app-owned source is announced but never disposed', () async {
      final camera = CameraSource(backend: h.media);
      final pub = await alice.localParticipant.publishMediaSource(camera);
      expect(pub.isMuted, isTrue, reason: 'not broadcasting yet');
      expect(
        h.announced('alice')!.tracks[pub.trackName],
        _cam.copyWith(muted: true),
      );

      await camera.startBroadcasting();
      await _settle();
      expect(h.announced('alice')!.tracks[pub.trackName]!.muted, isFalse);

      await pub.unpublish();
      expect(camera.isDisposed, isFalse);
      await camera.dispose();
    });

    test('setMetadata is announced', () async {
      final changes = <LocalParticipant>[];
      alice.localParticipant.changes.listen(changes.add);
      await alice.localParticipant.setMetadata({'hand': 'raised'});
      expect(h.announced('alice')!.metadata, {'hand': 'raised'});
      expect(alice.localParticipant.metadata, {'hand': 'raised'});
      await _settle();
      expect(changes, isNotEmpty);
    });

    test('a failing signaling update is reported and retried on the next '
        'change', () async {
      final signaling = _FlakySignaling(h.hub);
      final eve = await h.join('eve', signaling: signaling);
      final events = _record(eve);
      signaling.failUpdates = true;
      final mic = await eve.localParticipant.publishMicrophone();
      await _settle();
      final errors = events.whereType<RoomErrorEvent>();
      expect(errors, isNotEmpty);
      expect({for (final e in errors) e.operation}, {'signaling.update'});
      expect(h.announced('eve')!.tracks, isEmpty);

      signaling.failUpdates = false;
      await mic.mute();
      await _settle();
      expect(h.announced('eve')!.tracks[mic.trackName]!.muted, isTrue);
      await eve.leave();
    });
  });

  group('macOS microphone', () {
    const macDefault = MediaDevice(
      deviceId: 'default',
      kind: MediaDeviceKind.audioInput,
      label: 'Default',
      isDefault: true,
    );

    setUp(() {
      h = RoomHarness(
        media: FakeMediaBackend(
          platform: MediaPlatform.macos,
          devices: [cam1, macDefault, mic1],
        ),
      );
    });

    test('publishes the default without listing the devices', () async {
      final alice = await h.join('alice');
      final mic = await alice.localParticipant.publishMicrophone();
      await _settle();
      expect(await mic.setMuted(true), isTrue);
      expect(await mic.setMuted(false), isFalse);
      await _settle();
      expect(h.media.enumerateCalls, 0);
      expect(h.media.userMediaCalls, hasLength(1));
      expect((h.media.userMediaCalls.single['audio'] as Map)['optional'], [
        {'sourceId': 'default'},
      ]);
      expect(h.pcOf(alice).transceivers.single.sentTrack, isNotNull);

      // A camera lists them, and the microphone keeps its capture.
      await alice.localParticipant.publishCamera();
      await _settle();
      expect(h.media.enumerateCalls, 1);
      expect(h.media.userMediaCalls, hasLength(2));
      await alice.leave();
    });

    test('a chosen microphone lists the devices first', () async {
      final alice = await h.join('alice');
      await alice.localParticipant.publishMicrophone(device: mic1);
      expect(h.media.enumerateCalls, 1);
      expect((h.media.userMediaCalls.single['audio'] as Map)['optional'], [
        {'sourceId': mic1.deviceId},
      ]);
      await alice.leave();
    });
  });

  group('screen share', () {
    final screen1 = const ScreenSource(
      id: 'screen-1',
      name: 'Screen 1',
      type: ScreenSourceType.screen,
    );
    late FakeDesktopCapturer desktop;

    setUp(() {
      desktop = FakeDesktopCapturer([screen1]);
      h = RoomHarness(
        media: FakeMediaBackend(devices: [cam1, mic1], desktop: desktop),
      );
    });

    test('is published as one layer and unpublished when the source '
        'goes away', () async {
      final alice = await h.join('alice');
      final bob = await h.join('bob');
      final events = _record(alice);

      final share = await alice.localParticipant.publishScreen(source: screen1);
      expect(share.source, TrackSource.screen);
      expect(share.simulcast, isNull);
      expect(
        h.pcOf(alice).transceivers.single.sendEncodings,
        ScreenSharePresets.detail,
      );
      await _settle();
      expect(
        h.announced('alice')!.tracks[share.trackName],
        const TrackInfo(kind: TrackKind.video, source: TrackSource.screen),
      );
      final remote = bob.participant('alice')!.screen!;
      await remote.subscribe();
      expect(h.pullsOf(bob), ['session-1/${share.trackName}']);

      // The shared display disappears.
      desktop.removed.add(screen1);
      await _settle();
      expect(share.isPublished, isFalse);
      expect(alice.localParticipant.screen, isNull);
      expect(h.announced('alice')!.tracks, isEmpty);
      expect(bob.participant('alice')!.screen, isNull);
      expect(events.whereType<LocalTrackUnpublishedEvent>(), hasLength(1));

      await alice.leave();
      await bob.leave();
    });

    test('with system audio publishes a screenAudio track too', () async {
      final alice = await h.join('alice');
      final share = await alice.localParticipant.publishScreen(
        source: screen1,
        options: const ScreenShareOptions(captureAudio: true),
      );
      final audio = alice.localParticipant.screenAudio!;
      expect(audio.kind, TrackKind.audio);
      expect(audio.ownsMediaSource, isFalse);
      expect(h.announced('alice')!.tracks.keys, [
        share.trackName,
        audio.trackName,
      ]);

      await share.unpublish();
      expect(audio.isPublished, isFalse);
      expect(h.announced('alice')!.tracks, isEmpty);
      await alice.leave();
    });

    test('needs a source on desktop', () async {
      final alice = await h.join('alice');
      await expectLater(
        alice.localParticipant.publishScreen(),
        throwsArgumentError,
      );
      expect(alice.localParticipant.trackPublications, isEmpty);
      await alice.leave();
    });
  });

  group('connection state', () {
    test('follows the session; without automatic reconnection a failure '
        'disconnects with an event', () async {
      final room = await h.join(
        'alice',
        options: const RoomOptions(
          connectEarly: false,
          reconnect: ReconnectOptions.disabled,
        ),
      );
      final events = _record(room);
      final states = <RoomConnectionState>[];
      room.connectionStateChanges.listen(states.add);
      final pc = h.pcOf(room);

      for (final state in [
        RTCPeerConnectionState.RTCPeerConnectionStateConnecting,
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateConnected,
      ]) {
        pc.emitConnectionState(state);
        await _settle();
      }
      pc.emitIceConnectionState(
        RTCIceConnectionState.RTCIceConnectionStateFailed,
      );
      await _settle();

      expect(states, [
        RoomConnectionState.connected,
        RoomConnectionState.connecting,
        RoomConnectionState.connected,
        RoomConnectionState.reconnecting,
        RoomConnectionState.connected,
        RoomConnectionState.disconnected,
      ]);
      expect(room.failure, isA<SfuPeerConnectionFailed>());
      expect(
        events.whereType<RoomSessionFailedEvent>().single.failure,
        room.failure,
      );
      expect(
        () => room.localParticipant.publishMicrophone(),
        throwsA(anything),
      );
      await room.leave();
      expect(room.connectionState, RoomConnectionState.disconnected);
    });
  });

  group('leave', () {
    test('unpublishes, closes the session, leaves signaling and releases '
        'what the room created', () async {
      final alice = await h.join('alice');
      final bob = await h.join('bob');
      final mic = await alice.localParticipant.publishMicrophone();
      final cam = await alice.localParticipant.publishCamera();
      await _settle();
      await bob.participant('alice')!.camera!.subscribe();
      final bobAliceMic = bob.participant('alice')!.microphone!;
      final wrapped = bobAliceMic.track!.stream as FakeWrappedStream;
      final mids = [mic.publication.mid, cam.publication.mid];

      var participantsDone = false;
      var eventsDone = false;
      alice.participantsChanges.listen(
        null,
        onDone: () => participantsDone = true,
      );
      alice.events.listen(null, onDone: () => eventsDone = true);

      final leaving = alice.leave();
      expect(alice.leave(), same(leaving));
      await leaving;

      expect(alice.hasLeft, isTrue);
      expect(h.announced('alice'), isNull);
      expect(h.closesOf(alice), mids, reason: 'one tracks/close for both');
      expect(h.callsOf(alice, 'tracks/close'), hasLength(1));
      expect(alice.session.isClosed, isTrue);
      expect(h.pcOf(alice).closed, isTrue);
      expect(mic.mediaSource.isDisposed, isTrue);
      expect(cam.mediaSource.isDisposed, isTrue);
      expect(h.media.streams.every((s) => s.track.stopped), isTrue);
      expect(h.broker.disposed, isTrue);
      expect(alice.connectionState, RoomConnectionState.disconnected);
      expect(alice.participants, isEmpty);
      await _settle();
      expect(participantsDone && eventsDone, isTrue);
      expect(
        () => alice.localParticipant.publishMicrophone(),
        throwsStateError,
      );

      // Bob closes his pulls of Alice.
      await _settle();
      expect(bob.participants, isEmpty);
      expect(h.closesOf(bob), hasLength(2));
      expect(wrapped.disposed, isTrue);
      await bob.leave();
      expect(bob.session.isClosed, isTrue);
    });
  });

  group('data', () {
    test(
      'messages carry the sender participant, and follow a reconnect',
      () async {
        final bob = await h.join('bob');
        final ann = _Puppet(h, 'ann');
        await ann.join('ann-1');
        await _settle();
        final remote = bob.participant('ann')!;

        final sub = await bob.data.subscribe(remote, 'chat');
        expect(sub.channel.remoteSessionId, 'ann-1');
        final received = <RoomDataMessage>[];
        sub.messages.listen(received.add);

        final pc = h.pcOf(bob);
        final channel = pc.dataChannelById(sub.channel.id!)!;
        channel.open();
        channel.receiveText('hello');
        await _settle();
        expect(received.single.text, 'hello');
        expect(received.single.participantId, 'ann');
        expect(received.single.fromSessionId, 'ann-1');

        await ann.update('ann-2');
        await _settle();
        expect(sub.channel.remoteSessionId, 'ann-2');
        final next = pc.dataChannelById(sub.channel.id!)!;
        next.open();
        next.receiveText('back');
        await _settle();
        expect(channel.closed, isTrue, reason: 'the old pull was closed');
        expect(
          [for (final m in received) '${m.text}:${m.participantId}'],
          ['hello:ann', 'back:ann'],
        );
        expect(received.last.fromSessionId, 'ann-2');

        final published = await bob.data.publish('status');
        expect(published.name, 'status');

        await sub.close();
        expect(sub.isClosed, isTrue);
        await bob.leave();
        await ann.signaling.dispose();
      },
    );
  });
}
