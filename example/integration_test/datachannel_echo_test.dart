// Publishes a DataChannel on one SFU session, subscribes to it (with
// canReply) on another, and echoes messages both ways, through a real
// broker.
//
// Skipped unless CF_REALTIME_BROKER_URL is set. Settings are the same as in
// sfu_loopback_test.dart:
//
//   CF_REALTIME_BROKER_URL    the broker's base URL (required)
//   CF_REALTIME_BROKER_TOKEN  sent as `Authorization: Bearer <token>`
//   CF_REALTIME_ROOM          the room ID (default: integration-test)
//
//   cd example
//   flutter test integration_test/datachannel_echo_test.dart -d windows \
//     --dart-define=CF_REALTIME_BROKER_URL=https://broker.example.test/realtime
//
// The test never prints these values.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Sends with [send] every 200 ms until [received] completes: the SFU may
/// start forwarding shortly after both ends report open.
Future<T> _sendUntil<T>(
  Future<T> received,
  Future<void> Function() send,
  Duration timeout,
) async {
  final timer = Timer.periodic(
    const Duration(milliseconds: 200),
    (_) => unawaited(send().catchError((Object _) {})),
  );
  try {
    await send();
    return await received.timeout(timeout);
  } finally {
    timer.cancel();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final brokerUrl = _setting(_definedUrl, 'CF_REALTIME_BROKER_URL');
  final token = _setting(_definedToken, 'CF_REALTIME_BROKER_TOKEN');
  final room = _setting(_definedRoom, 'CF_REALTIME_ROOM') ?? 'integration-test';
  const timeout = Duration(seconds: 20);

  testWidgets(
    'publishes, subscribes and echoes over DataChannels',
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

      // Reliable, with a reply path.
      final local = await publisher.publishDataChannel('echo');
      final remote = await subscriber.subscribeDataChannel(
        publisher.sessionId,
        'echo',
        canReply: true,
      );
      expect(local.id, isNotNull);
      expect(remote.id, isNotNull);
      await Future.wait([local.whenOpen(), remote.whenOpen()]).timeout(timeout);

      final ping = await _sendUntil(
        remote.messages.firstWhere((m) => m.text == 'ping'),
        () => local.sendText('ping'),
        timeout,
      );
      expect(ping.fromSessionId, publisher.sessionId);

      final pong = await _sendUntil(
        local.messages.firstWhere((m) => m.text == 'pong'),
        () => remote.sendText('pong'),
        timeout,
      );
      expect(pong.fromSessionId, isNull, reason: 'a reply on our channel');

      final bytes = Uint8List.fromList([1, 2, 3, 250]);
      final binary = await _sendUntil(
        remote.messages.firstWhere((m) => m.isBinary),
        () => local.send(bytes),
        timeout,
      );
      expect(binary.binary, bytes);

      // Unreliable (unordered, no retransmits): a loss is fine, so keep
      // sending until one arrives.
      final fastLocal = await publisher.publishDataChannel(
        'pointer',
        profile: DataChannelProfile.unreliable,
      );
      final fastRemote = await subscriber.subscribeDataChannel(
        publisher.sessionId,
        'pointer',
        profile: DataChannelProfile.unreliable,
      );
      await Future.wait([fastLocal.whenOpen(), fastRemote.whenOpen()])
          .timeout(timeout);
      final move = await _sendUntil(
        fastRemote.messages.first,
        () => fastLocal.sendText('move'),
        timeout,
      );
      expect(move.fromSessionId, publisher.sessionId);

      await remote.close();
      await fastRemote.close();
      await local.close();
      await fastLocal.close();
      expect(local.state, SfuDataChannelState.closed);
      expect(publisher.failure, isNull);
      expect(subscriber.failure, isNull);
    },
    skip: brokerUrl == null,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
