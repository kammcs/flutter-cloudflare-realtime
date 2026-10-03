import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'broker_client.dart';
import 'broker_config.dart';
import 'broker_exception.dart';
import 'models/data_channels.dart';
import 'models/ice_servers.dart';
import 'models/json.dart';
import 'models/session.dart';
import 'models/tracks.dart';

/// The `errorCode` the SFU returns (with HTTP 410) for an expired session.
const _sessionErrorCode = 'session_error';

/// [BrokerClient] over HTTPS, using `package:http`.
///
/// One instance serves one room: every request carries the app's headers
/// (from [BrokerOptions.headers]) and `X-Realtime-Room: <roomId>`.
///
/// If the broker returns `X-Realtime-Session-Token` from `sessions/new`, the
/// token is kept per session ID and sent back on every later call for that
/// session, until [forgetSession] (a [SessionGoneException] doesn't drop
/// it). Brokers that bind sessions server-side and send no token work too.
///
/// This class never logs. Exceptions never include SDP, header values or
/// tokens.
class HttpBrokerClient implements BrokerClient {
  /// Creates a client for the room [roomId].
  ///
  /// Throws an [ArgumentError] if [roomId] is empty or contains a line
  /// break.
  HttpBrokerClient({required this.options, required this.roomId})
    : _client = options.httpClient ?? http.Client(),
      _ownsClient = options.httpClient == null {
    if (roomId.isEmpty || roomId.contains(RegExp(r'[\r\n]'))) {
      throw ArgumentError.value(roomId, 'roomId', 'must be a non-empty line');
    }
  }

  /// The broker options: its URL, the app's headers and the timeout.
  final BrokerOptions options;

  /// The room sent in `X-Realtime-Room` on every call.
  final String roomId;

  final http.Client _client;
  final bool _ownsClient;
  final Map<String, String> _sessionTokens = {};
  bool _disposed = false;

  @override
  Future<NewSessionResponse> newSession([NewSessionRequest? request]) async {
    request ??= const NewSessionRequest();
    const operation = 'sessions/new';
    final correlationId = request.correlationId;
    final response = await _send(
      'POST',
      const ['sessions', 'new'],
      operation: operation,
      body: request.hasBody ? request.toJson() : null,
      query: correlationId == null ? null : {'correlationId': correlationId},
    );
    final json = response.json;
    if (json['sessionId'] is! String && json['errorCode'] is String) {
      // A 2xx body with an error and no session: nothing to return.
      throw BrokerResponseException(
        operation: operation,
        statusCode: response.statusCode,
        errorCode: json['errorCode'] as String,
        errorDescription: json['errorDescription'] as String?,
      );
    }
    final parsed = _parse(response, operation, NewSessionResponse.fromJson);
    final token = response.header(BrokerHeaders.sessionToken);
    if (token != null && token.isNotEmpty) {
      _sessionTokens[parsed.sessionId] = token;
    }
    return parsed;
  }

  @override
  Future<TracksResponse> newTracks(String sessionId, TracksRequest request) =>
      _sessionCall(
        'POST',
        sessionId,
        const ['tracks', 'new'],
        request.toJson(),
        TracksResponse.fromJson,
      );

  @override
  Future<TracksResponse> updateTracks(
    String sessionId,
    UpdateTracksRequest request,
  ) => _sessionCall(
    'PUT',
    sessionId,
    const ['tracks', 'update'],
    request.toJson(),
    TracksResponse.fromJson,
  );

  @override
  Future<RenegotiateResponse> renegotiate(
    String sessionId,
    RenegotiateRequest request,
  ) => _sessionCall(
    'PUT',
    sessionId,
    const ['renegotiate'],
    request.toJson(),
    RenegotiateResponse.fromJson,
  );

  @override
  Future<TracksResponse> closeTracks(
    String sessionId,
    CloseTracksRequest request,
  ) => _sessionCall(
    'PUT',
    sessionId,
    const ['tracks', 'close'],
    request.toJson(),
    TracksResponse.fromJson,
  );

  @override
  Future<SessionState> getSessionState(String sessionId) => _sessionCall(
    'GET',
    sessionId,
    const [],
    null,
    SessionState.fromJson,
    operation: 'sessions/{id}',
  );

  @override
  Future<EstablishDataChannelsResponse> establishDataChannels(
    String sessionId, [
    EstablishDataChannelsRequest? request,
  ]) => _sessionCall(
    'POST',
    sessionId,
    const ['datachannels', 'establish'],
    (request ?? EstablishDataChannelsRequest()).toJson(),
    EstablishDataChannelsResponse.fromJson,
  );

