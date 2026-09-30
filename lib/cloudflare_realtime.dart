/// Unofficial Flutter client for the Cloudflare Realtime SFU.
///
/// See `docs/design.md` for the architecture.
library;

// Broker client (design.md §4.1, §5).
export 'src/broker/broker.dart';

// SFU session (design.md §4.2).
export 'src/session/session.dart';

// Signaling (design.md §4.4).
export 'src/signaling/in_memory_signaling.dart'
    show InMemorySignaling, InMemorySignalingHub;
export 'src/signaling/participant_state.dart'
    show ParticipantState, TrackInfo, TrackKind, TrackSource;
export 'src/signaling/signaling.dart' show Signaling;
