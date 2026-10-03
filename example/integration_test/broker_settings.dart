// Broker settings shared by the integration tests. Pass them with
// --dart-define (works on every device) or, on desktop, the environment:
//
//   CF_REALTIME_BROKER_URL    the broker's base URL (required; the tests
//                             are skipped without it)
//   CF_REALTIME_BROKER_TOKEN  sent as `Authorization: Bearer <token>`
//   CF_REALTIME_BROKER_USER   sent as `X-Dev-User: <user>`, which the DEV
//                             ONLY tools/dev-server broker requires
//   CF_REALTIME_ROOM          the room ID (default: integration-test)
//   CF_REALTIME_CROSS_DEVICE  set to 1 to run cross_device_test.dart, which
//                             needs a second device running it at the same
//                             time in the same room (docs/checkpoint.md §7)
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
import 'package:cloudflare_realtime_example/dev_config.dart';
import 'package:flutter/foundation.dart';

const _definedUrl = String.fromEnvironment('CF_REALTIME_BROKER_URL');
const _definedToken = String.fromEnvironment('CF_REALTIME_BROKER_TOKEN');
const _definedUser = String.fromEnvironment('CF_REALTIME_BROKER_USER');
const _definedRoom = String.fromEnvironment('CF_REALTIME_ROOM');
const _definedCrossDevice = String.fromEnvironment('CF_REALTIME_CROSS_DEVICE');

String? _setting(String defined, String name) {
  if (defined.isNotEmpty) return defined;
  if (kIsWeb) return null;
  final value = Platform.environment[name];
  return value == null || value.isEmpty ? null : value;
}

/// The broker the integration tests use, from the settings above.
class BrokerSettings {
  BrokerSettings._(
    this.url,
    this._token,
    this._user,
    this.room, {
    this.crossDevice = false,
  });

  /// Reads the settings.
  factory BrokerSettings.read() => BrokerSettings._(
    _setting(_definedUrl, 'CF_REALTIME_BROKER_URL'),
    _setting(_definedToken, 'CF_REALTIME_BROKER_TOKEN'),
    _setting(_definedUser, 'CF_REALTIME_BROKER_USER'),
    _setting(_definedRoom, 'CF_REALTIME_ROOM') ?? 'integration-test',
    crossDevice:
        _setting(_definedCrossDevice, 'CF_REALTIME_CROSS_DEVICE') == '1',
  );

  /// The broker's base URL, or `null` to skip the tests.
  final String? url;
  final String? _token;
  final String? _user;

  /// The room ID.
  final String room;

  /// Whether `CF_REALTIME_CROSS_DEVICE` is `1`.
  final bool crossDevice;

  /// The user name sent as `X-Dev-User`, if any.
  String? get user => _user;

  /// Whether the tests should be skipped (no broker URL).
  bool get skip => url == null;

  /// Whether the cross-device test should be skipped: no broker URL, no
  /// token or user for the dev server's signaling, or no
  /// `CF_REALTIME_CROSS_DEVICE=1`.
  bool get skipCrossDevice =>
      skip || _token == null || _user == null || !crossDevice;

  /// The dev server's settings (for its WebSocket signaling). Needs the
  /// token and the user.
  DevServerConfig devServer() =>
      DevServerConfig.parse(serverUrl: url!, token: _token!, userName: _user!);

  /// The broker config: [url] with the token and dev-user headers.
  BrokerOptions config() => BrokerOptions(
    baseUrl: Uri.parse(url!),
    headers: () async => {
      if (_token != null) 'Authorization': 'Bearer $_token',
      if (_user != null) 'X-Dev-User': _user,
    },
  );
}
