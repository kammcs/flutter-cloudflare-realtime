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
}
