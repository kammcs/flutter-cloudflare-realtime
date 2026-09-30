# Changelog

## Unreleased

- Repository scaffold and design docs.
- `Signaling` interface, `ParticipantState`/`TrackInfo` with a JSON wire shape, and `InMemorySignaling` with a shared `InMemorySignalingHub`.
- Example app shell (`example/`) with platform permissions for camera, microphone and network.
- Media layer: `MediaDeviceList`, `CameraSource` and `MicrophoneSource` with preferred devices and automatic fallback, the enabled/broadcasting mute model with a `MutePolicy`, `ScreenShareSource` (desktop and web) and the desktop `ScreenSourcePicker`, all behind a testable `MediaBackend`.
- Example app: a local media page with camera and microphone toggles, device dropdowns and a screen-source picker with preview.
