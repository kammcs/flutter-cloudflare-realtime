import 'package:http/http.dart' as http;

/// Returns the app's own request headers, such as
/// `{'Authorization': 'Bearer <user JWT>'}`.
///
/// Called before every broker request, so it can refresh an expiring token.
typedef BrokerHeadersProvider = Future<Map<String, String>> Function();

/// Where the broker lives and how to authenticate to it.
///
/// The broker is a server the app operates. It holds the Cloudflare App
/// Secret and forwards calls to the SFU; see `docs/design.md` §5. The App
/// Secret never goes in the client.
final class BrokerOptions {
  /// Creates a broker configuration.
  const BrokerOptions({
    required this.baseUrl,
    required this.headers,
    this.httpClient,
    this.timeout = const Duration(seconds: 15),
  });

  /// The broker's base URL, such as `https://api.example.com/realtime`.
  /// Paths such as `sessions/new` are appended to it.
  final Uri baseUrl;

  /// Supplies the app's auth headers for each request. Errors it throws
  /// propagate to the caller unchanged.
  final BrokerHeadersProvider headers;

  /// The HTTP client to use. If null, the broker client creates one and
  /// closes it on dispose; an injected client is never closed by it.
  final http.Client? httpClient;

  /// How long one request may take, from sending it to reading the whole
  /// response. The [headers] provider is not included.
  final Duration timeout;
}

/// The HTTP headers of the broker contract.
abstract final class BrokerHeaders {
  /// Request header naming the room the caller is acting in. Sent on every
  /// call; the broker checks the caller is a member.
  static const room = 'X-Realtime-Room';

  /// Session token. A broker MAY return it as a response header on
  /// `sessions/new`; the client then sends it back as a request header on
  /// every later call for that session.
  static const sessionToken = 'X-Realtime-Session-Token';
}
