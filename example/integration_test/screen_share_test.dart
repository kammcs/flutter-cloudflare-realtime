// Shares the screen through a real broker on a phone, with the same call
// as every platform (LocalParticipant.publishScreen). On Android: the
// system's consent dialog, this package's foreground service, then
// flutter_webrtc's capture. On iOS: the system's broadcast picker, then the
// example's Broadcast Upload Extension (the package's template) sending
// frames to flutter_webrtc. Two rooms in one process share in-memory
// signaling; Alice shares her screen, Bob pulls it. Alice's outbound frames
// and Bob's decoded frames must keep rising. Then Alice stops sharing, and
// the track must be unpublished, announced and gone from Bob's view.
//
// It needs a person at the phone. Android: the consent dialog needs a tap
// ("Start now", or on Android 14+ "Entire screen" then "Share screen");
// docs/checkpoint.md shows how to automate it with adb. Grant
// POST_NOTIFICATIONS first (or answer its prompt). iOS: tap "Start
// Broadcast" in the picker within 2 minutes of the "TAP" line in the log.
//
// With CF_REALTIME_SCREEN_SHARE_EXTERNAL_STOP=1 it also shares a second
// time and waits for the share to be stopped outside the app (Android: the
// notification's "Stop sharing", or the system's stop control; iOS: the
// red status-bar indicator or Control Center), which must unpublish it
// with ScreenShareEndReason.userStopped.
//
// In a browser it runs only with CF_REALTIME_SCREEN_SHARE_WEB=true, as
// the browser's picker needs a person unless the browser accepts it by
// itself: Chrome with --use-fake-ui-for-media-stream (and
// --use-fake-device-for-media-stream for a fake screen), or Firefox with
// media.navigator.permission.disabled. docs/checkpoint.md §7 has the
// command lines.
//
// Skipped unless CF_REALTIME_BROKER_URL is set (see broker_settings.dart),
// and on desktops, where the app picks the source. The test never prints
// the settings.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show StatsReport;
import 'package:integration_test/integration_test.dart';

import 'broker_settings.dart';

/// How long one media check may take.
const _timeout = Duration(seconds: 30);

/// How long the consent dialog may wait for its tap.
const _consentTimeout = Duration(minutes: 2);

/// How long to wait for a stop from outside the app.
const _externalStopTimeout = Duration(minutes: 2);

const _externalStop = bool.fromEnvironment(
  'CF_REALTIME_SCREEN_SHARE_EXTERNAL_STOP',
);

