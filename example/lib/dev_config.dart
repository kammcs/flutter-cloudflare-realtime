/// Join-screen settings for the local dev server in `tools/dev-server/`.
///
/// DEV ONLY: the dev server authenticates everybody with one shared token and
/// trusts the user name the client sends. See `tools/dev-server/README.md`.
library;

import 'dart:math';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';

import 'ws_signaling.dart';

/// The dev server's URL, its dev token, and who you are.
///
/// It produces the two things a call needs: a [BrokerOptions] for the SFU
/// session ([brokerOptions]) and a [WsSignaling] for presence
/// ([createSignaling]). Both point at the same server.
///
/// ```dart
/// final dev = DevServerConfig.parse(
///   serverUrl: 'http://192.168.1.10:8787',
///   token: '<dev token printed by the server>',
///   userName: 'ada',
/// );
/// final realtime = CloudflareRealtime(broker: dev.brokerOptions());
/// final signaling = dev.createSignaling();
/// ```
class DevServerConfig {
  /// Creates a config from already-validated values. Prefer [parse].
  DevServerConfig({
    required this.serverUrl,
    required this.token,
    required this.userName,
  });

  /// Validates and trims the join screen's fields.
  ///
  /// Throws a [FormatException] naming the first invalid field; the
  /// `validate*` functions give the same messages for form validation.
  factory DevServerConfig.parse({
    required String serverUrl,
    required String token,
    required String userName,
  }) {
    final error =
        validateServerUrl(serverUrl) ??
        validateToken(token) ??
        validateUserName(userName);
    if (error != null) throw FormatException(error);
    final url = Uri.parse(serverUrl.trim());
    return DevServerConfig(
      // Keep scheme, host, port and path; drop any query or fragment.
      serverUrl: Uri(
        scheme: url.scheme,
        host: url.host,
        port: url.hasPort ? url.port : null,
        path: url.path.replaceAll(RegExp(r'/+$'), ''),
      ),
      token: token.trim(),
      userName: userName.trim(),
    );
  }

  /// Reads `--dart-define`s, handy for running several devices without
  /// typing: `DEV_SERVER_URL`, `DEV_TOKEN` and `DEV_USER`. Returns `null`
  /// unless all three are set and valid.
  static DevServerConfig? fromEnvironment() {
    const serverUrl = String.fromEnvironment('DEV_SERVER_URL');
    const token = String.fromEnvironment('DEV_TOKEN');
    const userName = String.fromEnvironment('DEV_USER');
    try {
      return DevServerConfig.parse(
        serverUrl: serverUrl,
        token: token,
        userName: userName,
      );
    } on FormatException {
      return null;
    }
  }

  /// The dev server, such as `http://192.168.1.10:8787`. It serves the
  /// broker at its root and signaling at `/signaling`.
  final Uri serverUrl;

  /// The dev token the server printed at startup.
  final String token;

  /// Who you are. The broker binds SFU sessions to it (`X-Dev-User`).
  final String userName;

  /// Returns an error message for an invalid server URL, or `null`.
  static String? validateServerUrl(String value) {
    final url = Uri.tryParse(value.trim());
    if (url == null ||
        !(url.isScheme('http') || url.isScheme('https')) ||
        url.host.isEmpty) {
      return 'Enter the server URL, such as http://192.168.1.10:8787';
    }
    return null;
  }

  /// Returns an error message for an invalid dev token, or `null`.
  static String? validateToken(String value) {
    final token = value.trim();
    if (token.isEmpty) return 'Enter the dev token the server printed';
    if (!RegExp(r'^[\x21-\x7e]+$').hasMatch(token)) {
      return 'The dev token has unexpected characters';
    }
    return null;
  }

  /// Returns an error message for an invalid user name, or `null`.
  ///
  /// It goes in an HTTP header, so it must be printable ASCII.
  static String? validateUserName(String value) {
    final name = value.trim();
    if (name.isEmpty) return 'Enter a user name';
    if (name.length > 64) return 'Use at most 64 characters';
    if (!RegExp(r'^[\x20-\x7e]+$').hasMatch(name)) {
      return 'Use letters, digits and basic punctuation (ASCII)';
    }
    return null;
  }

  /// The headers the dev server's broker expects.
  Map<String, String> get brokerHeaders => {
    'Authorization': 'Bearer $token',
    'X-Dev-User': userName,
  };

  /// The broker settings: the server's root, with [brokerHeaders].
  BrokerOptions brokerOptions({
    Duration timeout = const Duration(seconds: 15),
  }) => BrokerOptions(
    baseUrl: serverUrl,
    headers: () async => brokerHeaders,
    timeout: timeout,
  );

  /// The signaling WebSocket URL: `ws(s)://<server>/signaling?token=<token>`.
  Uri get signalingUrl => serverUrl.replace(
    scheme: serverUrl.isScheme('https') ? 'wss' : 'ws',
    pathSegments: [
      ...serverUrl.pathSegments.where((s) => s.isNotEmpty),
      'signaling',
    ],
    queryParameters: {'token': token},
  );

  /// Creates a [WsSignaling] connected to [signalingUrl].
  WsSignaling createSignaling({
    WebSocketConnector? connect,
    void Function(Object error)? onError,
  }) => WsSignaling(url: signalingUrl, connect: connect, onError: onError);

  /// A fresh `participantId` for this user on this device, such as
  /// `ada:3f9a1c`. The same user may join from several devices; each needs
  /// its own ID.
  String newParticipantId([Random? random]) {
    final r = random ?? Random.secure();
    final suffix = List.generate(
      6,
      (_) => r.nextInt(16).toRadixString(16),
    ).join();
    return '$userName:$suffix';
  }
}
