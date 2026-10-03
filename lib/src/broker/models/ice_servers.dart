import 'json.dart';

/// One ICE server (STUN or TURN), as `generate-ice-servers` returns it.
///
/// Wire shape: `{"urls": ["turn:..."], "username"?: "...",
/// "credential"?: "..."}`. `urls` may also be a single string.
///
/// [toString] never includes [username] or [credential].
final class IceServer {
  /// Creates an ICE server.
  IceServer({required List<String> urls, this.username, this.credential})
    : urls = List.unmodifiable(urls);

  /// Parses the wire shape. Accepts `urls` as a string or an array, and the
  /// legacy singular `url`.
  factory IceServer.fromJson(Map<String, Object?> json) {
    final raw = json['urls'] ?? json['url'];
    final List<String> urls;
    if (raw is String) {
      urls = [raw];
    } else if (raw is List && raw.every((u) => u is String)) {
      urls = raw.cast<String>();
    } else {
      throw const FormatException('Expected a string or array for "urls".');
    }
    return IceServer(
      urls: urls,
      username: optString(json, 'username'),
      credential: optString(json, 'credential'),
    );
  }

  /// The server URLs, such as `stun:stun.cloudflare.com:3478` or
  /// `turn:turn.cloudflare.com:3478?transport=udp`.
  final List<String> urls;

  /// The TURN username, if any.
  final String? username;

  /// The TURN credential, if any. Treat it as a secret.
  final String? credential;

  /// The wire shape.
  Map<String, Object?> toJson() {
    final json = <String, Object?>{'urls': urls};
    putIfNotNull(json, 'username', username);
    putIfNotNull(json, 'credential', credential);
    return json;
  }

  /// This server as `flutter_webrtc` `iceServers` entries: one map per URL,
  /// each with a single string `urls`.
  ///
  /// One map per URL because `flutter_webrtc`'s Windows implementation keeps
  /// only the last entry of a `urls` array.
  List<Map<String, dynamic>> toRtcIceServers() => [
    for (final url in urls)
      <String, dynamic>{
        'urls': url,
        if (username != null) 'username': username,
        if (credential != null) 'credential': credential,
      },
  ];

  @override
  String toString() =>
      'IceServer(urls: $urls, hasCredential: ${credential != null})';
}

/// The response of the broker's `generate-ice-servers` endpoint:
/// `{"iceServers": [...]}`.
final class IceServersResponse {
  /// Creates an ICE servers response.
  IceServersResponse({required List<IceServer> iceServers})
    : iceServers = List.unmodifiable(iceServers);

  /// Parses the wire shape. Also accepts a single server object in place of
  /// the array, which older Cloudflare TURN responses used.
  factory IceServersResponse.fromJson(Map<String, Object?> json) {
    final raw = json['iceServers'];
    if (raw is List) {
      return IceServersResponse(
        iceServers: [
          for (final s in raw) IceServer.fromJson(jsonObject(s, 'iceServers')),
        ],
      );
    }
    if (raw is Map) {
      return IceServersResponse(
        iceServers: [IceServer.fromJson(jsonObject(raw, 'iceServers'))],
      );
    }
    throw const FormatException('Expected an array for "iceServers".');
  }

  /// The ICE servers.
  final List<IceServer> iceServers;

  /// The wire shape.
  Map<String, Object?> toJson() => {
    'iceServers': [for (final s in iceServers) s.toJson()],
  };

  /// All servers as `flutter_webrtc` `iceServers` entries (see
  /// [IceServer.toRtcIceServers]).
  List<Map<String, dynamic>> toRtcIceServers() => [
    for (final s in iceServers) ...s.toRtcIceServers(),
  ];
}