const _web = kIsWeb && bool.fromEnvironment('CF_REALTIME_SCREEN_SHARE_WEB');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final settings = BrokerSettings.read();
  final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  // On iOS the broadcast picker waits for a person: give them as long as
  // the test waits.
  const shareOptions = ScreenShareOptions(
    broadcastStartTimeout: _consentTimeout,
  );

  // Needs no person and no broker: the native setup check on an iPhone
  // (Info.plist keys, App Group container, embedded extension).
  testWidgets('iOS: the app is set up for a broadcast', (tester) async {
    final broadcast = const FlutterWebrtcMediaBackend().broadcastExtension!;
    final status = await broadcast.status();
    _log(
      'setup problems: ${status.problems.map((p) => p.name).toList()}, '
      'broadcasting: ${status.broadcasting}',
    );
    expect(status.problems, isEmpty);
    expect(status.isReady, isTrue);
  }, skip: !ios);

  testWidgets(
    'shares the screen, sends frames, and unpublishes when stopped',
    (tester) async {
      final realtime = CloudflareRealtime(broker: settings.config());
      final hub = InMemorySignalingHub();
      const options = RoomOptions(autoSubscribe: AutoSubscribe.all);
      final suffix = DateTime.now().microsecondsSinceEpoch;
      final alice = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'screen-alice-$suffix',
        options: options,
      );
      addTearDown(alice.leave);
      final bob = await realtime.join(
        settings.room,
        signaling: InMemorySignaling(hub),
        participantId: 'screen-bob-$suffix',
        options: options,
      );
      addTearDown(bob.leave);
      final events = <RoomEvent>[];
      final sub = alice.events.listen(events.add);
      addTearDown(sub.cancel);
      if (ios) {
        // Keeps Alice's session connected while the picker waits (the SFU
        // drops a session whose PeerConnection never connected), and keeps
        // the app's audio session running, as in a call.
        await alice.localParticipant.publishMicrophone();
      }

      // First share: stopped by the app.
      _askToShare(ios);
      var shared = await alice.localParticipant
          .publishScreen(options: shareOptions)
          .timeout(_consentTimeout + const Duration(seconds: 10));
      final share = shared.mediaSource as ScreenShareSource;
      expect(share.usesSystemPicker, isTrue);
      expect(share.audioTrack, isNull, reason: 'no screen audio');
      await shared.publication.whenSending().timeout(_timeout);
      _log('sharing ${_size(share)}');

      await _outboundRising(alice, 'Alice sends');
      final remote = await _remoteScreen(bob, alice);
      await _decodedRising(bob, 'Bob decodes');

      final name = shared.trackName;
      await shared.unpublish();
      expect(alice.localParticipant.screen, isNull);
      expect(
        alice.localParticipant.state.tracks.containsKey(name),
        isFalse,
        reason: 'no longer announced',
      );
      final unpublished = await _eventually(
        () => events.whereType<LocalTrackUnpublishedEvent>(),
        'the unpublished event',
      );
      expect(unpublished.single.publication, same(shared));
      expect(unpublished.single.endReason, isNull, reason: 'the app stopped');
      await _gone(bob, alice, remote);
      _log('unpublished; gone from Bob');

      if (_web) await _webScreenAudio(alice, bob);

      if (!_externalStop) return;

      // Second share: stopped outside the app.
      _askToShare(ios);
      shared = await alice.localParticipant
          .publishScreen(options: shareOptions)
          .timeout(_consentTimeout + const Duration(seconds: 10));
      await shared.publication.whenSending().timeout(_timeout);
      await _outboundRising(alice, 'Alice sends again');
      _log(
        ios
            ? 'STOP the broadcast on the iPhone: the red status-bar '
                  'indicator, or Control Center'
            : 'waiting for a stop from outside the app',
      );
      final ended = await alice.events
          .where((e) => e is LocalTrackUnpublishedEvent)
          .cast<LocalTrackUnpublishedEvent>()
          .firstWhere((e) => identical(e.publication, shared))
          .timeout(_externalStopTimeout);
      expect(ended.endReason, ScreenShareEndReason.userStopped);
      expect(alice.localParticipant.screen, isNull);
      _log('stopped outside the app: ${ended.endReason!.name}');
    },
    skip: settings.skip || !(android || ios || _web),
    timeout: const Timeout(Duration(minutes: 8)),
  );
}

void _log(String message) => debugPrint('[screen-share] $message');

