import 'dart:math';

import 'package:cloudflare_realtime_example/dev_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DevServerConfig config({
    String serverUrl = 'http://192.168.1.10:8787',
    String token = 'tok-123',
    String userName = 'ada',
  }) => DevServerConfig.parse(
    serverUrl: serverUrl,
    token: token,
    userName: userName,
  );

  test('builds the broker config', () async {
    final broker = config().brokerConfig();
    expect(broker.baseUrl, Uri.parse('http://192.168.1.10:8787'));
    expect(await broker.headers(), {
      'Authorization': 'Bearer tok-123',
      'X-Dev-User': 'ada',
    });
  });

  test('derives the signaling URL', () {
    expect(
      config().signalingUrl,
      Uri.parse('ws://192.168.1.10:8787/signaling?token=tok-123'),
    );
    expect(
      config(serverUrl: 'https://dev.example.test/base/').signalingUrl,
      Uri.parse('wss://dev.example.test/base/signaling?token=tok-123'),
    );
    expect(
      config(token: 'a+b/c=').signalingUrl.queryParameters['token'],
      'a+b/c=',
    );
  });

  test('trims input and drops query and fragment', () {
    final c = config(
      serverUrl: '  http://10.0.2.2:8787/?x=1#y ',
      token: ' tok ',
      userName: ' Ada L ',
    );
    expect(c.serverUrl, Uri.parse('http://10.0.2.2:8787'));
    expect(c.token, 'tok');
    expect(c.userName, 'Ada L');
  });

  test('creates a WsSignaling for the signaling URL', () {
    final s = config().createSignaling();
    expect(s.url, config().signalingUrl);
  });

  test('validates fields', () {
    expect(DevServerConfig.validateServerUrl('http://h:1'), isNull);
    expect(DevServerConfig.validateServerUrl(''), isNotNull);
    expect(DevServerConfig.validateServerUrl('ws://h:1'), isNotNull);
    expect(DevServerConfig.validateServerUrl('192.168.1.10:8787'), isNotNull);
    expect(DevServerConfig.validateToken(' '), isNotNull);
    expect(DevServerConfig.validateToken('a b'), isNotNull);
    expect(DevServerConfig.validateUserName(''), isNotNull);
    expect(DevServerConfig.validateUserName('Zoë'), isNotNull);
    expect(DevServerConfig.validateUserName('x' * 65), isNotNull);
    expect(DevServerConfig.validateUserName('Ada Lovelace'), isNull);
    expect(() => config(userName: ''), throwsFormatException);
  });

  test('fromEnvironment is null without dart-defines', () {
    expect(DevServerConfig.fromEnvironment(), isNull);
  });

  test('makes per-device participant IDs', () {
    final id = config().newParticipantId(Random(1));
    expect(id, matches(RegExp(r'^ada:[0-9a-f]{6}$')));
    expect(config().newParticipantId(), isNot(config().newParticipantId()));
  });
}
