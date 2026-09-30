// Recovers a call from a simulated network drop, through a real broker
// (docs/design.md §8; the week-6 checkpoint's "a call recovers from a
// network drop"). Two rooms in one process share in-memory signaling: the
// publisher's session is failed and replaced, then the subscriber's, and
// each time the subscriber must receive the track again.
//
// Skipped unless CF_REALTIME_BROKER_URL is set; see broker_settings.dart
// for the settings (including the dev server's X-Dev-User) and a
// command line. The test never prints them.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();
  final roomId = settings.room;
  const timeout = Duration(seconds: 30);

  testWidgets(
    'a call recovers from a network drop on either side',
    (tester) async {
      final realtime = CloudflareRealtime(broker: settings.config());
      final hub = InMemorySignalingHub();
      const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        roomId,
        signaling: InMemorySignaling(hub),
        participantId: 'reconnect-alice-$suffix',
        options: options,
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        roomId,
        signaling: InMemorySignaling(hub),
        participantId: 'reconnect-bob-$suffix',
        options: options,
      );
      addTearDown(bob.leave);

      // A camera if there is one, otherwise a microphone.
      LocalMediaPublication published;
      try {
        published = await alice.localParticipant.publishCamera(
          options: const CameraOptions(preset: VideoPreset.h360),
        );
      } on MediaException {
        published = await alice.localParticipant.publishMicrophone();
      }
      final trackName = published.trackName;
      final track = published.publication.track;

      /// Waits until Bob receives Alice's track from her current session,
      /// as a different track than [before] (a new pull), and returns it.
      Future<RenderableTrack> received({RenderableTrack? before}) async {
        final remote = await bob.participants
            .map((list) => list.where((p) => p.participantId.contains('alice')))
            .firstWhere((matches) => matches.isNotEmpty)
            .timeout(timeout);
        final participant = remote.single;
        await participant.changes
            .startWith(participant)
            .firstWhere(
              (p) =>
                  p.sessionId == alice.session.sessionId &&
                  p.trackPublication(trackName) != null,
            )
            .timeout(timeout);
        final publication = participant.trackPublication(trackName)!;
        return publication.track
            .where(
              (t) =>
                  t != null &&
                  !identical(t, before) &&
                  publication.subscriptionState == SfuTrackState.active &&
                  publication.subscription!.remoteSessionId ==
                      alice.session.sessionId,
            )
            .cast<RenderableTrack>()
            .first
            .timeout(timeout);
      }

      Future<void> connected(Room room) => room.session.connectionState
          .firstWhere((s) => s == SfuConnectionState.connected)
          .timeout(timeout);

      final first = await received();
      await connected(alice);
      await connected(bob);
      await published.publication.whenSending().timeout(timeout);

      // The publisher drops.
      final aliceSession = alice.session.sessionId;
      final aliceBack = alice.events
          .firstWhere((e) => e is RoomReconnectedEvent)
          .timeout(timeout);
      alice.debugSimulateConnectionFailure();
      await aliceBack;
      expect(alice.session.sessionId, isNot(aliceSession));
      expect(published.trackName, trackName, reason: 'same track name');
      expect(published.publication.track, same(track), reason: 'no recapture');
      final second = await received(before: first);
      await connected(alice);
      await published.publication.whenSending().timeout(timeout);
      await connected(bob);

      // The subscriber drops.
      final bobSession = bob.session.sessionId;
      final bobBack = bob.events
          .firstWhere((e) => e is RoomReconnectedEvent)
          .timeout(timeout);
      bob.debugSimulateConnectionFailure();
      await bobBack;
      expect(bob.session.sessionId, isNot(bobSession));
      await received(before: second);
      await connected(bob);

      expect(alice.currentConnectionState, RoomConnectionState.connected);
      expect(bob.currentConnectionState, RoomConnectionState.connected);
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

extension<T> on Stream<T> {
  /// This stream, preceded by [value].
  Stream<T> startWith(T value) async* {
    yield value;
    yield* this;
  }
}
