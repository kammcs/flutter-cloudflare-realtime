import 'dart:async';
import 'dart:typed_data';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

import '../support/session_harness.dart';

List<Map<String, Object?>> _json(BrokerCall call) => [
  for (final d in (call.request! as DataChannelsRequest).dataChannels)
    d.toJson(),
];

void main() {
  late SessionHarness h;

  setUp(() => h = SessionHarness());

  group('establish', () {
    test(
      'answers the SFU offer once, before the first datachannels/new',
      () async {
        final session = await h.connect();

        await session.publishDataChannel('chat');
        await session.publishDataChannel('input');
        await session.subscribeDataChannel('session-x', 'cursor');

        expect(h.broker.operations, [
          'sessions/new',
          'generate-ice-servers',
          'datachannels/establish',
          'renegotiate',
          'datachannels/new',
          'datachannels/new',
          'datachannels/new',
        ]);
        final establish = h.broker.callsTo('datachannels/establish').single;
        final request = establish.request! as EstablishDataChannelsRequest;
        expect(request.sessionDescription, isNull, reason: 'the SFU offers');
        expect(request.dataChannel.toJson(), {
          'location': 'remote',
          'dataChannelName': 'server-events',
        });
        expect(h.pc.log.take(3), [
          'setRemoteDescription(offer)',
          'createAnswer',
          'setLocalDescription(answer)',
        ]);
        final renegotiate =
            h.broker.callsTo('renegotiate').single.request!
                as RenegotiateRequest;
        expect(renegotiate.sessionDescription.type, SdpType.answer);
      },
    );

    test(
      'a failed establish fails the batch and is retried next time',
      () async {
        final session = await h.connect();
        h.broker.onEstablishDataChannels = (_, _) async =>
            const EstablishDataChannelsResponse(errorCode: 'internal_error');

        await expectLater(
          session.publishDataChannel('chat'),
          throwsA(
            isA<SfuRequestException>().having(
              (e) => e.operation,
              'operation',
              'datachannels/establish',
            ),
          ),
        );
        expect(h.broker.callsTo('datachannels/new'), isEmpty);
        expect(session.dataChannels, isEmpty);

        h.broker.onEstablishDataChannels = null;
        final chat = await session.publishDataChannel('chat');
        expect(chat.state, SfuDataChannelState.connecting);
        expect(h.broker.callsTo('datachannels/establish'), hasLength(2));
      },
    );

    test('runs through the op queue with track operations', () async {
      final session = await h.connect();
      final pub = session.publish(FakeMediaStreamTrack(kind: 'audio'));
      final chat = session.publishDataChannel('chat');
      await Future.wait([pub, chat]);
      expect(h.broker.operations.skip(2), [
        'tracks/new',
        'datachannels/establish',
        'renegotiate',
        'datachannels/new',
      ]);
    });
  });

  group('publish', () {
    test('reliable: ordered, no retransmit limit, negotiated id', () async {
      final session = await h.connect();
      final chat = await session.publishDataChannel('chat');

      expect(_json(h.broker.callsTo('datachannels/new').single), [
        {'location': 'local', 'dataChannelName': 'chat', 'ordered': true},
      ]);
      final dc = h.pc.dataChannels.single;
      expect(dc.label, 'chat');
      expect(dc.id, 1);
      expect(dc.ordered, isTrue);
      expect(dc.maxRetransmits, isNull);
      expect(h.pc.log.last, 'createDataChannel(chat, 1)');

      expect(chat.name, 'chat');
      expect(chat.profile, DataChannelProfile.reliable);
      expect(chat.id, 1);
      expect(chat.session, same(session));
      expect(chat.sessionId, 'session-1');
      expect(chat.state, SfuDataChannelState.connecting);
      expect(session.dataChannels, [chat]);
    });

    test('unreliable: unordered, maxRetransmits 0 on both sides', () async {
      final session = await h.connect();
      await session.publishDataChannel(
        'pointer',
        profile: DataChannelProfile.unreliable,
      );

      expect(_json(h.broker.callsTo('datachannels/new').single), [
        {
          'location': 'local',
          'dataChannelName': 'pointer',
          'ordered': false,
          'maxRetransmits': 0,
        },
      ]);
      final dc = h.pc.dataChannels.single;
      expect(dc.ordered, isFalse);
      expect(dc.maxRetransmits, 0);
    });

    test('batches publishes and subscribes of one turn by location', () async {
      final session = await h.connect();
      final results = await Future.wait([
        session.publishDataChannel('a'),
        session.publishDataChannel('b'),
        session.subscribeDataChannel('session-x', 'c'),
      ]);

      final calls = h.broker.callsTo('datachannels/new');
      expect(calls, hasLength(2));
      expect(
        [for (final d in _json(calls[0])) d['dataChannelName']],
        ['a', 'b'],
      );
      expect(_json(calls[1]).single['location'], 'remote');
      expect([for (final c in results) c.id], [1, 2, 3]);
      expect(h.broker.callsTo('datachannels/establish'), hasLength(1));
    });

    test('rejects empty, reserved and duplicate names', () async {
      final session = await h.connect();
      expect(() => session.publishDataChannel(''), throwsArgumentError);
      expect(
        () => session.publishDataChannel('server-events'),
        throwsArgumentError,
      );
      await session.publishDataChannel('chat');
      expect(() => session.publishDataChannel('chat'), throwsStateError);
    });
  });

  group('subscribe', () {
    test('requests the remote channel and mirrors the profile', () async {
      final session = await h.connect();
      final input = await session.subscribeDataChannel(
        'session-pub',
        'input',
        profile: DataChannelProfile.unreliable,
      );

      expect(_json(h.broker.callsTo('datachannels/new').single), [
        {
          'location': 'remote',
          'dataChannelName': 'input',
          'sessionId': 'session-pub',
          'ordered': false,
          'maxRetransmits': 0,
        },
      ]);
      final dc = h.pc.dataChannels.single;
      expect(dc.ordered, isFalse);
      expect(dc.maxRetransmits, 0);
      expect(input.remoteSessionId, 'session-pub');
      expect(input.canReply, isFalse);
    });

    test('uses the id returned for this session, not the publisher', () async {
      final publisher = await h.connect();
      final subscriber = await h.connect();
      final publisherPc = h.peerConnections.created[0];
      final subscriberPc = h.peerConnections.created[1];
      h.broker.onNewDataChannels = (sessionId, request) async =>
          DataChannelsResponse(
            dataChannels: [
              for (final d in request.dataChannels)
                DataChannelResult(
                  location: d.location,
                  dataChannelName: d.dataChannelName,
                  sessionId: d.sessionId,
                  id: sessionId == publisher.sessionId ? 3 : 8,
                ),
            ],
          );

      final pub = await publisher.publishDataChannel('input');
      final sub = await subscriber.subscribeDataChannel(
        publisher.sessionId,
        'input',
      );

      expect(pub.id, 3);
      expect(sub.id, 8);
      expect(publisherPc.dataChannels.single.id, 3);
      expect(subscriberPc.dataChannels.single.id, 8);
    });

    test('sends canReply only when granted', () async {
      final session = await h.connect();
      final sub = await session.subscribeDataChannel(
        'session-pub',
        'input',
        canReply: true,
      );
      expect(
        _json(h.broker.callsTo('datachannels/new').single).single['canReply'],
        isTrue,
      );
      expect(sub.canReply, isTrue);
    });

    test('rejects a duplicate subscription on the same session', () async {
      final session = await h.connect();
      await session.subscribeDataChannel('session-pub', 'input');
      expect(
        () => session.subscribeDataChannel('session-pub', 'input'),
        throwsStateError,
      );
      await session.subscribeDataChannel('session-other', 'input');
    });
  });

  group('per-channel errors', () {
    test('an error on one channel fails only that channel', () async {
      final session = await h.connect();
      h.broker.onNewDataChannels = (sessionId, request) async =>
          DataChannelsResponse(
            dataChannels: [
              for (final d in request.dataChannels)
                d.dataChannelName == 'bad'
                    ? DataChannelResult(
                        dataChannelName: d.dataChannelName,
                        errorCode: 'invalid_request',
                        errorDescription: 'nope',
                      )
                    : DataChannelResult(
                        dataChannelName: d.dataChannelName,
                        id: 4,
                      ),
            ],
          );

      final good = session.publishDataChannel('good');
      final bad = session.publishDataChannel('bad');

      expect((await good).id, 4);
      await expectLater(
        bad,
        throwsA(
          isA<SfuDataChannelException>()
              .having((e) => e.name, 'name', 'bad')
              .having((e) => e.errorCode, 'errorCode', 'invalid_request')
              .having((e) => e.operation, 'operation', 'datachannels/new'),
        ),
      );
      expect([for (final c in session.dataChannels) c.name], ['good']);
      expect(h.pc.dataChannels, hasLength(1));
    });

    test('a missing result or id fails the channel', () async {
      final session = await h.connect();
      h.broker.onNewDataChannels = (_, request) async =>
          const DataChannelsResponse(
            dataChannels: [DataChannelResult(dataChannelName: 'noid')],
          );
      final noId = session.publishDataChannel('noid');
      final missing = session.publishDataChannel('missing');
      await expectLater(noId, throwsA(isA<SfuDataChannelException>()));
      await expectLater(
        missing,
        throwsA(
          isA<SfuDataChannelException>().having(
            (e) => e.errorCode,
            'errorCode',
            isNull,
          ),
        ),
      );
    });

    test('a request-level error fails the whole batch', () async {
      final session = await h.connect();
      h.broker.onNewDataChannels = (_, _) async =>
          const DataChannelsResponse(errorCode: 'internal_error');
      final a = session.publishDataChannel('a');
      final b = session.publishDataChannel('b');
      await expectLater(a, throwsA(isA<SfuRequestException>()));
      await expectLater(b, throwsA(isA<SfuRequestException>()));

      // The session still works.
      h.broker.onNewDataChannels = null;
      await session.publishDataChannel('a');
    });

    test('a failed local channel fails it and releases its SFU id', () async {
      final session = await h.connect();
      h.pc.failNext('createDataChannel', StateError('boom'));
      await expectLater(
        session.publishDataChannel('chat'),
        throwsA(isA<StateError>()),
      );
      final close = h.broker.callsTo('datachannels/close').single;
      expect(_json(close), [
        {'id': 1},
      ]);
      expect(session.dataChannels, isEmpty);
    });

    test('a failed publish can be retried with republish', () async {
      final session = await h.connect();
      h.pc.failNext('createDataChannel', StateError('boom'));
      final publishing = session.publishDataChannel('chat');
      // The channel is listed on the session while pending.
      final channel = session.dataChannels.single as LocalDataChannel;
      expect(channel.state, SfuDataChannelState.pending);
      await expectLater(publishing, throwsA(isA<StateError>()));
      expect(channel.state, SfuDataChannelState.failed);
      expect(channel.error, isA<StateError>());
      expect(channel.session, isNull);

      await session.republishDataChannel(channel);
      expect(channel.state, SfuDataChannelState.connecting);
      expect(channel.id, 2);
    });
  });

  group('messages', () {
    test(
      'a subscription attributes messages to the publisher session',
      () async {
        final session = await h.connect();
        final sub = await session.subscribeDataChannel('session-pub', 'input');
        final messages = <DataChannelMessage>[];
        sub.messages.listen(messages.add);

        final dc = h.pc.dataChannels.single;
        dc.receiveText('{"sessionId":"spoofed"}');
        dc.receiveBinary([1, 2, 3]);
        await Future<void>.delayed(Duration.zero);

        expect(messages, hasLength(2));
        expect(messages[0].fromSessionId, 'session-pub');
        expect(messages[0].isBinary, isFalse);
        expect(messages[0].text, '{"sessionId":"spoofed"}');
        expect(messages[0].channel, same(sub));
        expect(messages[0].channelName, 'input');
        expect(messages[1].fromSessionId, 'session-pub');
        expect(messages[1].binary, Uint8List.fromList([1, 2, 3]));
      },
    );

    test('replies on a published channel have no sender session', () async {
      final session = await h.connect();
      final pub = await session.publishDataChannel('input');
      final received = pub.messages.first;
      h.pc.dataChannels.single.receiveText('reply');
      final message = await received;
      expect(message.fromSessionId, isNull);
      expect(message.text, 'reply');
    });

    test('states follow the channel; send works once open', () async {
      final session = await h.connect();
      final pub = await session.publishDataChannel('chat');
      final dc = h.pc.dataChannels.single;

      expect(pub.isOpen, isFalse);
      expect(() => pub.sendText('early'), throwsStateError);

      final opened = pub.whenOpen();
      dc.open();
      await opened;
      expect(pub.state, SfuDataChannelState.open);

      await pub.sendText('hi');
      await pub.send(Uint8List.fromList([9]));
      expect(dc.sent.map((m) => m.isBinary ? m.binary : m.text), [
        'hi',
        [9],
      ]);
    });

    test('a subscriber sends only with canReply', () async {
      final session = await h.connect();
      h.pc.openDataChannelsImmediately = true;
      final listener = await session.subscribeDataChannel('s-a', 'input');
      final replier = await session.subscribeDataChannel(
        's-b',
        'input',
        canReply: true,
      );
      expect(listener.isOpen, isTrue);
      expect(() => listener.sendText('x'), throwsStateError);
      await replier.sendText('ack');
      expect(h.pc.dataChannels[1].sent.single.text, 'ack');
    });

    test('bufferedAmount and the low-water mark', () async {
      final session = await h.connect();
      final pub = await session.publishDataChannel('chat');
      final dc = h.pc.dataChannels.single;
      pub.bufferedAmountLowThreshold = 100;
      expect(dc.threshold, 100);

      final lows = <int>[];
      pub.bufferedAmountLow.listen(lows.add);
      dc.setBufferedAmount(500);
      expect(pub.bufferedAmount, 500);
      dc.setBufferedAmount(80);
      dc.setBufferedAmount(20);
      await Future<void>.delayed(Duration.zero);
      expect(lows, [80]);
      expect(() => pub.bufferedAmountLowThreshold = -1, throwsArgumentError);
    });
  });

  group('canReply updates', () {
    test('setCanReply sends datachannels/update', () async {
      final session = await h.connect();
      final sub = await session.subscribeDataChannel('session-pub', 'input');
      await sub.setCanReply(true);

      expect(_json(h.broker.callsTo('datachannels/update').single), [
        {
          'location': 'remote',
          'dataChannelName': 'input',
          'sessionId': 'session-pub',
          'canReply': true,
        },
      ]);
      expect(sub.canReply, isTrue);
    });

    test('a rejected update leaves canReply unchanged', () async {
      final session = await h.connect();
      final sub = await session.subscribeDataChannel('session-pub', 'input');
      h.broker.onUpdateDataChannels = (_, _) async =>
          const DataChannelsResponse(
            dataChannels: [
              DataChannelResult(
                dataChannelName: 'input',
                errorCode: 'not_found',
              ),
            ],
          );
      await expectLater(
        sub.setCanReply(true),
        throwsA(isA<SfuDataChannelException>()),
      );
      expect(sub.canReply, isFalse);
    });
  });

  group('close', () {
    test('closes locally and sends datachannels/close by id', () async {
      final session = await h.connect();
      final pub = await session.publishDataChannel('chat');
      final done = expectLater(pub.messages, emitsDone);

      await pub.close();

      expect(pub.state, SfuDataChannelState.closed);
      expect(h.pc.dataChannels.single.closed, isTrue);
      expect(_json(h.broker.callsTo('datachannels/close').single), [
        {'id': 1},
      ]);
      expect(session.dataChannels, isEmpty);
      await done;
      expect(() => session.republishDataChannel(pub), throwsStateError);
    });

    test('closes of one turn share a request', () async {
      final session = await h.connect();
      final a = await session.publishDataChannel('a');
      final b = await session.subscribeDataChannel('s', 'b');
      await Future.wait([a.close(), b.close()]);
      expect(_json(h.broker.callsTo('datachannels/close').single), [
        {'id': 1},
        {'id': 2},
      ]);
    });

    test('closing while pending releases the SFU id afterwards', () async {
      final session = await h.connect();
      final publishing = session.publishDataChannel('chat');
      final channel = session.dataChannels.single;
      await channel.close();
      await expectLater(publishing, throwsA(isA<SfuSessionException>()));
      expect(channel.state, SfuDataChannelState.closed);
      expect(h.broker.callsTo('datachannels/new'), isEmpty);
    });

    test('closing during the request releases the SFU id', () async {
      final session = await h.connect();
      final response = Completer<DataChannelsResponse>();
      h.broker.onNewDataChannels = (_, _) => response.future;
      final publishing = session.publishDataChannel('chat');
      final channel = session.dataChannels.single;
      while (h.broker.callsTo('datachannels/new').isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      await channel.close();
      response.complete(
        const DataChannelsResponse(
          dataChannels: [DataChannelResult(dataChannelName: 'chat', id: 6)],
        ),
      );
      await expectLater(publishing, throwsA(isA<SfuSessionException>()));
      expect(_json(h.broker.callsTo('datachannels/close').single), [
        {'id': 6},
      ]);
      expect(h.pc.dataChannels, isEmpty);
    });

    test('a channel closed by the other end is interrupted', () async {
      final session = await h.connect();
      final sub = await session.subscribeDataChannel('session-pub', 'input');
      h.pc.dataChannels.single.remoteClose();
      expect(sub.state, SfuDataChannelState.interrupted);
      expect(sub.session, isNull);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(h.broker.callsTo('datachannels/close'), hasLength(1));

      // It can be subscribed again.
      await session.resubscribeDataChannel(sub);
      expect(sub.state, SfuDataChannelState.connecting);
    });
  });

  group('session failure and moving channels', () {
    test('a failed session interrupts channels; republish restores', () async {
      final first = await h.connect();
      final pub = await first.publishDataChannel('chat');
      final sub = await first.subscribeDataChannel('session-old', 'input');
      final firstPc = h.pc;
      final messages = <DataChannelMessage>[];
      sub.messages.listen(messages.add);

      firstPc.emitConnectionState(
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
      );
      expect(pub.state, SfuDataChannelState.interrupted);
      expect(sub.state, SfuDataChannelState.interrupted);
      expect(pub.error, isA<SfuSessionFailedException>());
      expect(firstPc.dataChannels.every((d) => d.closed), isTrue);
      expect(first.dataChannels, isEmpty);
      expect(
        () => first.publishDataChannel('x'),
        throwsA(isA<SfuSessionFailedException>()),
      );

      final second = await h.connect();
      await second.republishDataChannel(pub);
      await second.resubscribeDataChannel(sub, remoteSessionId: 'session-new');

      expect(pub.session, same(second));
      expect(pub.sessionId, second.sessionId);
      expect(sub.remoteSessionId, 'session-new');
      expect(
        h.broker
            .callsTo('datachannels/establish')
            .map((c) => c.sessionId)
            .toList(),
        [first.sessionId, second.sessionId],
      );
      expect(_json(h.broker.callsTo('datachannels/new').last), [
        {
          'location': 'remote',
          'dataChannelName': 'input',
          'sessionId': 'session-new',
          'ordered': true,
        },
      ]);

      h.pc.dataChannels.last.receiveText('hello');
      await Future<void>.delayed(Duration.zero);
      expect(messages.single.fromSessionId, 'session-new');
    });

    test('session.close interrupts channels without SFU calls', () async {
      final session = await h.connect();
      final pub = await session.publishDataChannel('chat');
      await session.close();
      expect(pub.state, SfuDataChannelState.interrupted);
      expect(pub.error, isA<SfuSessionClosedException>());

      await pub.close();
      expect(pub.state, SfuDataChannelState.closed);
      expect(h.broker.callsTo('datachannels/close'), isEmpty);
    });

    test('a gone session fails the operation and the session', () async {
      final session = await h.connect();
      h.broker.onNewDataChannels = (_, _) async =>
          throw const SessionGoneException(
            operation: 'datachannels/new',
            statusCode: 410,
            errorCode: 'session_error',
          );
      await expectLater(
        session.publishDataChannel('chat'),
        throwsA(isA<SessionGoneException>()),
      );
      expect(session.failure, isA<SfuSessionGone>());
    });

    test(
      'republish and resubscribe refuse channels still on a session',
      () async {
        final session = await h.connect();
        final pub = await session.publishDataChannel('chat');
        final sub = await session.subscribeDataChannel('s', 'input');
        expect(() => session.republishDataChannel(pub), throwsStateError);
        expect(() => session.resubscribeDataChannel(sub), throwsStateError);
      },
    );
  });
}
