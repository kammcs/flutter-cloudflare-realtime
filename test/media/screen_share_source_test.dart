import 'dart:async';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fakes.dart';

const screen1 = ScreenSource(
  id: 'screen-1',
  name: 'Screen 1',
  type: ScreenSourceType.screen,
);
const window1 = ScreenSource(
  id: 'window-1',
  name: 'Editor',
  type: ScreenSourceType.window,
);

void main() {
  late FakeDesktopCapturer desktop;
  late FakeMediaBackend backend;

  setUp(() {
    desktop = FakeDesktopCapturer([screen1, window1]);
    backend = FakeMediaBackend(desktop: desktop);
  });

  tearDown(() => backend.close());

  FakeTrack videoOf(ScreenShareSource share) => share.track!.track as FakeTrack;

  group('desktop', () {
    test(
      'captures the chosen source by id with a mandatory frame rate',
      () async {
        final share = ScreenShareSource(backend: backend);
        expect(share.isSupported, isTrue);
        expect(share.usesBrowserPicker, isFalse);
        expect(share.usesSystemPicker, isFalse);

        expect(
          await share.start(
            source: window1,
            options: const ScreenShareOptions(frameRate: 15),
          ),
          isTrue,
        );
        expect(backend.displayMediaCalls.single, {
          'audio': false,
          'video': {
            'deviceId': {'exact': 'window-1'},
            'mandatory': {'frameRate': 15.0},
          },
        });
        expect(share.selectedSource, window1);
        expect(share.track!.track.kind, 'video');
        expect(share.track!.device, isNull);
        expect(share.audioTrack, isNull);
        await share.dispose();
      },
    );

    test('requires a source', () async {
      final share = ScreenShareSource(backend: backend);
      expect(() => share.start(), throwsArgumentError);
      expect(() => share.enable(), throwsArgumentError);
      await share.dispose();
    });

    test('captures system audio when asked', () async {
      final share = ScreenShareSource(
        backend: backend,
        options: const ScreenShareOptions(captureAudio: true),
      );
      await share.start(source: screen1);
      expect(backend.displayMediaCalls.single['audio'], isTrue);
      expect(share.audioTrack!.track.kind, 'audio');
      expect(share.broadcastAudioTrack, isNull);

      await share.startBroadcasting();
      expect(share.broadcastTrack, share.track);
      expect(share.broadcastAudioTrack, share.audioTrack);

      final audio = share.audioTrack!.track as FakeTrack;
      await share.stop();
      expect(audio.stopped, isTrue);
      expect(share.audioTrack, isNull);
      expect(share.broadcastAudioTrack, isNull);
      await share.dispose();
    });

    test('ends with sourceClosed when the shared window goes away', () async {
      final share = ScreenShareSource(backend: backend);
      final reasons = <ScreenShareEndReason>[];
      share.ended.listen(reasons.add);
      await share.start(source: window1);
      await share.startBroadcasting();
      final video = videoOf(share);

      desktop.removed.add(screen1); // Another source: ignored.
      await pumpEventQueue();
      expect(share.isEnabled, isTrue);

      desktop.removed.add(window1);
      await pumpEventQueue();
      expect(reasons, [ScreenShareEndReason.sourceClosed]);
      expect(share.isEnabled, isFalse);
      expect(share.isBroadcasting, isFalse);
      expect(share.track, isNull);
      expect(video.stopped, isTrue);
      await share.dispose();
      expect(reasons, hasLength(1));
    });

    test('re-scans sources while sharing, so removals are reported', () {
      fakeAsync((async) {
        final share = ScreenShareSource(
          backend: backend,
          sourceWatchInterval: const Duration(seconds: 2),
        );
        share.start(source: screen1);
        async.flushMicrotasks();
        expect(desktop.updateSourcesCalls, 0);

        async.elapse(const Duration(seconds: 5));
        expect(desktop.updateSourcesCalls, 2);

        share.stop();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 10));
        expect(desktop.updateSourcesCalls, 2);
        share.dispose();
        async.flushMicrotasks();
      });
    });

    test('stop ends with the stopped reason', () async {
      final share = ScreenShareSource(backend: backend);
      final reasons = <ScreenShareEndReason>[];
      share.ended.listen(reasons.add);
      await share.start(source: screen1);
      final video = videoOf(share);

      await share.stop();
      await pumpEventQueue();
      expect(reasons, [ScreenShareEndReason.stopped]);
      expect(video.stopped, isTrue);

      // Stopping again reports nothing new.
      await share.stop();
      await pumpEventQueue();
      expect(reasons, hasLength(1));
      await share.dispose();
    });

    test('muting with releaseCapture ends the share', () async {
      final share = ScreenShareSource(backend: backend);
      await share.select(screen1);
      await share.startBroadcasting();
      expect(share.broadcastTrack, isNotNull);
      await share.stopBroadcasting();
      expect(share.isEnabled, isFalse);
      expect(share.track, isNull);
      await share.dispose();
    });

    test('switching sources releases the old capture first', () async {
      final share = ScreenShareSource(backend: backend);
      final reasons = <ScreenShareEndReason>[];
      share.ended.listen(reasons.add);
      await share.start(source: screen1);
      final first = videoOf(share);

      var firstStoppedBeforeSecondCapture = false;
      backend.onDisplayMedia = (constraints) async {
        firstStoppedBeforeSecondCapture = first.stopped;
        return FakeStream([FakeTrack(kind: 'video')]);
      };
      await share.start(source: window1);

      expect(firstStoppedBeforeSecondCapture, isTrue);
      expect(share.track!.track, isNot(first));
      expect((backend.displayMediaCalls.last['video'] as Map)['deviceId'], {
        'exact': 'window-1',
      });
      await pumpEventQueue();
      expect(reasons, isEmpty); // A switch is not an end.
      await share.dispose();
    });

    test('recovers from "source not found" by re-listing (#1085)', () async {
      final share = ScreenShareSource(backend: backend);
      var calls = 0;
      backend.onDisplayMedia = (constraints) async {
        if (calls++ == 0) throw 'Unable to getDisplayMedia: source not found!';
        return FakeStream([FakeTrack(kind: 'video')]);
      };
      expect(await share.start(source: window1), isTrue);
      expect(desktop.getSourcesCalls, 1);
      expect(desktop.requestedTypes.single, {
        ScreenSourceType.screen,
        ScreenSourceType.window,
      });
      await share.dispose();
    });

    test('recovers from the macOS "No source found" answer too', () async {
      // macOS answers {error: ...} instead of throwing, which flutter_webrtc
      // 1.6 reads as a null streamId: a TypeError.
      backend.platform = MediaPlatform.macos;
      final share = ScreenShareSource(backend: backend);
      final Map<String, dynamic> answer = {
        'error': 'No source found for id: window-1',
      };
      var calls = 0;
      backend.onDisplayMedia = (constraints) async {
        if (calls++ == 0) {
          final String streamId = answer['streamId'];
          throw StateError('unreachable: $streamId');
        }
        return FakeStream([FakeTrack(kind: 'video')]);
      };
      expect(await share.start(source: window1), isTrue);
      expect(desktop.getSourcesCalls, 1);
      await share.dispose();

      // Elsewhere a TypeError is just a failure.
      backend.platform = MediaPlatform.windows;
      final other = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      other.errors.listen(errors.add);
      calls = 0;
      expect(await other.start(source: window1), isFalse);
      await pumpEventQueue();
      expect(errors.single, isA<MediaCaptureException>());
      expect(desktop.getSourcesCalls, 1);
      await other.dispose();
    });

    test(
      'reports ScreenSourceNotFoundException if the source is gone',
      () async {
        final share = ScreenShareSource(backend: backend);
        final errors = <MediaException>[];
        share.errors.listen(errors.add);
        backend.onDisplayMedia = (constraints) async =>
            throw 'Unable to getDisplayMedia: source not found!';

        expect(await share.start(source: window1), isFalse);
        await pumpEventQueue();
        final error = errors.single as ScreenSourceNotFoundException;
        expect(error.sourceId, 'window-1');
        expect(share.isEnabled, isFalse);
        expect(backend.displayMediaCalls, hasLength(2));
        await share.dispose();
      },
    );

    test('other capture failures are reported, not thrown', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      backend.onDisplayMedia = (constraints) async =>
          throw 'Unable to getDisplayMedia: CreateDesktopCapturer failed!';

      expect(await share.start(source: screen1), isFalse);
      await pumpEventQueue();
      expect(errors.single, isA<MediaCaptureException>());
      await share.dispose();
    });
  });

  group('web', () {
    setUp(() {
      backend = FakeMediaBackend(platform: MediaPlatform.web);
    });

    test('uses the browser picker', () async {
      final share = ScreenShareSource(backend: backend);
      expect(share.usesBrowserPicker, isTrue);
      expect(share.usesSystemPicker, isTrue);
      expect(() => share.start(source: screen1), throwsArgumentError);
      expect(() => share.select(screen1), throwsUnsupportedError);

      expect(await share.start(), isTrue);
      expect(backend.displayMediaCalls.single, {
        'audio': false,
        'video': {
          'frameRate': {'ideal': 15},
        },
      });
      await share.dispose();
    });

    test('the browser "Stop sharing" button ends with userStopped', () async {
      final share = ScreenShareSource(backend: backend);
      final reasons = <ScreenShareEndReason>[];
      share.ended.listen(reasons.add);
      await share.startBroadcasting();
      final video = videoOf(share);

      video.endExternally();
      await pumpEventQueue();
      expect(reasons, [ScreenShareEndReason.userStopped]);
      expect(share.isEnabled, isFalse);
      expect(share.broadcastTrack, isNull);
      expect(video.stopped, isTrue);
      await share.dispose();
    });

    test('cancelling the picker is not an error', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      backend.onDisplayMedia = (constraints) async =>
          throw 'Unable to getDisplayMedia: NotAllowedError: Permission denied';

      expect(await share.start(), isFalse);
      await pumpEventQueue();
      expect(errors, isEmpty);
      expect(share.isEnabled, isFalse);
      await share.dispose();
    });
  });

  group('android', () {
    late FakeScreenCaptureService service;

    setUp(() {
      service = FakeScreenCaptureService();
      backend = FakeMediaBackend(
        platform: MediaPlatform.android,
        screenCapture: service,
      );
    });

    test('asks for consent, then starts the service, then captures', () async {
      final share = ScreenShareSource(backend: backend);
      expect(share.isSupported, isTrue);
      expect(share.usesSystemPicker, isTrue);
      expect(share.usesBrowserPicker, isFalse);
      expect(() => share.start(source: screen1), throwsArgumentError);
      expect(() => share.select(screen1), throwsUnsupportedError);
      var startedBeforeCapture = false;
      backend.onDisplayMedia = (constraints) async {
        startedBeforeCapture = service.running;
        final stream = FakeStream([FakeTrack(kind: 'video')]);
        backend.streams.add(stream);
        return stream;
      };

      expect(await share.start(), isTrue);
      expect(startedBeforeCapture, isTrue);
      final video = videoOf(share);
      expect(service.calls, ['consent', 'start', 'watch:${video.id}']);
      expect(backend.displayMediaCalls, hasLength(1));
      expect(share.selectedSource, isNull);

      await share.stop();
      expect(video.stopped, isTrue);
      expect(service.calls.last, 'stop');
      expect(service.running, isFalse);
      await share.dispose();
    });

    test('a cancelled consent dialog returns false, not an error', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      service.consent = false;

      expect(await share.start(), isFalse);
      await pumpEventQueue();
      expect(errors, isEmpty);
      expect(share.isEnabled, isFalse);
      expect(service.calls, ['consent']);
      expect(backend.displayMediaCalls, isEmpty);
      await share.dispose();
    });

    test('a service that fails to start is a capture error', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      service.startError = PlatformException(code: 'screen_capture');

      expect(await share.start(), isFalse);
      await pumpEventQueue();
      expect(errors.single, isA<MediaCaptureException>());
      expect(backend.displayMediaCalls, isEmpty);
      expect(service.calls, ['consent', 'start', 'stop']);
      await share.dispose();
    });

    test('a failed capture stops the service', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      backend.onDisplayMedia = (constraints) async =>
          throw 'Unable to getDisplayMedia: SecurityException';

      expect(await share.start(), isFalse);
      await pumpEventQueue();
      expect(errors.single, isA<MediaCaptureException>());
      expect(service.calls, ['consent', 'start', 'stop']);
      expect(service.running, isFalse);
      await share.dispose();
    });

    test(
      'stopped while the consent dialog is open: nothing is captured',
      () async {
        final share = ScreenShareSource(backend: backend);
        service.consentGate = Completer<void>();
        final started = share.start();
        await pumpEventQueue();
        final stopped = share.stop();
        service.consentGate!.complete();

        expect(await started, isFalse);
        await stopped;
        expect(backend.displayMediaCalls, isEmpty);
        expect(service.calls, ['consent']);
        await share.dispose();
      },
    );

    for (final (what, byTrack) in [
      ('the system stop control', true),
      ('the notification', false),
    ]) {
      test('$what ends the share as userStopped', () async {
        final share = ScreenShareSource(backend: backend);
        final reasons = <ScreenShareEndReason>[];
        share.ended.listen(reasons.add);
        await share.startBroadcasting();
        final video = videoOf(share);

        service.stopFromSystem(byTrack ? video.id : null);
        await pumpEventQueue();
        expect(reasons, [ScreenShareEndReason.userStopped]);
        expect(share.isEnabled, isFalse);
        expect(share.broadcastTrack, isNull);
        expect(video.stopped, isTrue);
        expect(service.calls.last, 'stop');
        await share.dispose();
      });
    }

    test("a stop for another share's track is ignored", () async {
      final share = ScreenShareSource(backend: backend);
      final reasons = <ScreenShareEndReason>[];
      share.ended.listen(reasons.add);
      await share.start();

      service.stopFromSystem('some-other-track');
      await pumpEventQueue();
      expect(reasons, isEmpty);
      expect(share.track, isNotNull);
      await share.dispose();
      expect(reasons, [ScreenShareEndReason.stopped]);
    });

    test('captureAudio is ignored, not an error', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      // Like flutter_webrtc on Android: video only, whatever is asked.
      backend.onDisplayMedia = (constraints) async =>
          FakeStream([FakeTrack(kind: 'video')]);

      expect(
        await share.start(
          options: const ScreenShareOptions(captureAudio: true),
        ),
        isTrue,
      );
      expect(share.audioTrack, isNull);
      expect(errors, isEmpty);
      await share.dispose();
    });

    test('a watch that fails still shares', () async {
      final share = ScreenShareSource(backend: backend);
      service.canWatch = false;
      expect(await share.start(), isTrue);
      expect(share.track, isNotNull);
      await share.dispose();
    });

    test(
      'muting releases the capture; unmuting asks for consent again',
      () async {
        final share = ScreenShareSource(backend: backend);
        await share.startBroadcasting();
        await share.stopBroadcasting();
        expect(share.track, isNull);
        expect(service.calls.last, 'stop');

        await share.startBroadcasting();
        expect(share.track, isNotNull);
        expect(service.calls.where((c) => c == 'consent'), hasLength(2));
        await share.dispose();
      },
    );

    test('without the service backend it is unsupported', () async {
      final share = ScreenShareSource(
        backend: FakeMediaBackend(platform: MediaPlatform.android),
      );
      expect(share.isSupported, isFalse);
      expect(() => share.start(), throwsUnsupportedError);
      await share.dispose();
    });
  });

  group('iOS', () {
    late FakeBroadcastExtension broadcast;

    setUp(() {
      broadcast = FakeBroadcastExtension();
      backend = FakeMediaBackend(
        platform: MediaPlatform.ios,
        broadcast: broadcast,
      );
      // Like the real extension: releasing the capture ends the broadcast.
      backend.onDisplayMedia = (constraints) async {
        final stream = FakeStream([
          FakeTrack(kind: 'video')..onStop = broadcast.captureReleased,
        ]);
        backend.streams.add(stream);
        return stream;
      };
    });

    test(
      'checks the setup, shows the picker, waits for the broadcast',
      () async {
        final share = ScreenShareSource(
          backend: backend,
          options: const ScreenShareOptions(
            frameRate: 10,
            broadcastScale: 0.75,
          ),
        );
        expect(share.isSupported, isTrue);
        expect(share.usesSystemPicker, isTrue);
        expect(share.usesBrowserPicker, isFalse);
        expect(() => share.start(source: screen1), throwsArgumentError);
        expect(() => share.select(screen1), throwsUnsupportedError);

        var done = false;
        final started = share.start().then((ok) {
          done = true;
          return ok;
        });
        await pumpEventQueue();
        expect(broadcast.calls, ['status', 'prepare:10@0.75']);
        expect(backend.displayMediaCalls.single, {
          'audio': false,
          'video': {'deviceId': 'broadcast'},
        });
        expect(done, isFalse, reason: 'waits for the user');
        expect(share.track, isNull);

        broadcast.start();
        expect(await started, isTrue);
        expect(share.track, isNotNull);
        expect(share.selectedSource, isNull);
        await share.dispose();
      },
    );

    test('a missing setup is reported with guidance', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      broadcast.problems = const [
        BroadcastSetupProblem.noAppGroupKey,
        BroadcastSetupProblem.extensionMissing,
      ];

      expect(await share.start(), isFalse);
      await pumpEventQueue();
      final error = errors.single as ScreenShareSetupException;
      expect(error.problems, broadcast.problems);
      expect(error.guidance, contains('RTCAppGroupIdentifier'));
      expect(error.guidance, contains('Embed Foundation Extensions'));
      expect(error.guidance, contains('iOS screen share setup'));
      expect(backend.displayMediaCalls, isEmpty);
      expect(broadcast.calls, ['status']);
      await share.dispose();
    });

    test('a failing setup check is a capture error, not a hang', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      broadcast.statusError = MissingPluginException();

      expect(await share.start(), isFalse);
      await pumpEventQueue();
      expect(errors.single, isA<MediaCaptureException>());
      await share.dispose();
    });

    test('a broadcast that never starts times out without an error', () {
      fakeAsync((async) {
        final share = ScreenShareSource(backend: backend);
        final errors = <MediaException>[];
        share.errors.listen(errors.add);
        bool? result;
        share.start().then((ok) => result = ok);
        async.elapse(const Duration(seconds: 59));
        expect(result, isNull);

        async.elapse(const Duration(seconds: 2));
        expect(result, isFalse);
        expect(errors, isEmpty);
        expect(share.isEnabled, isFalse);
        expect(backend.streams.single.track.stopped, isTrue);
        expect(broadcast.calls.last, 'abandon');
        share.dispose();
        async.flushMicrotasks();
      });
    });

    test('the start timeout is configurable', () {
      fakeAsync((async) {
        final share = ScreenShareSource(
          backend: backend,
          options: const ScreenShareOptions(
            broadcastStartTimeout: Duration(seconds: 5),
          ),
        );
        bool? result;
        share.start().then((ok) => result = ok);
        async.elapse(const Duration(seconds: 6));
        expect(result, isFalse);
        share.dispose();
        async.flushMicrotasks();
      });
    });

    test('stopping while waiting gives up at once', () async {
      final share = ScreenShareSource(backend: backend);
      final started = share.start();
      await pumpEventQueue();
      await share.stop();

      expect(await started, isFalse);
      expect(backend.streams.single.track.stopped, isTrue);
      expect(broadcast.calls.last, 'abandon');
      // A broadcast that starts late is ignored.
      broadcast.start();
      await pumpEventQueue();
      expect(share.track, isNull);
      await share.dispose();
    });

    test('a broadcast that finishes before it starts returns false', () async {
      final share = ScreenShareSource(backend: backend);
      final started = share.start();
      await pumpEventQueue();
      broadcast.finish();
      expect(await started, isFalse);
      expect(share.isEnabled, isFalse);
      await share.dispose();
    });

    test('a running broadcast is used without the picker', () async {
      broadcast.broadcasting = true;
      final share = ScreenShareSource(backend: backend);
      expect(await share.start(), isTrue);
      expect(backend.displayMediaCalls.single, {
        'audio': false,
        'video': {'deviceId': 'broadcast-manual'},
      });
      await share.dispose();
    });

    test(
      'the user stopping the broadcast ends the share as userStopped',
      () async {
        final share = ScreenShareSource(backend: backend);
        final reasons = <ScreenShareEndReason>[];
        share.ended.listen(reasons.add);
        final started = share.startBroadcasting();
        await pumpEventQueue();
        broadcast.start();
        expect(await started, isTrue);
        final video = videoOf(share);

        broadcast.finish();
        await pumpEventQueue();
        expect(reasons, [ScreenShareEndReason.userStopped]);
        expect(share.isEnabled, isFalse);
        expect(share.broadcastTrack, isNull);
        expect(video.stopped, isTrue);
        await share.dispose();
      },
    );

    test('stopping waits for the broadcast to finish', () async {
      final share = ScreenShareSource(backend: backend);
      final reasons = <ScreenShareEndReason>[];
      share.ended.listen(reasons.add);
      final started = share.start();
      await pumpEventQueue();
      broadcast.start();
      expect(await started, isTrue);

      await share.stop();
      expect(broadcast.broadcasting, isFalse);
      expect(reasons, [ScreenShareEndReason.stopped]);

      // The next share shows the picker again.
      final again = share.start();
      await pumpEventQueue();
      expect(
        (backend.displayMediaCalls.last['video'] as Map)['deviceId'],
        'broadcast',
      );
      broadcast.start();
      expect(await again, isTrue);
      await share.dispose();
    });

    test('a broadcast that never reports its end delays a stop only a bit', () {
      fakeAsync((async) {
        backend.onDisplayMedia = (constraints) async =>
            FakeStream([FakeTrack(kind: 'video')]);
        final share = ScreenShareSource(backend: backend);
        share.start();
        async.flushMicrotasks();
        broadcast.start();
        async.flushMicrotasks();
        expect(share.track, isNotNull);

        var stopped = false;
        share.stop().then((_) => stopped = true);
        async.elapse(const Duration(seconds: 2));
        expect(stopped, isFalse);
        async.elapse(const Duration(seconds: 2));
        expect(stopped, isTrue);
        share.dispose();
        async.flushMicrotasks();
      });
    });

    test('captureAudio is ignored, not an error', () async {
      final share = ScreenShareSource(backend: backend);
      final errors = <MediaException>[];
      share.errors.listen(errors.add);
      final started = share.start(
        options: const ScreenShareOptions(captureAudio: true),
      );
      await pumpEventQueue();
      broadcast.start();
      expect(await started, isTrue);
      expect(backend.displayMediaCalls.single['audio'], isFalse);
      expect(share.audioTrack, isNull);
      expect(errors, isEmpty);
      await share.dispose();
    });

    test('without the broadcast backend it is unsupported', () async {
      final share = ScreenShareSource(
        backend: FakeMediaBackend(platform: MediaPlatform.ios),
      );
      expect(share.isSupported, isFalse);
      expect(share.usesSystemPicker, isFalse);
      expect(() => share.start(), throwsUnsupportedError);
      expect(() => share.startBroadcasting(), throwsUnsupportedError);
      await share.dispose();
    });
  });

  test('dispose releases the share and completes its streams', () async {
    final share = ScreenShareSource(backend: backend);
    final reasons = <ScreenShareEndReason>[];
    final ended = share.ended.listen(reasons.add).asFuture<void>();
    await share.start(source: screen1);
    final video = videoOf(share);

    await share.dispose();
    await ended;
    expect(reasons, [ScreenShareEndReason.stopped]);
    expect(video.stopped, isTrue);
    expect(() => share.start(source: screen1), throwsStateError);
  });
}
