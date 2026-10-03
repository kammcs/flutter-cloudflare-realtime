// A publish long after joining, against a real broker (roadmap M10).
//
// The SFU expires a session whose PeerConnection never connected (about
// ten seconds after `sessions/new`; then 410 "Session appears to be
// disconnected"). A first publish that waits on a permission prompt or a
// screen-share picker used to fail with SessionGoneException. Two ways in
// (docs/design.md §8.1, "Publishing late"):
//
// 1. The default: the room connects its session at join
//    (RoomOptions.connectEarly), so the session is kept and the publish is a
//    plain push on it.
// 2. connectEarly off: the session expires, the push gets the 410, the room
//    re-sessions and the publish completes on the new session.
//
// Either way Bob must decode Alice's video. Skipped unless
// CF_REALTIME_BROKER_URL is set; see broker_settings.dart.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

const _timeout = Duration(seconds: 20);

/// Longer than the SFU's expiry window for an unconnected session.
const _idle = Duration(seconds: 30);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();

  Future<void> run({required bool connectEarly}) async {
    // The permission prompt is not what this test is about: ask first, so
    // a first run's prompt doesn't add to the idle time.
    await _askForPermissions();

    final realtime = CloudflareRealtime(broker: settings.config());
    final hub = InMemorySignalingHub();
    final suffix = DateTime.now().microsecondsSinceEpoch;
    final alice = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: 'late-alice-$suffix',
      options: RoomOptions(connectEarly: connectEarly),
    );
    addTearDown(alice.leave);
    final events = <RoomEvent>[];
    final sub = alice.events.listen(events.add);
    addTearDown(sub.cancel);
    final bob = await realtime.join(
      settings.room,
      signaling: InMemorySignaling(hub),
      participantId: 'late-bob-$suffix',
      options: const RoomOptions(autoSubscribe: AutoSubscribe.all),
    );
    addTearDown(bob.leave);
    final joinedSession = alice.session.sessionId;

    _log('joined (connectEarly: $connectEarly); idle for ${_idle.inSeconds} s');
    await Future<void>.delayed(_idle);
    _log(
      'after idling: session ${alice.session.connectionState.name}, '
      'room ${alice.connectionState.name}',
    );
    if (connectEarly) {
      expect(
        alice.session.connectionState,
        SfuConnectionState.connected,
        reason: 'the session connected at join',
      );
    }

    final watch = Stopwatch()..start();
    LocalMediaPublication published;
    try {
      published = await alice.localParticipant.publishCamera(
        options: const CameraOptions(preset: VideoPreset.h360),
      );
    } on MediaException catch (e) {
      _log('no camera ($e), publishing the microphone');
      published = await alice.localParticipant.publishMicrophone();
    }
    final reconnected = events.whereType<RoomReconnectingEvent>().toList();
    _log(
      'published ${published.kind.name} in ${watch.elapsedMilliseconds} ms; '
      're-sessions: ${[for (final e in reconnected) e.reason.name]}',
    );
    expect(published.publication.state, SfuTrackState.active);
    expect(published.publication.session, same(alice.session));
    if (connectEarly) {
      expect(reconnected, isEmpty, reason: 'the joined session was kept');
      expect(alice.session.sessionId, joinedSession);
    } else {
      // The SFU expired the unconnected session: the push got the 410 and
      // the room published on a new session.
      expect(
        [for (final e in reconnected) e.reason],
        [ReconnectReason.sessionGone],
        reason: 'the SFU should have expired the idle, unconnected session',
      );
      expect(alice.session.sessionId, isNot(joinedSession));
    }

    await published.publication.whenSending().timeout(_timeout);
    await _received(bob, alice, published.kind);
    expect(alice.connectionState, RoomConnectionState.connected);
  }

  testWidgets(
    'a publish 30 s after joining: the early-connected session is kept',
    (tester) => run(connectEarly: true),
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );

  testWidgets(
    'a publish 30 s after joining without connecting early: the room '
    're-sessions and the publish completes',
    (tester) => run(connectEarly: false),
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _log(String message) => debugPrint('[late-publish] $message');

Future<void> _askForPermissions() async {
  for (final source in [CameraSource(), MicrophoneSource()]) {
    try {
      await source.enable();
    } on MediaException {
      // No such device: the test falls back to the other.
    } finally {
      await source.dispose();
    }
  }
}

/// Waits until Bob receives Alice's track from her current session and
/// media flows: 15 more decoded frames for video, rising bytes for audio.
Future<void> _received(Room bob, Room alice, TrackKind kind) async {
  final deadline = DateTime.now().add(_timeout);
  RemoteTrackPublication? pulled;
  while (pulled == null && DateTime.now().isBefore(deadline)) {
    for (final p in bob.participants) {
      final track = kind == TrackKind.video ? p.camera : p.microphone;
      if (p.sessionId == alice.session.sessionId &&
          track != null &&
          track.subscriptionState == SfuTrackState.active) {
        pulled = track;
      }
    }
    if (pulled == null) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
  if (pulled == null) {
    // What Bob has, for the next time this fails.
    for (final p in bob.participants) {
      final track = kind == TrackKind.video ? p.camera : p.microphone;
      _log(
        'Bob sees ${p.participantId} on ${p.sessionId} (Alice is on '
        '${alice.session.sessionId}): ${track?.trackName} '
        '${track?.subscriptionState?.name}, last error ${track?.error}',
      );
    }
    fail('Bob never pulled Alice\'s ${kind.name}');
  }

  Future<num> counter() async {
    num total = 0;
    for (final r in await bob.session.getStats()) {
      if (r.type == 'inbound-rtp' && r.values['kind'] == kind.name) {
        final v =
            r.values[kind == TrackKind.video
                ? 'framesDecoded'
                : 'bytesReceived'];
        total += v is num ? v : num.tryParse('${v ?? ''}') ?? 0;
      }
    }
    return total;
  }

  final start = await counter();
  final enough = kind == TrackKind.video ? 15 : 2000;
  var last = start;
  while (DateTime.now().isBefore(deadline)) {
    last = await counter();
    if (last - start >= enough) {
      _log(
        'Bob received ${last - start} more '
        '${kind == TrackKind.video ? 'frames' : 'bytes'}',
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('Bob received only ${last - start} in $_timeout');
}
