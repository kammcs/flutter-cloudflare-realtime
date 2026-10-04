// Bounded negotiation steps (docs/design.md §4.2): a peer-connection step
// that never completes fails the session instead of hanging its queue.

import 'dart:async';

import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/src/session/negotiation_guard.dart';
import 'package:cloudflare_realtime/src/session/sfu_session.dart';
import 'package:cloudflare_realtime/src/util/native_negotiation.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/session_harness.dart';

const _timeout = Duration(seconds: 60);

/// Counts its SDP calls in [NativeNegotiation], as the flutter_webrtc
/// peer connection does.
class _CountedPeerConnection extends FakePeerConnection {
  @override
  Future<SessionDescription> createOffer() =>
      NativeNegotiation.run(super.createOffer);
}

Matcher _timedOutFailure() => isA<SfuSessionFailedException>().having(
  (e) => e.failure,
  'failure',
  isA<SfuPeerConnectionFailed>().having(
    (f) => f.kind,
    'kind',
    PeerConnectionFailureKind.negotiationTimeout,
  ),
);

void main() {
  late SessionHarness h;

  setUp(() => h = SessionHarness());

  test('the default is 60 s', () {
    expect(const SfuSessionOptions().negotiationTimeout, _timeout);
  });

  for (final step in ['addTransceiver', 'createOffer', 'setLocalDescription']) {
    test('a push whose $step never completes fails the session after the '
        'timeout, before tracks/new', () {
      fakeAsync((async) {
        late SfuSession session;
        h.connect().then((s) => session = s);
        async.flushMicrotasks();
        final failures = <SfuSessionFailure>[];
        session.failures.listen(failures.add);
        final late = h.pc.hangNext(step);

        Object? error;
        var done = false;
        session
            .publish(FakeMediaStreamTrack(kind: 'audio'))
            .then(
              (_) {
                done = true;
              },
              onError: (Object e) {
                error = e;
              },
            );
        // A pull queued behind it must not hang either.
        Object? pullError;
        session
            .subscribe(remoteSessionId: 'p', trackName: 't')
            .then(
              (_) {},
              onError: (Object e) {
                pullError = e;
              },
            );

        async.elapse(_timeout - const Duration(milliseconds: 1));
        expect(done, isFalse);
        expect(error, isNull);

        async.elapse(const Duration(milliseconds: 1));
        expect(done, isFalse);
        expect(error, _timedOutFailure());
        expect(pullError, isA<SfuSessionFailedException>());
        expect(failures.single, isA<SfuPeerConnectionFailed>());
        expect(session.connectionState, SfuConnectionState.failed);
        expect(h.broker.callsTo('tracks/new'), isEmpty);

        // The step completing late changes nothing and throws nothing.
        late.complete();
        async.flushMicrotasks();
        expect(h.broker.callsTo('tracks/new'), isEmpty);
        expect(failures, hasLength(1));
      });
    });
  }

  test('a step that completes within the timeout is unaffected', () {
    fakeAsync((async) {
      late SfuSession session;
      h.connect().then((s) => session = s);
      async.flushMicrotasks();
      final slow = h.pc.hangNext('setLocalDescription');
      LocalTrackPublication? published;
      session
          .publish(FakeMediaStreamTrack(kind: 'audio'))
          .then((p) => published = p);
      async.elapse(const Duration(seconds: 59));
      slow.complete();
      async.flushMicrotasks();
      expect(published?.state, SfuTrackState.active);
      expect(session.failure, isNull);
      // No guard timer is left behind.
      async.elapse(const Duration(minutes: 1));
      expect(session.failure, isNull);
    });
  });

  test('the timeout is configurable, and null waits', () {
    fakeAsync((async) {
      late SfuSession quick;
      h
          .connect(
            options: const SfuSessionOptions(
              negotiationTimeout: Duration(seconds: 2),
            ),
          )
          .then((s) => quick = s);
      async.flushMicrotasks();
      h.pc.hangNext('createOffer');
      Object? error;
      quick
          .publish(FakeMediaStreamTrack(kind: 'audio'))
          .then(
            (_) {},
            onError: (Object e) {
              error = e;
            },
          );
      async.elapse(const Duration(seconds: 2));
      expect(error, _timedOutFailure());

      late SfuSession patient;
      h
          .connect(options: const SfuSessionOptions(negotiationTimeout: null))
          .then((s) => patient = s);
      async.flushMicrotasks();
      final hang = h.pc.hangNext('createOffer');
      LocalTrackPublication? published;
      patient
          .publish(FakeMediaStreamTrack(kind: 'audio'))
          .then((p) => published = p);
      async.elapse(const Duration(minutes: 5));
      expect(published, isNull);
      expect(patient.failure, isNull);
      hang.complete();
      async.flushMicrotasks();
      expect(published?.state, SfuTrackState.active);
    });
  });

  test('a stuck SFU-offer exchange (establishConnection) fails the session '
      'too', () {
    fakeAsync((async) {
      late SfuSession session;
      h.connect().then((s) => session = s);
      async.flushMicrotasks();
      h.pc.hangNext('setRemoteDescription');
      Object? error;
      session.establishConnection().then(
        (_) {},
        onError: (Object e) {
          error = e;
        },
      );
      async.elapse(_timeout);
      expect(error, _timedOutFailure());
      expect(session.isUsable, isFalse);
    });
  });

  test('connect fails when the peer connection is not created in time, '
      'and closes one created late', () {
    fakeAsync((async) {
      final hang = h.peerConnections.hangNextCreate = Completer<void>();
      Object? error;
      h.connect().then(
        (_) {},
        onError: (Object e) {
          error = e;
        },
      );
      async.elapse(_timeout);
      expect(error, _timedOutFailure());
      expect(h.broker.forgotten, hasLength(1));

      hang.complete();
      async.flushMicrotasks();
      expect(h.pc.closed, isTrue);
    });
  });

  test('close() does not wait on a peer connection that never closes', () {
    fakeAsync((async) {
      late SfuSession session;
      h.connect().then((s) => session = s);
      async.flushMicrotasks();
      h.pc.hangNext('close');
      var closed = false;
      session.close().then((_) => closed = true);
      async.elapse(_timeout);
      expect(closed, isTrue);
      expect(session.connectionState, SfuConnectionState.closed);
    });
  });

  group('NegotiationGuard', () {
    test('closes a DataChannel created after the timeout', () {
      fakeAsync((async) {
        final pc = FakePeerConnection();
        final steps = <String>[];
        final guard = NegotiationGuard(pc, timeout: _timeout)
          ..onTimeout = (step) {
            steps.add(step);
            return StateError('timed out: $step');
          };
        final hang = pc.hangNext('createDataChannel');
        Object? error;
        guard
            .createDataChannel('chat', id: 3)
            .then(
              (_) {},
              onError: (Object e) {
                error = e;
              },
            );
        async.elapse(_timeout);
        expect(error, isA<StateError>());
        expect(steps, ['createDataChannel']);

        hang.complete();
        async.flushMicrotasks();
        expect(pc.dataChannels.single.closed, isTrue);
      });
    });

    test('throws a TimeoutException without onTimeout', () {
      fakeAsync((async) {
        final pc = FakePeerConnection();
        final guard = NegotiationGuard(pc, timeout: _timeout);
        pc.hangNext('createOffer');
        Object? error;
        guard.createOffer().then(
          (_) {},
          onError: (Object e) {
            error = e;
          },
        );
        async.elapse(_timeout);
        expect(error, isA<TimeoutException>());
      });
    });

    test('a step that timed out no longer holds back whenIdle (getStats, '
        'the macOS microphone selection); its late end counts nothing', () {
      fakeAsync((async) {
        final pc = _CountedPeerConnection();
        final guard = NegotiationGuard(pc, timeout: _timeout);
        final hang = pc.hangNext('createOffer');
        guard.createOffer().then((_) {}, onError: (Object _) {});
        async.flushMicrotasks();
        expect(NativeNegotiation.isRunning, isTrue);
        var idle = false;
        NativeNegotiation.whenIdle().then((_) => idle = true);

        async.elapse(_timeout - const Duration(milliseconds: 1));
        expect(idle, isFalse, reason: 'still within the bound');
        async.elapse(const Duration(milliseconds: 1));
        expect(idle, isTrue);
        expect(NativeNegotiation.isRunning, isFalse);

        hang.complete();
        async.flushMicrotasks();
        expect(NativeNegotiation.isRunning, isFalse);

        // A step that completes in time is counted while it runs.
        final slow = pc.hangNext('createOffer');
        SessionDescription? offer;
        guard.createOffer().then((o) => offer = o);
        async.flushMicrotasks();
        expect(NativeNegotiation.isRunning, isTrue);
        slow.complete();
        async.flushMicrotasks();
        expect(offer, isNotNull);
        expect(NativeNegotiation.isRunning, isFalse);
      });
    });
  });
}
