# Changelog

## Unreleased

- Repository scaffold and design docs.
- `Signaling` interface, `ParticipantState`/`TrackInfo` with a JSON wire shape, and `InMemorySignaling` with a shared `InMemorySignalingHub`.
- Example app shell (`example/`) with platform permissions for camera, microphone and network.
- Media layer: `MediaDeviceList`, `CameraSource` and `MicrophoneSource` with preferred devices and automatic fallback, the enabled/broadcasting mute model with a `MutePolicy`, `ScreenShareSource` (desktop and web) and the desktop `ScreenSourcePicker`, all behind a testable `MediaBackend`.
- Example app: a local media page with camera and microphone toggles, device dropdowns and a screen-source picker with preview.
- `SfuSession` (ported from partytracks): push, pull, simulcast layer updates and close through one serialized, batching operation queue; per-track errors; `LocalTrackPublication`/`RemoteTrackSubscription` that survive a failed session; `SimulcastPresets`; VP8 by default on Windows.
- Example app: an optional broker URL creates a real SFU session. A loopback integration test runs against a real broker when `CF_REALTIME_BROKER_URL` is set.
- Quality and reconnection building blocks (not yet wired to a session): the `SimulcastLayerReporter` widget with `LayerDemandReporter`/`TileDemand`, tuning via `LayerSelectionConfig`, `ActiveSpeakerConfig`, `BackoffConfig` and `ReconnectTriggerConfig`, plus internal layer-selection, active-speaker and reconnect-trigger logic.
- DataChannels: `SfuSession.publishDataChannel` and `subscribeDataChannel` with `reliable` and `unreliable` profiles, lazy `datachannels/establish`, batched requests, per-channel errors, `canReply` (at subscribe time or with `setCanReply`), `DataChannelMessage.fromSessionId` taken from the channel, `bufferedAmount` with a low-water-mark stream, and `republishDataChannel`/`resubscribeDataChannel` after a session failure. Works around `flutter_webrtc` dropping `maxRetransmits: 0` on native platforms. A DataChannel echo integration test runs against a real broker when `CF_REALTIME_BROKER_URL` is set.
- Rooms: `CloudflareRealtime.join` returns a `Room` with `localParticipant`, `participants`, `events`, `connectionState` and `leave()`. `LocalParticipant.publishCamera`/`publishMicrophone`/`publishScreen`/`publishMediaSource` with mute and unmute; `RemoteParticipant` and `RemoteTrackPublication` with pull-on-subscribe (`AutoSubscribe`, `subscribe`, leases), `setPreferredLayer(SimulcastLayer)`, pull retries, and re-pulling when a publisher changes session. `room.data` maps DataChannel senders to participants through signaling.
- `TrackInfo.muted` and `TrackInfo.simulcast` (`SimulcastInfo`): optional, backward-compatible fields in the signaling wire shape.
- `ParticipantVideoView` for local and remote video, behind an injectable `VideoRenderer`, with a `LayerDemandReporter` hook for layer selection. Pulled tracks are exposed as `RenderableTrack` (the track plus a `MediaStream` holding it).
- Example app: a call screen (video grid, microphone/camera/screen controls, leave) with in-memory or dev-server signaling chosen on the join screen, and a presence-only mode without a broker.
