import 'package:cloudflare_realtime/cloudflare_realtime.dart';
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
}
