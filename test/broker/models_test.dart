import 'dart:convert';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Encodes and decodes [json] so tests compare plain JSON values.
Object? roundTrip(Object? json) => jsonDecode(jsonEncode(json));

const sdp = 'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\na=ice-pwd:secretpwd\r\n';

void main() {
  group('SessionDescription', () {
    test('round-trips', () {
      final json = {'type': 'offer', 'sdp': sdp};
      final parsed = SessionDescription.fromJson(json);
      expect(parsed.type, SdpType.offer);
      expect(parsed.sdp, sdp);
      expect(roundTrip(parsed.toJson()), json);
      expect(const SessionDescription.answer('x').toJson(), {
        'type': 'answer',
        'sdp': 'x',
      });
    });

    test('rejects a missing or unknown type', () {
      expect(
        () => SessionDescription.fromJson({'sdp': sdp}),
        throwsFormatException,
      );
      expect(
        () => SessionDescription.fromJson({'type': 'pranswer', 'sdp': sdp}),
        throwsFormatException,
      );
    });

    test('toString hides the SDP', () {
      final s = const SessionDescription.offer(sdp).toString();
      expect(s, isNot(contains('secretpwd')));
      expect(s, contains('offer'));
    });
  });

  group('TrackObject', () {
    test('local push shape', () {
      expect(const TrackObject.local(mid: '0', trackName: 'cam').toJson(), {
        'location': 'local',
        'mid': '0',
        'trackName': 'cam',
      });
    });

    test('remote pull shape with simulcast', () {
      const track = TrackObject.remote(
        sessionId: 'pub-1',
        trackName: 'cam',
        simulcast: SimulcastOptions(
          preferredRid: 'b',
          priorityOrdering: SimulcastOrdering.asciibetical,
          ridNotAvailable: SimulcastOrdering.asciibetical,
        ),
      );
      final json = {
        'location': 'remote',
        'sessionId': 'pub-1',
        'trackName': 'cam',
        'simulcast': {
          'preferredRid': 'b',
          'priorityOrdering': 'asciibetical',
          'ridNotAvailable': 'asciibetical',
        },
      };
      expect(roundTrip(track.toJson()), json);
      expect(roundTrip(TrackObject.fromJson(json).toJson()), json);
    });

    test('simulcast omits unset orderings', () {
      expect(const SimulcastOptions(preferredRid: 'a').toJson(), {
        'preferredRid': 'a',
      });
    });

    test('general constructor carries every schema field', () {
      final json = {
        'location': 'local',
        'mid': '#mic-1',
        'trackName': 'mic-1',
        'kind': 'audio',
        'bidirectionalMediaStream': true,
      };
      expect(roundTrip(TrackObject.fromJson(json).toJson()), json);
    });
  });

  group('TracksRequest', () {
    test('push round-trips', () {
      final json = {
        'tracks': [
          {'location': 'local', 'mid': '4', 'trackName': 'cam'},
        ],
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      };
      expect(roundTrip(TracksRequest.fromJson(json).toJson()), json);
    });

    test('pull has no session description', () {
      const request = TracksRequest(
        tracks: [TrackObject.remote(sessionId: 's', trackName: 't')],
      );
      expect(request.toJson().containsKey('sessionDescription'), isFalse);
    });

    test('autoDiscover round-trips', () {
      final json = {
        'tracks': <Object?>[],
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
        'autoDiscover': true,
      };
      expect(roundTrip(TracksRequest.fromJson(json).toJson()), json);
    });
  });

  group('TracksResponse', () {
    test('parses a pull that requires renegotiation', () {
      final response = TracksResponse.fromJson({
        'requiresImmediateRenegotiation': true,
        'tracks': [
          {'sessionId': 'pub-1', 'trackName': 'cam', 'mid': '7'},
        ],
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      });
      expect(response.requiresImmediateRenegotiation, isTrue);
      expect(response.sessionDescription!.type, SdpType.offer);
      expect(response.tracks.single.mid, '7');
      expect(response.tracks.single.sessionId, 'pub-1');
      expect(response.hasError, isFalse);
      expect(response.trackErrors, isEmpty);
    });

    test('parses per-track errors', () {
      final json = {
        'requiresImmediateRenegotiation': false,
        'tracks': [
          {'mid': '0'},
          {
            'mid': '1',
            'errorCode': 'close_track_error',
            'errorDescription': "Track doesn't exist or was already closed",
          },
          {
            'mid': '2',
            'errorCode': 'internal_error',
            'errorDescription': 'Backend error',
          },
        ],
      };
      final response = TracksResponse.fromJson(json);
      expect(response.hasError, isFalse);
      expect(response.tracks[0].hasError, isFalse);
      expect(response.tracks[1].hasError, isTrue);
      expect(response.tracks[1].errorCode, 'close_track_error');
      expect(
        response.tracks[1].errorDescription,
        "Track doesn't exist or was already closed",
      );
      expect(response.trackErrors.map((t) => t.mid), ['1', '2']);
      expect(roundTrip(response.toJson()), json);
    });

    test('parses a request-level error', () {
      final response = TracksResponse.fromJson({
        'errorCode': 'invalid_request',
        'errorDescription': 'bad',
      });
      expect(response.hasError, isTrue);
      expect(response.errorCode, 'invalid_request');
      expect(response.tracks, isEmpty);
      expect(response.requiresImmediateRenegotiation, isFalse);
    });

    test('a pulled track echoes simulcast', () {
      final response = TracksResponse.fromJson({
        'tracks': [
          {
            'sessionId': 'p',
            'trackName': 't',
            'mid': '5',
            'simulcast': {'preferredRid': 'h', 'priorityOrdering': 'weird'},
          },
        ],
      });
      final simulcast = response.tracks.single.simulcast!;
      expect(simulcast.preferredRid, 'h');
      // Unknown enum values parse as null rather than failing.
      expect(simulcast.priorityOrdering, isNull);
    });

    test('rejects wrong field types', () {
      expect(
        () => TracksResponse.fromJson({'tracks': 'nope'}),
        throwsFormatException,
      );
      expect(
        () => TracksResponse.fromJson({
          'tracks': [
            {'mid': 7},
          ],
        }),
        throwsFormatException,
      );
    });
  });

  group('UpdateTracksRequest', () {
    test('round-trips', () {
      final json = {
        'tracks': [
          {
            'location': 'remote',
            'mid': '8',
            'sessionId': 'p',
            'trackName': 'cam',
            'simulcast': {'preferredRid': 'c'},
          },
        ],
      };
      final request = UpdateTracksRequest(
        tracks: [
          const TrackObject.remote(
            sessionId: 'p',
            trackName: 'cam',
            mid: '8',
            simulcast: SimulcastOptions(preferredRid: 'c'),
          ),
        ],
      );
      expect(roundTrip(request.toJson()), json);
      expect(roundTrip(UpdateTracksRequest.fromJson(json).toJson()), json);
    });
  });

  group('CloseTracksRequest', () {
    test('negotiated shape', () {
      final request = CloseTracksRequest(
        mids: ['7'],
        sessionDescription: const SessionDescription.offer(sdp),
      );
      final json = {
        'tracks': [
          {'mid': '7'},
        ],
        'force': false,
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      };
      expect(roundTrip(request.toJson()), json);
      expect(roundTrip(CloseTracksRequest.fromJson(json).toJson()), json);
    });

    test('forced shape', () {
      expect(CloseTracksRequest(mids: ['0', '1'], force: true).toJson(), {
        'tracks': [
          {'mid': '0'},
          {'mid': '1'},
        ],
        'force': true,
      });
    });

    test('validates arguments', () {
      expect(
        () => CloseTracksRequest(mids: [], force: true),
        throwsArgumentError,
      );
      expect(() => CloseTracksRequest(mids: ['0']), throwsArgumentError);
    });
  });

  group('Renegotiate', () {
    test('request round-trips', () {
      final json = {
        'sessionDescription': {'type': 'answer', 'sdp': sdp},
      };
      expect(roundTrip(RenegotiateRequest.fromJson(json).toJson()), json);
    });

    test('empty response parses', () {
      final response = RenegotiateResponse.fromJson({});
      expect(response.hasError, isFalse);
      expect(response.sessionDescription, isNull);
      expect(response.toJson(), isEmpty);
    });
  });

  group('sessions/new', () {
    test('request body omits correlationId', () {
      const request = NewSessionRequest(
        sessionDescription: SessionDescription.offer(sdp),
        correlationId: 'diag-1',
      );
      expect(request.hasBody, isTrue);
      expect(request.toJson(), {
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      });
      expect(const NewSessionRequest().hasBody, isFalse);
      expect(
        NewSessionRequest.fromJson(request.toJson()).sessionDescription?.sdp,
        sdp,
      );
    });

    test('response round-trips and requires sessionId', () {
      final json = {
        'sessionId': 'abc',
        'sessionDescription': {'type': 'answer', 'sdp': sdp},
      };
      final response = NewSessionResponse.fromJson(json);
      expect(response.sessionId, 'abc');
      expect(roundTrip(response.toJson()), json);
      expect(() => NewSessionResponse.fromJson({}), throwsFormatException);
    });
  });

  group('SessionState', () {
    test('parses the schema example', () {
      final json = {
        'tracks': [
          {
            'location': 'local',
            'mid': '2',
            'trackName': 'cam',
            'status': 'active',
          },
          {
            'location': 'remote',
            'mid': '7',
            'sessionId': 'p',
            'trackName': 'mic',
            'status': 'inactive',
          },
        ],
        'dataChannels': [
          {
            'location': 'remote',
            'sessionId': 'p',
            'dataChannelName': 'controls',
            'id': 2,
            'status': 'initializing',
          },
        ],
      };
      final state = SessionState.fromJson(json);
      expect(state.tracks[0].location, TrackLocation.local);
      expect(state.tracks[0].status, ResourceStatus.active);
      expect(state.tracks[1].status, ResourceStatus.inactive);
      expect(state.dataChannels.single.id, 2);
      expect(state.dataChannels.single.status, ResourceStatus.initializing);
      expect(roundTrip(state.toJson()), json);
    });

    test('unknown status parses as unknown', () {
      final state = SessionState.fromJson({
        'tracks': [
          {'mid': '1', 'status': 'paused'},
        ],
      });
      expect(state.tracks.single.status, ResourceStatus.unknown);
      expect(state.dataChannels, isEmpty);
    });
  });

  group('DataChannels', () {
    test('local publisher shapes', () {
      expect(DataChannelObject.local('input').toJson(), {
        'location': 'local',
        'dataChannelName': 'input',
      });
      expect(
        DataChannelObject.local(
          'moves',
          ordered: false,
          maxRetransmits: 0,
        ).toJson(),
        {
          'location': 'local',
          'dataChannelName': 'moves',
          'ordered': false,
          'maxRetransmits': 0,
        },
      );
    });

    test('remote subscriber shape', () {
      final json = {
        'location': 'remote',
        'dataChannelName': 'input',
        'sessionId': 'pub',
        'waitForAck': true,
        'canReply': true,
      };
      final object = DataChannelObject.remote(
        sessionId: 'pub',
        dataChannelName: 'input',
        waitForAck: true,
        canReply: true,
      );
      expect(object.toJson(), json);
      expect(roundTrip(DataChannelObject.fromJson(json).toJson()), json);
    });

    test('close by id', () {
      expect(
        DataChannelsRequest(
          dataChannels: [DataChannelObject.withId(2)],
        ).toJson(),
        {
          'dataChannels': [
            {'id': 2},
          ],
        },
      );
    });

    test('rejects both retry limits', () {
      expect(
        () => DataChannelObject.local(
          'x',
          maxRetransmits: 0,
          maxPacketLifeTime: 100,
        ),
        throwsArgumentError,
      );
    });

    test('request round-trips', () {
      final json = {
        'dataChannels': [
          {'location': 'local', 'dataChannelName': 'a', 'ordered': true},
          {
            'location': 'remote',
            'dataChannelName': 'b',
            'sessionId': 's',
            'maxPacketLifeTime': 500,
          },
        ],
      };
      expect(roundTrip(DataChannelsRequest.fromJson(json).toJson()), json);
    });

    test('response parses ids and per-channel errors', () {
      final json = {
        'dataChannels': [
          {'location': 'local', 'dataChannelName': 'a', 'id': 3},
          {
            'location': 'remote',
            'dataChannelName': 'b',
            'sessionId': 's',
            'errorCode': 'not_found',
            'errorDescription': 'no such channel',
          },
        ],
      };
      final response = DataChannelsResponse.fromJson(json);
      expect(response.dataChannels[0].id, 3);
      expect(response.dataChannels[0].hasError, isFalse);
      expect(response.dataChannelErrors.single.dataChannelName, 'b');
      expect(response.dataChannelErrors.single.errorCode, 'not_found');
      expect(roundTrip(response.toJson()), json);
    });

    test('integral numeric id parses', () {
      final result = DataChannelResult.fromJson({'id': 4.0});
      expect(result.id, 4);
      expect(
        () => DataChannelResult.fromJson({'id': 4.5}),
        throwsFormatException,
      );
    });

    test('establish defaults to pulling server-events', () {
      expect(EstablishDataChannelsRequest().toJson(), {
        'dataChannel': {
          'location': 'remote',
          'dataChannelName': 'server-events',
        },
      });
    });

    test('establish round-trips', () {
      final request = {
        'dataChannel': {
          'location': 'remote',
          'dataChannelName': 'server-events',
        },
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
      };
      expect(
        roundTrip(EstablishDataChannelsRequest.fromJson(request).toJson()),
        request,
      );
      final response = {
        'requiresImmediateRenegotiation': true,
        'sessionDescription': {'type': 'offer', 'sdp': sdp},
        'dataChannel': {'dataChannelName': 'server-events', 'id': 0},
      };
      final parsed = EstablishDataChannelsResponse.fromJson(response);
      expect(parsed.requiresImmediateRenegotiation, isTrue);
      expect(parsed.dataChannel!.id, 0);
      expect(roundTrip(parsed.toJson()), response);
    });
  });

  group('ICE servers', () {
    test('parses the array shape and flattens for flutter_webrtc', () {
      final json = {
        'iceServers': [
          {
            'urls': [
              'stun:stun.cloudflare.com:3478',
              'stun:stun.cloudflare.com:53',
            ],
          },
          {
            'urls': [
              'turn:turn.cloudflare.com:3478?transport=udp',
              'turns:turn.cloudflare.com:443?transport=tcp',
            ],
            'username': 'user',
            'credential': 'cred',
          },
        ],
      };
      final response = IceServersResponse.fromJson(json);
      expect(roundTrip(response.toJson()), json);
      expect(response.toRtcIceServers(), [
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {'urls': 'stun:stun.cloudflare.com:53'},
        {
          'urls': 'turn:turn.cloudflare.com:3478?transport=udp',
          'username': 'user',
          'credential': 'cred',
        },
        {
          'urls': 'turns:turn.cloudflare.com:443?transport=tcp',
          'username': 'user',
          'credential': 'cred',
        },
      ]);
    });

    test('accepts a single object and a string url', () {
      final response = IceServersResponse.fromJson({
        'iceServers': {'urls': 'stun:stun.cloudflare.com:3478'},
      });
      expect(response.iceServers.single.urls, [
        'stun:stun.cloudflare.com:3478',
      ]);
    });

    test('rejects a missing list', () {
      expect(() => IceServersResponse.fromJson({}), throwsFormatException);
      expect(
        () => IceServersResponse.fromJson({
          'iceServers': [
            {'urls': 3},
          ],
        }),
        throwsFormatException,
      );
    });

    test('toString hides the credential', () {
      final server = IceServer(
        urls: ['turn:x'],
        username: 'user-name',
        credential: 'top-secret',
      );
      expect(server.toString(), isNot(contains('top-secret')));
      expect(server.toString(), isNot(contains('user-name')));
    });
  });
}
