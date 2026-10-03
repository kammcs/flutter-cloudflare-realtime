import 'package:cloudflare_realtime/broker.dart';
import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime/testing.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the barrel exports the signaling API', () {
    final Signaling signaling = InMemorySignaling(InMemorySignalingHub());
    expect(signaling, isA<InMemorySignaling>());
    expect(
      ParticipantState(
        participantId: 'p',
        tracks: const {
          'cam': TrackInfo(kind: TrackKind.video, source: TrackSource.camera),
        },
      ).tracks,
      hasLength(1),
    );
  });

  test('the barrel exports the session API', () {
    const options = SfuSessionOptions(
      defaults: SfuSessionDefaults(videoEncodings: SimulcastPresets.h360),
    );
    expect(options.defaults.videoEncodings.map((e) => e.rid), ['a', 'b', 'c']);
    expect(const PublishOptions(trackName: 'cam').trackName, 'cam');
    expect(SfuConnectionState.values, hasLength(6));
    expect(SfuTrackState.values, hasLength(5));
    expect(
      const SfuPeerConnectionFailed(PeerConnectionFailureKind.iceFailed),
      isA<SfuSessionFailure>(),
    );
    expect(SfuSession.connect, isA<Function>());
  });

  test('the barrel exports the media API', () {
    const MediaBackend backend = FlutterWebrtcMediaBackend();
    expect(backend, isA<MediaBackend>());
    expect(VideoPreset.h720.width, 1280);
    expect(MutePolicy.values, hasLength(2));
    expect(ScreenShareEndReason.values, contains(ScreenShareEndReason.stopped));
    expect(ScreenPickerState().sources, isEmpty);
    expect(
      const MediaDevice(deviceId: 'a', kind: MediaDeviceKind.audioInput),
      isA<MediaDevice>(),
    );
    expect(const ScreenSourcesException('x'), isA<MediaException>());
  });

  test('the barrel exports the quality and reconnection tuning', () {
    expect(const ActiveSpeakerOptions().pollInterval.inMilliseconds, 250);
    expect(const LayerSelectionOptions().debounce.inMilliseconds, 300);
    expect(const TileDemand(width: 1, height: 1).needsVideo, isTrue);
    expect(const BackoffOptions().multiplier, 2.0);
    expect(const ReconnectTriggerOptions().disconnectedTimeout.inSeconds, 5);
    expect(ReconnectReason.values, contains(ReconnectReason.sessionGone));
    LayerDemandReporter? reporter;
    expect(reporter, isNull);
    expect(SimulcastLayerReporter, isNotNull);
  });
}
