import 'dart:async';
import 'dart:convert';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const sdp = 'v=0\r\na=ice-pwd:sdp-secret\r\n';
const appToken = 'app-jwt-value';

/// A [MockClient] that records requests and answers from a queue of
/// handlers.
class Recorder {
  final requests = <http.Request>[];
  final _responses = <Future<http.Response> Function(http.Request)>[];

  void reply(
    int status, [
    Object? body,
    Map<String, String> headers = const {},
  ]) {
    _responses.add(
      (_) async => http.Response(
        body == null
            ? ''
            : body is String
            ? body
            : jsonEncode(body),
        status,
        headers: {'content-type': 'application/json', ...headers},
      ),
    );
  }

  void replyWith(Future<http.Response> Function(http.Request) handler) =>
      _responses.add(handler);

  late final client = MockClient((request) {
    requests.add(request);
    if (_responses.isEmpty) fail('Unexpected request ${request.url}');
    return _responses.removeAt(0)(request);
  });

  http.Request get last => requests.last;
  Map<String, Object?> get lastJson =>
      jsonDecode(last.body) as Map<String, Object?>;
}

String? header(http.Request r, String name) {
  for (final e in r.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

void main() {
  late Recorder server;
  late HttpBrokerClient client;
  var headerCalls = 0;

  HttpBrokerClient makeClient({
    String base = 'https://api.example.com/realtime',
    Duration timeout = const Duration(seconds: 15),
    BrokerHeadersProvider? headers,
  }) => HttpBrokerClient(
    roomId: 'room-1',
    config: BrokerConfig(
      baseUrl: Uri.parse(base),
      headers:
          headers ??
          () async {
            headerCalls++;
            return {'Authorization': 'Bearer $appToken'};
          },
      httpClient: server.client,
      timeout: timeout,
    ),
  );

  setUp(() {
    headerCalls = 0;
    server = Recorder();
    client = makeClient();
  });

  group('requests', () {
    test('sessions/new without a body', () async {
      server.reply(201, {'sessionId': 's1'});
      final response = await client.newSession();
      expect(response.sessionId, 's1');
      expect(server.last.method, 'POST');
      expect(
        server.last.url.toString(),
        'https://api.example.com/realtime/sessions/new',
      );
      expect(server.last.body, isEmpty);
      expect(header(server.last, 'Authorization'), 'Bearer $appToken');
      expect(header(server.last, 'X-Realtime-Room'), 'room-1');
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);
      expect(headerCalls, 1);
    });

    test('sessions/new with an offer and correlationId', () async {
      server.reply(201, {
        'sessionId': 's1',
        'sessionDescription': {'type': 'answer', 'sdp': sdp},
      });
      final response = await client.newSession(
        const NewSessionRequest(
          sessionDescription: SessionDescription.offer(sdp),
          correlationId: 'diag 1',
        ),
      );
      expect(response.sessionDescription!.type, SdpType.answer);
      expect(server.last.url.path, '/realtime/sessions/new');
      expect(server.last.url.queryParameters, {'correlationId': 'diag 1'});
      expect(server.lastJson, {
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      });
      expect(
        header(server.last, 'Content-Type'),
        startsWith('application/json'),
      );
    });

    test('base URL with a trailing slash and query', () async {
      client = makeClient(base: 'https://api.example.com/rt/?v=2');
      server.reply(200, {'sessionId': 's1'});
      await client.newSession();
      expect(
        server.last.url.toString(),
        'https://api.example.com/rt/sessions/new?v=2',
      );
    });

    test('tracks/new push', () async {
      server.reply(200, {
        'requiresImmediateRenegotiation': false,
        'tracks': [
          {'trackName': 'cam', 'mid': '0'},
        ],
        'sessionDescription': {'type': 'answer', 'sdp': sdp},
      });
      final response = await client.newTracks(
        's1',
        const TracksRequest(
          sessionDescription: SessionDescription.offer(sdp),
          tracks: [TrackObject.local(mid: '0', trackName: 'cam')],
        ),
      );
      expect(server.last.method, 'POST');
      expect(server.last.url.path, '/realtime/sessions/s1/tracks/new');
      expect(server.lastJson, {
        'tracks': [
          {'location': 'local', 'mid': '0', 'trackName': 'cam'},
        ],
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      });
      expect(response.tracks.single.mid, '0');
      expect(response.sessionDescription!.type, SdpType.answer);
    });

    test('tracks/new pull with simulcast and per-track errors', () async {
      server.reply(200, {
        'requiresImmediateRenegotiation': true,
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
        'tracks': [
          {'sessionId': 'p1', 'trackName': 'cam', 'mid': '3'},
          {
            'sessionId': 'p2',
            'trackName': 'gone',
            'errorCode': 'not_found',
            'errorDescription': 'track not found',
          },
        ],
      });
      final response = await client.newTracks(
        's1',
        const TracksRequest(
          tracks: [
            TrackObject.remote(
              sessionId: 'p1',
              trackName: 'cam',
              simulcast: SimulcastConfig(
                preferredRid: 'b',
                ridNotAvailable: SimulcastOrdering.asciibetical,
              ),
            ),
            TrackObject.remote(sessionId: 'p2', trackName: 'gone'),
          ],
        ),
      );
      expect(server.lastJson, {
        'tracks': [
          {
            'location': 'remote',
            'sessionId': 'p1',
            'trackName': 'cam',
            'simulcast': {
              'preferredRid': 'b',
              'ridNotAvailable': 'asciibetical',
            },
          },
          {'location': 'remote', 'sessionId': 'p2', 'trackName': 'gone'},
        ],
      });
      expect(response.requiresImmediateRenegotiation, isTrue);
      expect(response.hasError, isFalse);
      expect(response.tracks[0].hasError, isFalse);
      expect(response.tracks[1].errorCode, 'not_found');
      expect(response.tracks[1].errorDescription, 'track not found');
      expect(response.trackErrors.single.trackName, 'gone');
    });

    test('tracks/update', () async {
      server.reply(200, {
        'requiresImmediateRenegotiation': false,
        'tracks': [
          {'mid': '3', 'sessionId': 'p1', 'trackName': 'cam'},
        ],
      });
      await client.updateTracks(
        's1',
        const UpdateTracksRequest(
          tracks: [
            TrackObject.remote(
              sessionId: 'p1',
              trackName: 'cam',
              mid: '3',
              simulcast: SimulcastConfig(preferredRid: 'c'),
            ),
          ],
        ),
      );
      expect(server.last.method, 'PUT');
      expect(server.last.url.path, '/realtime/sessions/s1/tracks/update');
      expect(
        (server.lastJson['tracks'] as List).single,
        containsPair('mid', '3'),
      );
    });

    test('renegotiate with an empty response body', () async {
      server.reply(200);
      final response = await client.renegotiate(
        's1',
        const RenegotiateRequest(
          sessionDescription: SessionDescription.answer(sdp),
        ),
      );
      expect(server.last.method, 'PUT');
      expect(server.last.url.path, '/realtime/sessions/s1/renegotiate');
      expect(server.lastJson, {
        'sessionDescription': {'type': 'answer', 'sdp': sdp},
      });
      expect(response.hasError, isFalse);
    });

    test('tracks/close with force', () async {
      server.reply(200, {
        'requiresImmediateRenegotiation': false,
        'tracks': [
          {'mid': '0'},
          {
            'mid': '1',
            'errorCode': 'close_track_error',
            'errorDescription': 'already closed',
          },
        ],
      });
      final response = await client.closeTracks(
        's1',
        CloseTracksRequest(mids: ['0', '1'], force: true),
      );
      expect(server.last.method, 'PUT');
      expect(server.last.url.path, '/realtime/sessions/s1/tracks/close');
      expect(server.lastJson, {
        'tracks': [
          {'mid': '0'},
          {'mid': '1'},
        ],
        'force': true,
      });
      expect(response.trackErrors.single.mid, '1');
    });

    test('GET session state', () async {
      server.reply(200, {
        'tracks': [
          {
            'location': 'local',
            'mid': '0',
            'trackName': 'cam',
            'status': 'active',
          },
        ],
      });
      final state = await client.getSessionState('s1');
      expect(server.last.method, 'GET');
      expect(server.last.url.path, '/realtime/sessions/s1');
      expect(server.last.body, isEmpty);
      expect(state.tracks.single.status, ResourceStatus.active);
    });

    test('datachannels establish/new/update/close', () async {
      server
        ..reply(200, {
          'requiresImmediateRenegotiation': true,
          'sessionDescription': {'type': 'offer', 'sdp': sdp},
          'dataChannel': {'dataChannelName': 'server-events', 'id': 0},
        })
        ..reply(200, {
          'dataChannels': [
            {'location': 'local', 'dataChannelName': 'input', 'id': 3},
          ],
        })
        ..reply(200, {
          'dataChannels': [
            {
              'location': 'remote',
              'dataChannelName': 'input',
              'canReply': true,
              'id': 4,
            },
          ],
        })
        ..reply(200, {
          'dataChannels': [
            {'id': 3},
          ],
        });

      final established = await client.establishDataChannels('s1');
      expect(server.last.method, 'POST');
      expect(
        server.last.url.path,
        '/realtime/sessions/s1/datachannels/establish',
      );
      expect(server.lastJson, {
        'dataChannel': {
          'location': 'remote',
          'dataChannelName': 'server-events',
        },
      });
      expect(established.requiresImmediateRenegotiation, isTrue);
      expect(established.dataChannel!.id, 0);

      final created = await client.newDataChannels(
        's1',
        DataChannelsRequest(dataChannels: [DataChannelObject.local('input')]),
      );
      expect(server.last.method, 'POST');
      expect(server.last.url.path, '/realtime/sessions/s1/datachannels/new');
      expect(server.lastJson, {
        'dataChannels': [
          {'location': 'local', 'dataChannelName': 'input'},
        ],
      });
      expect(created.dataChannels.single.id, 3);

      await client.updateDataChannels(
        's1',
        DataChannelsRequest(
          dataChannels: [
            DataChannelObject.remote(
              sessionId: 'p1',
              dataChannelName: 'input',
              canReply: true,
            ),
          ],
        ),
      );
      expect(server.last.method, 'PUT');
      expect(server.last.url.path, '/realtime/sessions/s1/datachannels/update');

      await client.closeDataChannels(
        's1',
        DataChannelsRequest(dataChannels: [DataChannelObject.withId(3)]),
      );
      expect(server.last.method, 'PUT');
      expect(server.last.url.path, '/realtime/sessions/s1/datachannels/close');
      expect(server.lastJson, {
        'dataChannels': [
          {'id': 3},
        ],
      });
    });

    test('generate-ice-servers', () async {
      server.reply(200, {
        'iceServers': [
          {
            'urls': ['stun:stun.cloudflare.com:3478'],
          },
          {
            'urls': ['turn:turn.cloudflare.com:3478?transport=udp'],
            'username': 'u',
            'credential': 'c',
          },
        ],
      });
      final servers = await client.getIceServers();
      expect(server.last.method, 'POST');
      expect(server.last.url.path, '/realtime/generate-ice-servers');
      expect(header(server.last, 'X-Realtime-Room'), 'room-1');
      expect(servers, [
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {
          'urls': 'turn:turn.cloudflare.com:3478?transport=udp',
          'username': 'u',
          'credential': 'c',
        },
      ]);
    });

    test('session IDs are path-encoded', () async {
      server.reply(200, {});
      await client.getSessionState('a/b c');
      expect(server.last.url.pathSegments.last, 'a/b c');
      expect(server.last.url.path, '/realtime/sessions/a%2Fb%20c');
    });

    test('app headers cannot override the room or session token', () async {
      client = makeClient(
        headers: () async => {
          'Authorization': 'Bearer x',
          'x-realtime-room': 'other-room',
          'X-Realtime-Session-Token': 'forged',
          'X-App': 'yes',
        },
      );
      server.reply(200, {});
      await client.getSessionState('s1');
      expect(header(server.last, 'X-Realtime-Room'), 'room-1');
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);
      expect(header(server.last, 'X-App'), 'yes');
    });

    test('rejects invalid room IDs and session IDs', () {
      expect(
        () => HttpBrokerClient(
          roomId: '',
          config: BrokerConfig(
            baseUrl: Uri.parse('https://x'),
            headers: () async => {},
          ),
        ),
        throwsArgumentError,
      );
      expect(
        () => HttpBrokerClient(
          roomId: 'a\r\nb',
          config: BrokerConfig(
            baseUrl: Uri.parse('https://x'),
            headers: () async => {},
          ),
        ),
        throwsArgumentError,
      );
      expect(() => client.getSessionState(''), throwsArgumentError);
    });
  });

  group('session token', () {
    test('is captured from sessions/new and echoed per session', () async {
      server
        ..reply(201, {'sessionId': 's1'}, {'X-Realtime-Session-Token': 'tok-1'})
        ..reply(201, {'sessionId': 's2'}, {'x-realtime-session-token': 'tok-2'})
        ..reply(200, {})
        ..reply(200, {})
        ..reply(200, {'iceServers': <Object?>[]});

      await client.newSession();
      await client.newSession();
      // A later sessions/new never carries a token.
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);

      await client.getSessionState('s1');
      expect(header(server.last, 'X-Realtime-Session-Token'), 'tok-1');
      await client.renegotiate(
        's2',
        const RenegotiateRequest(
          sessionDescription: SessionDescription.answer(sdp),
        ),
      );
      expect(header(server.last, 'X-Realtime-Session-Token'), 'tok-2');
      await client.getIceServers();
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);
    });

    test('is optional', () async {
      server
        ..reply(201, {'sessionId': 's1'})
        ..reply(200, {});
      await client.newSession();
      await client.getSessionState('s1');
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);
      expect(header(server.last, 'X-Realtime-Room'), 'room-1');
    });

    test('forgetSession drops it', () async {
      server
        ..reply(201, {'sessionId': 's1'}, {'X-Realtime-Session-Token': 'tok'})
        ..reply(200, {});
      await client.newSession();
      client.forgetSession('s1');
      await client.getSessionState('s1');
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);
    });

    test('is dropped when the session is gone', () async {
      server
        ..reply(201, {'sessionId': 's1'}, {'X-Realtime-Session-Token': 'tok'})
        ..reply(410, {'errorCode': 'session_error'})
        ..reply(200, {});
      await client.newSession();
      await expectLater(
        client.getSessionState('s1'),
        throwsA(isA<SessionGoneException>()),
      );
      await client.getSessionState('s1');
      expect(header(server.last, 'X-Realtime-Session-Token'), isNull);
    });
  });

  group('errors', () {
    Future<Object> errorOf(Future<Object?> future) async {
      try {
        await future;
      } catch (e) {
        return e;
      }
      fail('Expected an exception');
    }

    test('401 maps to BrokerUnauthorizedException', () async {
      server.reply(401, 'unauthorized');
      final e = await errorOf(client.newSession());
      expect(e, isA<BrokerUnauthorizedException>());
      e as BrokerException;
      expect(e.statusCode, 401);
      expect(e.operation, 'sessions/new');
      expect(e.errorCode, isNull);
    });

    test('403 maps to BrokerForbiddenException with the error body', () async {
      server.reply(403, {
        'errorCode': 'forbidden',
        'errorDescription': 'not a member of this room',
      });
      final e = await errorOf(
        client.newTracks(
          's1',
          const TracksRequest(
            tracks: [TrackObject.remote(sessionId: 'p', trackName: 't')],
          ),
        ),
      );
      expect(e, isA<BrokerForbiddenException>());
      e as BrokerException;
      expect(e.statusCode, 403);
      expect(e.errorCode, 'forbidden');
      expect(e.errorDescription, 'not a member of this room');
      expect(e.operation, 'tracks/new');
    });

    test('410 maps to SessionGoneException', () async {
      server.reply(410, {
        'errorCode': 'session_error',
        'errorDescription': 'session expired',
      });
      final e = await errorOf(client.getSessionState('s1'));
      expect(e, isA<SessionGoneException>());
      e as SessionGoneException;
      expect(e.statusCode, 410);
      expect(e.sessionId, 's1');
      expect(e.errorCode, 'session_error');
      expect(e.operation, 'sessions/{id}');
    });

    test('410 without a body still maps to SessionGoneException', () async {
      server.reply(410);
      expect(
        await errorOf(client.getSessionState('s1')),
        isA<SessionGoneException>(),
      );
    });

    test('session_error on another status maps to SessionGone', () async {
      server.reply(400, {'errorCode': 'session_error'});
      expect(
        await errorOf(client.getSessionState('s1')),
        isA<SessionGoneException>().having((e) => e.statusCode, 'status', 400),
      );
    });

    test('session_error in a 2xx body maps to SessionGone', () async {
      server.reply(200, {'errorCode': 'session_error'});
      expect(
        await errorOf(client.getSessionState('s1')),
        isA<SessionGoneException>(),
      );
    });

    test('other statuses pass through as BrokerException', () async {
      server.reply(406, {
        'errorCode': 'invalid_params',
        'errorDescription': 'bad track',
      });
      final e = await errorOf(client.getSessionState('s1'));
      expect(e.runtimeType, BrokerException);
      e as BrokerException;
      expect(e.statusCode, 406);
      expect(e.errorCode, 'invalid_params');
    });

    test('non-JSON error bodies are ignored', () async {
      server.reply(502, '<html>Bad gateway</html>');
      final e = await errorOf(client.getSessionState('s1')) as BrokerException;
      expect(e.statusCode, 502);
      expect(e.errorCode, isNull);
      expect(e.toString(), isNot(contains('html')));
    });

    test('a 2xx request-level error is returned, not thrown', () async {
      server.reply(200, {
        'errorCode': 'invalid_request',
        'errorDescription': 'nope',
        'tracks': <Object?>[],
      });
      final response = await client.newTracks(
        's1',
        const TracksRequest(tracks: []),
      );
      expect(response.hasError, isTrue);
      expect(response.errorCode, 'invalid_request');
    });

    test('a 2xx sessions/new error without sessionId throws', () async {
      server.reply(201, {'errorCode': 'x', 'errorDescription': 'y'});
      final e = await errorOf(client.newSession()) as BrokerException;
      expect(e.errorCode, 'x');
      expect(e.statusCode, 201);
    });

    test('malformed 2xx bodies map to BrokerProtocolException', () async {
      server
        ..reply(200, 'not json')
        ..reply(201, {'sessionId': 42})
        ..reply(200, {
          'tracks': 'nope',
          'sessionDescription': {'type': 'offer', 'sdp': sdp},
        });
      expect(
        await errorOf(client.getSessionState('s1')),
        isA<BrokerProtocolException>(),
      );
      expect(
        await errorOf(client.newSession()),
        isA<BrokerProtocolException>(),
      );
      final e = await errorOf(
        client.newTracks('s1', const TracksRequest(tracks: [])),
      );
      expect(e, isA<BrokerProtocolException>());
      expect(e.toString(), contains('tracks'));
      expect(e.toString(), isNot(contains('sdp-secret')));
    });

    test('network errors map to BrokerNetworkException', () async {
      server.replyWith(
        (r) => throw http.ClientException('connection refused', r.url),
      );
      final e = await errorOf(client.getSessionState('s1'));
      expect(e, isA<BrokerNetworkException>());
      expect(e, isNot(isA<BrokerTimeoutException>()));
      expect((e as BrokerNetworkException).cause, isA<http.ClientException>());
    });

    test('timeouts map to BrokerTimeoutException', () {
      fakeAsync((async) {
        client = makeClient(timeout: const Duration(seconds: 5));
        server.replyWith((_) => Completer<http.Response>().future);
        Object? error;
        client.getSessionState('s1').catchError((Object e) {
          error = e;
          return const SessionState();
        });
        async.elapse(const Duration(seconds: 4));
        expect(error, isNull);
        async.elapse(const Duration(seconds: 2));
        expect(
          error,
          isA<BrokerTimeoutException>().having(
            (e) => e.timeout,
            'timeout',
            const Duration(seconds: 5),
          ),
        );
      });
    });

    test('header provider errors propagate unchanged', () async {
      client = makeClient(headers: () async => throw StateError('no login'));
      expect(await errorOf(client.newSession()), isA<StateError>());
      expect(server.requests, isEmpty);
    });

    test('messages never include tokens, SDP or header values', () async {
      server
        ..reply(
          201,
          {'sessionId': 's1'},
          {'X-Realtime-Session-Token': 'tok-secret'},
        )
        ..reply(500, {
          'errorCode': 'internal_error',
          'errorDescription': 'boom',
        });
      await client.newSession();
      final e = await errorOf(
        client.newTracks(
          's1',
          const TracksRequest(
            sessionDescription: SessionDescription.offer(sdp),
            tracks: [TrackObject.local(mid: '0', trackName: 'cam')],
          ),
        ),
      );
      final text = e.toString();
      expect(text, contains('internal_error'));
      expect(text, contains('500'));
      for (final secret in ['tok-secret', appToken, 'sdp-secret', 'room-1']) {
        expect(text, isNot(contains(secret)));
      }
    });

    test('long error descriptions are truncated', () async {
      server.reply(500, {'errorDescription': 'x' * 1000});
      final e = await errorOf(client.getSessionState('s1'));
      expect(e.toString().length, lessThan(300));
    });
  });

  group('lifecycle', () {
    test('dispose closes an owned client only', () async {
      client.dispose();
      expect(() => client.getSessionState('s1'), throwsStateError);
      // The injected MockClient still works after dispose.
      server.reply(200, {});
      final other = makeClient();
      await other.getSessionState('s1');
      other.dispose();
      other.dispose(); // idempotent
    });

    test('an owned client is created when none is injected', () {
      final owned = HttpBrokerClient(
        roomId: 'r',
        config: BrokerConfig(
          baseUrl: Uri.parse('https://x'),
          headers: () async => {},
        ),
      );
      owned.dispose();
    });
  });
}
