# Changelog

## Unreleased

- Repository scaffold and design docs.
- `Signaling` interface, `ParticipantState`/`TrackInfo` with a JSON wire shape, and `InMemorySignaling` with a shared `InMemorySignalingHub`.
- Example app shell (`example/`) with platform permissions for camera, microphone and network.
- Media layer: `MediaDeviceList`, `CameraSource` and `MicrophoneSource` with preferred devices and automatic fallback, the enabled/broadcasting mute model with a `MutePolicy`, `ScreenShareSource` (desktop and web) and the desktop `ScreenSourcePicker`, all behind a testable `MediaBackend`.
- Example app: a local media page with camera and microphone toggles, device dropdowns and a screen-source picker with preview.
- `SfuSession` (ported from partytracks): push, pull, simulcast layer updates and close through one serialized, batching operation queue; per-track errors; `LocalTrackPublication`/`RemoteTrackSubscription` that survive a failed session; `SimulcastPresets`; VP8 by default on Windows.
- Example app: an optional broker URL creates a real SFU session. A loopback integration test runs against a real broker when `CF_REALTIME_BROKER_URL` is set.
