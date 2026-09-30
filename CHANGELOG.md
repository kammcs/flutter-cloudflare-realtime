# Changelog

## Unreleased

- Repository scaffold and design docs.
- `Signaling` interface, `ParticipantState`/`TrackInfo` with a JSON wire shape, and `InMemorySignaling` with a shared `InMemorySignalingHub`.
- Example app shell (`example/`) with platform permissions for camera, microphone and network.
- Media layer: `MediaDeviceList`, `CameraSource` and `MicrophoneSource` with preferred devices and automatic fallback, the enabled/broadcasting mute model with a `MutePolicy`, `ScreenShareSource` (desktop and web) and the desktop `ScreenSourcePicker`, all behind a testable `MediaBackend`.
- Example app: a local media page with camera and microphone toggles, device dropdowns and a screen-source picker with preview.
- Quality and reconnection building blocks (not yet wired to a session): the `SimulcastLayerReporter` widget with `LayerDemandReporter`/`TileDemand`, tuning via `LayerSelectionConfig`, `ActiveSpeakerConfig`, `BackoffConfig` and `ReconnectTriggerConfig`, plus internal layer-selection, active-speaker and reconnect-trigger logic.
