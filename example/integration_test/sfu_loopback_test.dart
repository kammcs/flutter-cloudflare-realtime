// Pushes a local track on one SFU session and pulls it on another, through
// a real broker.
//
// Skipped unless CF_REALTIME_BROKER_URL is set; see broker_settings.dart
// for the settings (including the dev server's X-Dev-User) and a
// command line. The test never prints them.

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();
  final room = settings.room;
  const timeout = Duration(seconds: 20);

  testWidgets(
    'pushes and pulls a loopback track between two sessions',
    (tester) async {
      final broker = HttpBrokerClient(
        roomId: room,
        options: settings.brokerOptions(),
      );
      addTearDown(broker.dispose);

      final publisher = await SfuSession.connect(broker: broker);
      addTearDown(publisher.close);
      final subscriber = await SfuSession.connect(broker: broker);
      addTearDown(subscriber.close);
      expect(publisher.sessionId, isNot(subscriber.sessionId));
      // Connect both now: the SFU expires a session whose peer connection
      // never connected (about ten seconds), and the first capture below
      // can take that long on a loaded machine.
      await Future.wait([
        publisher.establishConnection(),
        subscriber.establishConnection(),
      ]);

      final stream = await _captureLocalMedia();
      addTearDown(() async {
        for (final t in stream.getTracks()) {
          await t.stop();
        }
        await stream.dispose();
      });
      final track = stream.getTracks().first;

      final publication = await publisher.publish(track);
      expect(publication.state, SfuTrackState.active);
      expect(publication.mid, isNotNull);
      await publication.whenSending().timeout(timeout);
      await publisher.connectionStateChanges
          .firstWhere((s) => s == SfuConnectionState.connected)
          .timeout(timeout);

      final isVideo = track.kind == 'video';
      final subscription = await subscriber.subscribe(
        remoteSessionId: publisher.sessionId,
        trackName: publication.trackName,
        preferredRid: isVideo ? 'b' : null,
      );
      expect(subscription.state, SfuTrackState.active);
      expect(subscription.track?.kind, track.kind);
      await subscriber.connectionStateChanges
          .firstWhere((s) => s == SfuConnectionState.connected)
          .timeout(timeout);

      if (isVideo) {
        await subscription.setPreferredRid('c');
        expect(subscription.preferredRid, 'c');
      }

      await subscription.unsubscribe();
      expect(subscription.state, SfuTrackState.closed);
      await publication.unpublish();
      expect(publication.state, SfuTrackState.closed);
      expect(publisher.failure, isNull);
      expect(subscriber.failure, isNull);
    },
    skip: settings.skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// A camera track if there is one, otherwise a microphone track.
///
/// Without a camera, getUserMedia either throws or (on the iOS Simulator)
/// returns a stream with no track; either way, fall back to the microphone.
Future<MediaStream> _captureLocalMedia() async {
  try {
    final stream = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {'width': 640, 'height': 360},
    });
    if (stream.getVideoTracks().isNotEmpty) return stream;
    for (final t in stream.getTracks()) {
      await t.stop();
    }
    await stream.dispose();
  } catch (_) {
    // No camera, or no permission for it.
  }
  return navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
}
