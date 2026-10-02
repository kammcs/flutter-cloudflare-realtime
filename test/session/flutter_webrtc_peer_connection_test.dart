import 'dart:async';

import 'package:cloudflare_realtime/src/session/flutter_webrtc_peer_connection.dart';
import 'package:cloudflare_realtime/src/broker/models/common.dart' show SdpType;
import 'package:cloudflare_realtime/src/session/peer_connection.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// A `flutter_webrtc` peer connection with no native side. Calls are logged.
class _FakeRtcPeerConnection extends Fake implements webrtc.RTCPeerConnection {
  final List<String> log = [];
  final List<Map<String, dynamic>?> offerConstraints = [];
  final List<Map<String, dynamic>?> answerConstraints = [];
  final List<_FakeRtcDataChannel> created = [];
  List<webrtc.StatsReport> stats = [];
  int statsCalls = 0;

  @override
  Function(webrtc.RTCPeerConnectionState state)? onConnectionState;
  @override
  Function(webrtc.RTCIceConnectionState state)? onIceConnectionState;
  @override
  Function(webrtc.RTCDataChannel channel)? onDataChannel;
  @override
  Function(webrtc.RTCTrackEvent event)? onTrack;

  @override
  Future<webrtc.RTCSessionDescription> createOffer([
    Map<String, dynamic>? constraints,
  ]) async {
    offerConstraints.add(constraints);
    return webrtc.RTCSessionDescription('o', 'offer');
  }

  @override
  Future<webrtc.RTCSessionDescription> createAnswer([
    Map<String, dynamic>? constraints,
  ]) async {
    answerConstraints.add(constraints);
    return webrtc.RTCSessionDescription('a', 'answer');
  }

  @override
  Future<webrtc.RTCDataChannel> createDataChannel(
    String label,
    webrtc.RTCDataChannelInit init,
  ) async {
    final channel = _FakeRtcDataChannel(label, log);
    created.add(channel);
    return channel;
  }

  @override
  Future<List<webrtc.StatsReport>> getStats([
    webrtc.MediaStreamTrack? track,
  ]) async {
    statsCalls++;
    return stats;
  }

  /// What `getTransceivers()` returns next.
  List<webrtc.RTCRtpTransceiver> current = [];

  /// What `addTransceiver()` returns next.
  webrtc.RTCRtpTransceiver? nextTransceiver;

  @override
  Future<webrtc.RTCRtpTransceiver> addTransceiver({
    webrtc.MediaStreamTrack? track,
    webrtc.RTCRtpMediaType? kind,
    webrtc.RTCRtpTransceiverInit? init,
  }) async => nextTransceiver!;

  @override
  Future<List<webrtc.RTCRtpTransceiver>> getTransceivers() async => current;

  /// What `getLocalDescription()` returns; throws [localDescriptionError]
  /// instead when set.
  webrtc.RTCSessionDescription? local;
  Object? localDescriptionError;

  @override
  Future<webrtc.RTCSessionDescription?> getLocalDescription() async {
    final error = localDescriptionError;
    if (error != null) throw error;
    return local;
  }

  @override
  Future<void> close() async => log.add('pc.close');

  @override
  Future<void> dispose() async => log.add('pc.dispose');
}

/// A native transceiver as one `flutter_webrtc` call reported it.
class _FakeTransceiver extends Fake implements webrtc.RTCRtpTransceiver {
  _FakeTransceiver(this.transceiverId, this.mid, String senderId, this._log)
    : sender = _FakeSender(senderId);

  @override
  final String transceiverId;

  @override
  final String mid;

  @override
  final webrtc.RTCRtpSender sender;

  final List<String> _log;

  @override
  Future<void> stop() async => _log.add('stop($transceiverId)');
}

class _FakeSender extends Fake implements webrtc.RTCRtpSender {
  _FakeSender(this.senderId);

  @override
  final String senderId;
}

class _FakeRtcDataChannel extends webrtc.RTCDataChannel {
  _FakeRtcDataChannel(this.label, this._log) {
    stateChangeStream = _states.stream;
    messageStream = _messages.stream;
  }

  final List<String> _log;
  final _states = StreamController<webrtc.RTCDataChannelState>.broadcast(
    sync: true,
  );
  final _messages = StreamController<webrtc.RTCDataChannelMessage>.broadcast(
    sync: true,
  );

  @override
  webrtc.RTCDataChannelState? state;

  @override
  final String label;

  @override
  int? get id => null;

  @override
  int? get bufferedAmount => 0;

  void emit(webrtc.RTCDataChannelState next) {
    state = next;
    _states.add(next);
  }

  @override
  Future<void> send(webrtc.RTCDataChannelMessage message) async {}

  @override
  Future<void> close() async => _log.add('dc.close($label)');
}

