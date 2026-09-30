// Broker settings shared by the integration tests. Pass them with
// --dart-define (works on every device) or, on desktop, the environment:
//
//   CF_REALTIME_BROKER_URL    the broker's base URL (required; the tests
//                             are skipped without it)
//   CF_REALTIME_BROKER_TOKEN  sent as `Authorization: Bearer <token>`
//   CF_REALTIME_BROKER_USER   sent as `X-Dev-User: <user>`, which the DEV
//                             ONLY tools/dev-server broker requires
//   CF_REALTIME_ROOM          the room ID (default: integration-test)
//
// Against the dev server (docs/checkpoint.md):
//
//   cd example
//   flutter test integration_test -d windows \
//     --dart-define=CF_REALTIME_BROKER_URL=http://192.168.1.10:8787 \
//     --dart-define=CF_REALTIME_BROKER_TOKEN=<dev token> \
//     --dart-define=CF_REALTIME_BROKER_USER=it-windows
//
// The tests never print these values.

import 'dart:io' show Platform;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';

const _definedUrl = String.fromEnvironment('CF_REALTIME_BROKER_URL');
const _definedToken = String.fromEnvironment('CF_REALTIME_BROKER_TOKEN');
const _definedUser = String.fromEnvironment('CF_REALTIME_BROKER_USER');
const _definedRoom = String.fromEnvironment('CF_REALTIME_ROOM');

String? _setting(String defined, String name) {
  if (defined.isNotEmpty) return defined;
  if (kIsWeb) return null;
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

/// The broker the integration tests use, from the settings above.
class BrokerSettings {
  BrokerSettings._(this.url, this._token, this._user, this.room);

  /// Reads the settings.
  factory BrokerSettings.read() => BrokerSettings._(
    _setting(_definedUrl, 'CF_REALTIME_BROKER_URL'),
    _setting(_definedToken, 'CF_REALTIME_BROKER_TOKEN'),
    _setting(_definedUser, 'CF_REALTIME_BROKER_USER'),
    _setting(_definedRoom, 'CF_REALTIME_ROOM') ?? 'integration-test',
  );

  /// The broker's base URL, or `null` to skip the tests.
  final String? url;
  final String? _token;
  final String? _user;

  /// The room ID.
  final String room;

  /// Whether the tests should be skipped (no broker URL).
  bool get skip => url == null;

  /// The broker config: [url] with the token and dev-user headers.
  BrokerConfig config() => BrokerConfig(
    baseUrl: Uri.parse(url!),
    headers: () async => {
      if (_token != null) 'Authorization': 'Bearer $_token',
      if (_user != null) 'X-Dev-User': _user,
    },
  );
}