/// In a browser: a share with `captureAudio` publishes the tab or system
/// audio the browser gives (Chrome's fake screen has some) as Alice's
/// `screenAudio`, and Bob pulls it.
Future<void> _webScreenAudio(Room alice, Room bob) async {
  final shared = await alice.localParticipant.publishScreen(
    options: const ScreenShareOptions(captureAudio: true),
  );
  await shared.publication.whenSending().timeout(_timeout);
  final share = shared.mediaSource as ScreenShareSource;
  final audio = share.audioTrack;
  _log('with captureAudio: audio track ${audio == null ? 'none' : 'live'}');
  if (audio != null) {
    final published = alice.localParticipant.screenAudio;
    expect(published, isNotNull, reason: 'the screen audio is published');
    await published!.publication.whenSending().timeout(_timeout);
    final deadline = DateTime.now().add(_timeout);
    while (bob.participants.every(
      (p) =>
          p.sessionId != alice.session.sessionId ||
          p.screenAudio?.subscriptionState != SfuTrackState.active,
    )) {
      if (DateTime.now().isAfter(deadline)) {
        fail("Bob never received Alice's screen audio");
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    _log('Bob receives the screen audio');
  }
  await shared.unpublish();
  expect(alice.localParticipant.screenAudio, isNull);
}

void _askToShare(bool ios) => _log(
  ios
      ? 'TAP "Start Broadcast" on the iPhone (within '
            '${_consentTimeout.inMinutes} minutes)'
      : 'sharing: answer the consent dialog',
);

String _size(ScreenShareSource share) {
  final s = share.track?.track.getSettings() ?? const {};
  return '${s['width'] ?? '?'}x${s['height'] ?? '?'}';
}

num _num(Object? value) =>
    value is num ? value : num.tryParse('${value ?? ''}') ?? 0;

/// The sum of [field] over the [type] video reports in [reports].
num _sum(List<StatsReport> reports, String type, String field) {
  num total = 0;
  for (final r in reports) {
    if (r.type == type && r.values['kind'] == 'video') {
      total += _num(r.values[field]);
    }
  }
  return total;
}

/// Waits until Alice has encoded at least 15 more frames (and sent more
/// bytes) than now.
Future<void> _outboundRising(Room alice, String what) async {
  final first = await alice.session.getStats();
  final startFrames = _sum(first, 'outbound-rtp', 'framesEncoded');
  final startBytes = _sum(first, 'outbound-rtp', 'bytesSent');
  final deadline = DateTime.now().add(_timeout);
  var frames = startFrames;
  var bytes = startBytes;
  while (DateTime.now().isBefore(deadline)) {
    final reports = await alice.session.getStats();
    frames = _sum(reports, 'outbound-rtp', 'framesEncoded');
    bytes = _sum(reports, 'outbound-rtp', 'bytesSent');
    if (frames - startFrames >= 15 && bytes > startBytes) {
      _log(
        '$what: ${frames - startFrames} more frames encoded, '
        '${bytes - startBytes} more bytes',
      );
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail(
    '$what: only ${frames - startFrames} more frames encoded '
    '(${bytes - startBytes} bytes) in $_timeout',
  );
}

/// Waits until Bob has decoded at least 15 more video frames than now.
Future<void> _decodedRising(Room bob, String what) async {
  final start = _sum(
    await bob.session.getStats(),
    'inbound-rtp',
    'framesDecoded',
  );
  final deadline = DateTime.now().add(_timeout);
  var last = start;
  while (DateTime.now().isBefore(deadline)) {
    last = _sum(await bob.session.getStats(), 'inbound-rtp', 'framesDecoded');
    if (last - start >= 15) {
      _log('$what: ${last - start} more frames decoded');
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 500));
  }
  fail('$what: only ${last - start} more frames decoded in $_timeout');
}

/// Waits until [read] returns a non-empty result.
Future<Iterable<T>> _eventually<T>(
  Iterable<T> Function() read,
  String what,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final value = read();
    if (value.isNotEmpty) return value;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  fail('Timed out waiting for $what');
}

/// Alice's screen as Bob receives it, once its pull is active.
Future<RemoteTrackPublication> _remoteScreen(Room bob, Room alice) async {
  final deadline = DateTime.now().add(_timeout);
  while (DateTime.now().isBefore(deadline)) {
    for (final p in bob.participants) {
      final screen = p.screen;
      if (p.sessionId == alice.session.sessionId &&
          screen != null &&
          screen.subscriptionState == SfuTrackState.active) {
        return screen;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail("Bob never received Alice's screen");
}

/// Waits until Bob no longer sees [remote] among Alice's tracks.
Future<void> _gone(Room bob, Room alice, RemoteTrackPublication remote) async {
  final deadline = DateTime.now().add(_timeout);
  while (DateTime.now().isBefore(deadline)) {
    final peer = bob.participants
        .where((p) => p.sessionId == alice.session.sessionId)
        .firstOrNull;
    if (peer == null || peer.screen == null) return;
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
  fail("Bob still sees Alice's screen (${remote.id})");
}