webrtc.StatsReport _dataChannelReport(int id, String state) =>
    webrtc.StatsReport('D$id', 'data-channel', 0, {
      'dataChannelIdentifier': id,
      'label': 'x',
      'state': state,
    });

const _open = webrtc.RTCDataChannelState.RTCDataChannelOpen;

void main() {
  late _FakeRtcPeerConnection rtc;
  late FlutterWebrtcPeerConnection pc;

  setUp(() {
    rtc = _FakeRtcPeerConnection();
    pc = FlutterWebrtcPeerConnection(rtc);
  });

  test('offers and answers with empty constraints, so native '
      'flutter_webrtc adds no receive-only transceivers', () async {
    await pc.createOffer();
    await pc.createAnswer();
    expect(rtc.offerConstraints, [<String, dynamic>{}]);
    expect(rtc.answerConstraints, [<String, dynamic>{}]);
  });

  group('localDescription', () {
    test('is the platform\'s description', () async {
      rtc.local = webrtc.RTCSessionDescription('v=0', 'offer');
      final d = await pc.localDescription();
      expect(d!.type, SdpType.offer);
      expect(d.sdp, 'v=0');
    });

    test('is null while there is none, including when the platform throws '
        'for it (Android)', () async {
      expect(await pc.localDescription(), isNull);
      rtc.local = webrtc.RTCSessionDescription('', 'offer');
      expect(await pc.localDescription(), isNull);
      rtc.localDescriptionError = PlatformException(
        code: 'getLocalDescriptionFailed',
        message:
            "Attempt to read from field 'java.lang.String "
            "org.webrtc.SessionDescription.description' on a null object "
            'reference',
      );
      expect(await pc.localDescription(), isNull);
    });
  });

  test('close() closes DataChannels before the connection', () async {
    await pc.createDataChannel('chat', id: 2);
    final serverEvents = _FakeRtcDataChannel('server-events', rtc.log);
    rtc.onDataChannel!(serverEvents);

    await pc.close();

    expect(rtc.log, [
      'dc.close(chat)',
      'dc.close(server-events)',
      'pc.close',
      'pc.dispose',
    ]);
  });

  group('a negotiated DataChannel whose open event is missed', () {
    test('opens once the stats report it open', () {
      fakeAsync((async) {
        late _StateLog view;
        pc.createDataChannel('chat', id: 3).then((c) {
          view = _StateLog(c);
        });
        async.flushMicrotasks();
        expect(view.channel.state, isNull);

        async.elapse(const Duration(milliseconds: 100));
        expect(view.channel.state, isNull);
        expect(rtc.statsCalls, greaterThan(0));

        rtc.stats = [
          _dataChannelReport(1, 'open'),
          _dataChannelReport(3, 'open'),
        ];
        async.elapse(const Duration(seconds: 1));
        expect(view.channel.state, _open);
        expect(view.states, [_open]);

        final calls = rtc.statsCalls;
        async.elapse(const Duration(seconds: 5));
        expect(rtc.statsCalls, calls, reason: 'probing stops once open');
      });
    });

    test('ignores other channels and other states', () {
      fakeAsync((async) {
        late _StateLog view;
        pc.createDataChannel('chat', id: 3).then((c) {
          view = _StateLog(c);
        });
        rtc.stats = [
          _dataChannelReport(1, 'open'),
          _dataChannelReport(3, 'connecting'),
        ];
        async.elapse(const Duration(seconds: 5));
        expect(view.channel.state, isNull);
        expect(view.states, isEmpty);
      });
    });

    test('a platform state event wins and stops probing', () {
      fakeAsync((async) {
        late _StateLog view;
        pc.createDataChannel('chat', id: 3).then((c) {
          view = _StateLog(c);
        });
        async.flushMicrotasks();
        rtc.created.single.emit(_open);
        async.flushMicrotasks();
        expect(view.channel.state, _open);

        final calls = rtc.statsCalls;
        rtc.stats = [_dataChannelReport(3, 'open')];
        async.elapse(const Duration(seconds: 5));
        expect(rtc.statsCalls, calls);
        expect(view.states, [_open], reason: 'open is reported once');
      });
    });

    test('probing stops when the channel closes', () {
      fakeAsync((async) {
        late _StateLog view;
        pc.createDataChannel('chat', id: 3).then((c) {
          view = _StateLog(c);
        });
        async.flushMicrotasks();
        view.channel.close();
        async.flushMicrotasks();
        final calls = rtc.statsCalls;
        rtc.stats = [_dataChannelReport(3, 'open')];
        async.elapse(const Duration(seconds: 5));
        expect(rtc.statsCalls, calls);
        expect(view.states, isEmpty);
      });
    });
  });

  group('a send transceiver', () {
    test('finds its mid after negotiation when Android replaces its '
        'transceiverId with the mid', () async {
      rtc.nextTransceiver = _FakeTransceiver('uuid-1', '', 'sender-a', rtc.log);
      final t = await pc.addSendTransceiver(kind: 'video');
      rtc.current = [
        _FakeTransceiver('0', '0', 'sender-z', rtc.log),
        _FakeTransceiver('1', '1', 'sender-a', rtc.log),
      ];
      expect(await t.mid(), '1');

      await t.stop();
      expect(rtc.log, ['stop(1)'], reason: 'stops the current entry');
    });

    test('finds its mid on Darwin, where the transceiverId is the mid '
        '(empty before negotiation)', () async {
      rtc.nextTransceiver = _FakeTransceiver('', '', 'sender-a', rtc.log);
      final t = await pc.addSendTransceiver(kind: 'audio');
      rtc.current = [
        _FakeTransceiver('', '', 'sender-b', rtc.log),
        _FakeTransceiver('2', '2', 'sender-a', rtc.log),
      ];
      expect(await t.mid(), '2');
    });

    test('has no mid before negotiation, or once it is gone', () async {
      rtc.nextTransceiver = _FakeTransceiver('t1', '', 'sender-a', rtc.log);
      final t = await pc.addSendTransceiver(kind: 'video');
      rtc.current = [_FakeTransceiver('t1', '', 'sender-a', rtc.log)];
      expect(await t.mid(), isNull);
      rtc.current = [_FakeTransceiver('t2', '0', 'sender-b', rtc.log)];
      expect(await t.mid(), isNull);
    });

    test('falls back to the transceiverId without a sender ID', () async {
      rtc.nextTransceiver = _FakeTransceiver('t1', '', '', rtc.log);
      final t = await pc.addSendTransceiver(kind: 'video');
      rtc.current = [
        _FakeTransceiver('t0', '0', '', rtc.log),
        _FakeTransceiver('t1', '1', '', rtc.log),
      ];
      expect(await t.mid(), '1');
    });
  });

  group('platformConfiguration', () {
    final servers = [
      for (var i = 0; i < 9; i++) <String, dynamic>{'urls': 'turn:t:$i'},
    ];
    final config = <String, dynamic>{
      'iceServers': servers,
      'bundlePolicy': 'max-bundle',
    };

    test('limits ICE servers on Windows and Linux', () {
      for (final platform in [TargetPlatform.windows, TargetPlatform.linux]) {
        final adjusted = platformConfiguration(
          config,
          platform: platform,
          isWeb: false,
        );
        expect(adjusted['iceServers'], hasLength(maxDesktopIceServers));
        expect(adjusted['bundlePolicy'], 'max-bundle');
      }
    });

    test('leaves Android, iOS, macOS and the web alone', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.macOS,
      ]) {
        expect(
          platformConfiguration(config, platform: platform, isWeb: false),
          same(config),
        );
      }
      expect(
        platformConfiguration(
          config,
          platform: TargetPlatform.windows,
          isWeb: true,
        ),
        same(config),
      );
    });
  });

  group('limitIceServers', () {
    Map<String, dynamic> server(String url) => {
      'urls': url,
      'username': 'u',
      'credential': 'c',
    };

    test('keeps a list within the limit unchanged', () {
      final servers = [for (var i = 0; i < 8; i++) server('turn:t:$i')];
      expect(limitIceServers(servers, 8), same(servers));
    });

    test('drops port 53 and duplicates first, then the tail', () {
      final servers = [
        {'urls': 'stun:stun.cloudflare.com:3478'},
        {'urls': 'stun:stun.cloudflare.com:53'},
        server('turn:turn.cloudflare.com:3478?transport=udp'),
        server('turn:turn.cloudflare.com:53?transport=udp'),
        server('turn:turn.cloudflare.com:3478?transport=tcp'),
        server('turn:turn.cloudflare.com:3478?transport=tcp'),
        server('turn:turn.cloudflare.com:80?transport=tcp'),
        server('turns:turn.cloudflare.com:5349?transport=tcp'),
        server('turns:turn.cloudflare.com:443?transport=tcp'),
        server('turn:turn.cloudflare.com:443?transport=udp'),
      ];
      expect(limitIceServers(servers, 8).map((s) => s['urls']), [
        'stun:stun.cloudflare.com:3478',
        'turn:turn.cloudflare.com:3478?transport=udp',
        'turn:turn.cloudflare.com:3478?transport=tcp',
        'turn:turn.cloudflare.com:80?transport=tcp',
        'turns:turn.cloudflare.com:5349?transport=tcp',
        'turns:turn.cloudflare.com:443?transport=tcp',
        'turn:turn.cloudflare.com:443?transport=udp',
      ]);
      expect(limitIceServers(servers, 3).map((s) => s['urls']), hasLength(3));
    });
  });
}

/// Records the states a [PeerDataChannel] reports.
class _StateLog {
  _StateLog(this.channel) {
    channel.onStateChange.listen(states.add);
  }

  final PeerDataChannel channel;
  final List<webrtc.RTCDataChannelState> states = [];
}