  @override
  Future<DataChannelsResponse> newDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) => _sessionCall(
    'POST',
    sessionId,
    const ['datachannels', 'new'],
    request.toJson(),
    DataChannelsResponse.fromJson,
  );

  @override
  Future<DataChannelsResponse> updateDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) => _sessionCall(
    'PUT',
    sessionId,
    const ['datachannels', 'update'],
    request.toJson(),
    DataChannelsResponse.fromJson,
  );

  @override
  Future<DataChannelsResponse> closeDataChannels(
    String sessionId,
    DataChannelsRequest request,
  ) => _sessionCall(
    'PUT',
    sessionId,
    const ['datachannels', 'close'],
    request.toJson(),
    DataChannelsResponse.fromJson,
  );

  @override
  Future<List<Map<String, dynamic>>> getIceServers() async {
    const operation = 'generate-ice-servers';
    final response = await _send('POST', const [
      'generate-ice-servers',
    ], operation: operation);
    return _parse(
      response,
      operation,
      IceServersResponse.fromJson,
    ).toRtcIceServers();
  }

  @override
  void forgetSession(String sessionId) => _sessionTokens.remove(sessionId);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _sessionTokens.clear();
    if (_ownsClient) _client.close();
  }

  /// Calls `sessions/{sessionId}/<segments>` and parses the response.
  Future<T> _sessionCall<T>(
    String method,
    String sessionId,
    List<String> segments,
    Map<String, Object?>? body,
    T Function(Map<String, Object?> json) fromJson, {
    String? operation,
  }) async {
    if (sessionId.isEmpty) {
      throw ArgumentError.value(sessionId, 'sessionId', 'must not be empty');
    }
    final op = operation ?? segments.join('/');
    final response = await _send(
      method,
      ['sessions', sessionId, ...segments],
      operation: op,
      body: body,
      sessionId: sessionId,
    );
    return _parse(response, op, fromJson);
  }

  T _parse<T>(
    _BrokerResponse response,
    String operation,
    T Function(Map<String, Object?> json) fromJson,
  ) {
    try {
      return fromJson(response.json);
    } on FormatException catch (e) {
      // FormatExceptions from the model parsers name fields, never values.
      throw BrokerProtocolException(
        operation: operation,
        statusCode: response.statusCode,
        message: e.message,
      );
    }
  }

  Future<_BrokerResponse> _send(
    String method,
    List<String> segments, {
    required String operation,
    Map<String, Object?>? body,
    String? sessionId,
    Map<String, String>? query,
  }) async {
    if (_disposed) throw StateError('HttpBrokerClient has been disposed.');

    final appHeaders = await options.headers();
    if (_disposed) throw StateError('HttpBrokerClient has been disposed.');

    final abort = Completer<void>();
    final request = http.AbortableRequest(
      method,
      _url(segments, query),
      abortTrigger: abort.future,
    );
    appHeaders.forEach((name, value) {
      if (!_isReservedHeader(name)) request.headers[name] = value;
    });
    request.headers['Accept'] = 'application/json';
    request.headers[BrokerHeaders.room] = roomId;
    final token = sessionId == null ? null : _sessionTokens[sessionId];
    if (token != null) request.headers[BrokerHeaders.sessionToken] = token;
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }

    final http.Response response;
    try {
      response = await _client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(options.timeout);
    } on TimeoutException {
      if (!abort.isCompleted) abort.complete();
      throw BrokerTimeoutException(
        operation: operation,
        timeout: options.timeout,
      );
    } on Exception catch (e) {
      // http.ClientException, and platform socket/TLS errors from custom
      // clients. Their messages can include the URL, so they are kept only
      // as the cause, never in the message.
      throw BrokerNetworkException(operation: operation, cause: e);
    }

    final status = response.statusCode;
    final json = _decodeJsonObject(response.bodyBytes);
    final errorCode = json?['errorCode'];
    final errorDescription = json?['errorDescription'];
    final code = errorCode is String ? errorCode : null;
    final description = errorDescription is String ? errorDescription : null;

    if (status < 200 || status >= 300) {
      throw _errorFor(status, code, description, operation, sessionId);
    }
    if (code == _sessionErrorCode) {
      throw _errorFor(status, code, description, operation, sessionId);
    }
    if (json == null && response.bodyBytes.isNotEmpty) {
      throw BrokerProtocolException(
        operation: operation,
        statusCode: status,
        message: 'Response body is not a JSON object.',
      );
    }
    return _BrokerResponse(status, json ?? const {}, response.headers);
  }

  BrokerException _errorFor(
    int status,
    String? errorCode,
    String? errorDescription,
    String operation,
    String? sessionId,
  ) {
    if (status == 401) {
      return BrokerUnauthorizedException(
        operation: operation,
        errorCode: errorCode,
        errorDescription: errorDescription,
      );
    }
    if (status == 403) {
      return BrokerForbiddenException(
        operation: operation,
        errorCode: errorCode,
        errorDescription: errorDescription,
      );
    }
    if (status == 410 || errorCode == _sessionErrorCode) {
      // The session token is kept: a request that names other sessions (a
      // pull) can report one of *them* gone, and the session layer then
      // confirms its own with `GET sessions/{id}`, which needs the token.
      // [forgetSession] drops it once the session is abandoned.
      return SessionGoneException(
        operation: operation,
        sessionId: sessionId,
        statusCode: status,
        errorCode: errorCode,
        errorDescription: errorDescription,
      );
    }
    return BrokerResponseException(
      operation: operation,
      statusCode: status,
      errorCode: errorCode,
      errorDescription: errorDescription,
    );
  }

  Uri _url(List<String> segments, Map<String, String>? query) {
    final base = options.baseUrl;
    final queryParameters = {...base.queryParameters, ...?query};
    return base.replace(
      pathSegments: [
        ...base.pathSegments.where((s) => s.isNotEmpty),
        ...segments,
      ],
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
  }

  static bool _isReservedHeader(String name) {
    final lower = name.toLowerCase();
    return lower == BrokerHeaders.room.toLowerCase() ||
        lower == BrokerHeaders.sessionToken.toLowerCase();
  }

  static Map<String, Object?>? _decodeJsonObject(List<int> bytes) {
    if (bytes.isEmpty) return null;
    try {
      final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
      return decoded is Map ? jsonObject(decoded, 'response') : null;
    } on FormatException {
      return null;
    }
  }
}

class _BrokerResponse {
  const _BrokerResponse(this.statusCode, this.json, this._headers);

  final int statusCode;
  final Map<String, Object?> json;
  final Map<String, String> _headers;

  /// Case-insensitive header lookup.
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final entry in _headers.entries) {
      if (entry.key.toLowerCase() == lower) return entry.value;
    }
    return null;
  }
}
