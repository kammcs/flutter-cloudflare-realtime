// Pushes a local track on one SFU session and pulls it on another, through
// a real broker.
//
// Skipped unless CF_REALTIME_BROKER_URL is set. Pass settings with
// --dart-define (works on every device) or, on desktop, the environment:
//
//   CF_REALTIME_BROKER_URL    the broker's base URL (required)
//   CF_REALTIME_BROKER_TOKEN  sent as `Authorization: Bearer <token>`
//   CF_REALTIME_ROOM          the room ID (default: integration-test)
//
//   cd example
//   flutter test integration_test -d windows \
//     --dart-define=CF_REALTIME_BROKER_URL=https://broker.example.test/realtime
//
// The test never prints these values.

import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';

const _definedUrl = String.fromEnvironment('CF_REALTIME_BROKER_URL');
const _definedToken = String.fromEnvironment('CF_REALTIME_BROKER_TOKEN');
const _definedRoom = String.fromEnvironment('CF_REALTIME_ROOM');

String? _setting(String defined, String name) {
  if (defined.isNotEmpty) return defined;
  if (kIsWeb) return null;
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final brokerUrl = _setting(_definedUrl, 'CF_REALTIME_BROKER_URL');
  final token = _setting(_definedToken, 'CF_REALTIME_BROKER_TOKEN');
  final room = _setting(_definedRoom, 'CF_REALTIME_ROOM') ?? 'integration-test';
  const timeout = Duration(seconds: 20);

  testWidgets(
    'pushes and pulls a loopback track between two sessions',
    (tester) async {
      final broker = HttpBrokerClient(
        roomId: room,
        config: BrokerConfig(
          baseUrl: Uri.parse(brokerUrl!),
          headers: () async => {
            if (token != null) 'Authorization': 'Bearer $token',
          },
        ),
      );
      addTearDown(broker.dispose);

      final publisher = await SfuSession.connect(broker: broker);
      addTearDown(publisher.close);
      final subscriber = await SfuSession.connect(broker: broker);
      addTearDown(subscriber.close);
      expect(publisher.sessionId, isNot(subscriber.sessionId));

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
      await publisher.connectionState
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
      await subscriber.connectionState
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
    skip: brokerUrl == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

/// A camera track if there is one, otherwise a microphone track.
Future<MediaStream> _captureLocalMedia() async {
  try {
    return await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {'width': 640, 'height': 360},
    });
  } catch (_) {
    return navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
  }
}
