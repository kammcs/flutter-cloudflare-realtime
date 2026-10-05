# Migrating to 0.1.0

Before its first release on pub.dev, the API was cleaned up in one breaking pass. Code written against the pre-release API (the GitHub repository before 0.1.0) needs the changes below; behaviour is unchanged unless a row says otherwise. The reasons are in [docs/api-review.md](https://github.com/kammcs/flutter-cloudflare-realtime/blob/main/docs/api-review.md).

The analyzer finds almost everything: a stream used as a value, or a value used as a stream, no longer type-checks. Two kinds of change it can't flag on their own:

- **A getter that kept its name but changed meaning.** `room.participants`, `room.connectionState`, `room.activeSpeakers`, `room.dominantSpeaker`, `room.stats`, `room.audioRoutes`, `publication.track` and `publication.stats` (and the others marked "now the value" below) used to be streams and are now values. Code that only passes them to something taking `Object?` (string interpolation, `print`, `expect(x, isNotNull)`) still compiles. Search for them.
- **Polling of stats.** Reading `room.stats` (now a `RoomStats?`) doesn't start polling; listening to `room.statsChanges` does, as listening to the old `room.stats` stream did.

A safe order: rename the streams first (`.participants` → `.participantsChanges`), then the `current…` getters (`.currentParticipants` → `.participants`).

## 1. Imports

Most apps import only `package:cloudflare_realtime/cloudflare_realtime.dart`, as before. Two new libraries hold what moved out of it:

| Symbols | Now in |
|---|---|
| `BrokerClient`, `HttpBrokerClient`, `BrokerHeaders`; the wire models `NewSessionRequest`, `NewSessionResponse`, `SessionState`, `SessionTrackState`, `SessionDataChannelState`, `TracksRequest`, `TracksResponse`, `UpdateTracksRequest`, `CloseTracksRequest`, `RenegotiateRequest`, `RenegotiateResponse`, `TrackObject`, `TrackResult`, `SimulcastOptions` (was `SimulcastConfig`), `DataChannelsRequest`, `DataChannelsResponse`, `EstablishDataChannelsRequest`, `EstablishDataChannelsResponse`, `DataChannelObject`, `DataChannelResult`, `SessionDescription`, `IceServer`, `IceServersResponse`, `SfuErrorFields`, `SdpType`, `TrackLocation`, `ResourceStatus`; `SfuSession`, `LocalTrackPublication`, `RemoteTrackSubscription`, `SfuConnectionState`, `PublishOptions`, `defaultVideoCodecPreferences` | `package:cloudflare_realtime/broker.dart` |
| `MediaBackend`, `DesktopCapturerBackend`, `ScreenCaptureServiceBackend`, `BroadcastExtensionBackend`, `BroadcastExtensionStatus`, `BroadcastExtensionEvent`, `FlutterWebrtcMediaBackend`; `VideoRenderer`, `FlutterWebrtcVideoRenderer`, `VideoRendererFactory`; `MediaStreamWrapper`, `wrapTrackInMediaStream`; `BrokerClientFactory`, `SfuSessionConnector`; `InMemorySignaling`, `InMemorySignalingHub` | `package:cloudflare_realtime/testing.dart` |

Everything else stays in the main library, including `BrokerOptions`, every exception, `SfuSessionOptions`, `SfuSessionDefaults`, `SfuTrackState`, `SendEncoding`, `SimulcastPresets`, `VideoCodec`, `SimulcastOrdering`, `BroadcastSetupProblem`, `SfuSessionFailure` and the DataChannel types. No symbol is exported from two libraries.

`Room.session` still returns the `SfuSession`; import `broker.dart` only to name the type.

## 2. Renamed classes

| Before | After |
|---|---|
| `BrokerConfig` | `BrokerOptions` |
| `ActiveSpeakerConfig` | `ActiveSpeakerOptions` |
| `BackoffConfig` | `BackoffOptions` |
| `ConnectionQualityConfig` | `ConnectionQualityOptions` |
| `LayerSelectionConfig` | `LayerSelectionOptions` |
| `ReconnectTriggerConfig` | `ReconnectTriggerOptions` |
| `SystemCallsConfig` | `SystemCallsOptions` |
| `SimulcastConfig` (wire model, `broker.dart`) | `SimulcastOptions` |
| `ConnectionQualityChangedEvent` | `ParticipantConnectionQualityChangedEvent` |
| `LocalScreenShareStalledEvent` | `LocalTrackStalledEvent` |
| `CallInterruptedEvent` | `RoomAudioInterruptedEvent` |
| `CallResumedEvent` | `RoomAudioResumedEvent` |
| `LocalCameraPausedEvent` | `RoomCameraPausedEvent` |
| `LocalCameraResumedEvent` | `RoomCameraResumedEvent` |

The events' fields are unchanged. `RoomReconnectAttemptEvent` is new (one per reconnection attempt), so an exhaustive `switch` over `RoomEvent` needs a case for it.

## 3. Observable state: the value, and `…Changes`

Every piece of state is now a getter for the value now, `x`, and a stream `xChanges` that replays the current value to each new listener, then emits each change. Booleans are `isX`, and their stream drops the `is` (`isMuted` / `mutedChanges`).

```dart
// Before
StreamBuilder(stream: room.participants, initialData: room.currentParticipants, ...)
// After
StreamBuilder(stream: room.participantsChanges, initialData: room.participants, ...)
```

| Class | Before | After |
|---|---|---|
| `Room` | `participants` (stream) | `participantsChanges` |
| | `currentParticipants` | `participants` (now the value) |
| | `connectionState` (stream) | `connectionStateChanges` |
| | `currentConnectionState` | `connectionState` (now the value) |
| | `activeSpeakers` (stream) | `activeSpeakersChanges` |
| | `currentActiveSpeakers` | `activeSpeakers` (now the value) |
| | `dominantSpeaker` (stream) | `dominantSpeakerChanges` |
| | `currentDominantSpeaker` | `dominantSpeaker` (now the value) |
| | `stats` (stream) | `statsChanges` (listening starts the polling) |
| | `currentStats` | `stats` (now the value, `RoomStats?`) |
| | `audioRoutes` (stream) | `audioRoutesChanges` |
| | `currentAudioRoutes` | `audioRoutes` (now the value) |
| | `currentAudioRoute` | `audioRoute` (`audioRouteChanges` unchanged) |
| | `audioPlaybackBlocked` | `isAudioPlaybackBlocked` (`audioPlaybackBlockedChanges` unchanged) |
| | `speakerphone` | `isSpeakerphoneOn` |
| | `speakerphoneChanges` | `speakerphoneOnChanges` |
| | `proximitySensorActive` | `isProximitySensorActive` |
| | `proximitySensorChanges` | `proximitySensorActiveChanges` |
| | `keepingScreenAwake` | `isKeepingScreenAwake` (`keepingScreenAwakeChanges` unchanged) |
| `LocalParticipant`, `RemoteParticipant` | `audioLevels` | `audioLevelChanges` |
| `Participant` | | now also declares `speakingChanges`, `audioLevel` and `audioLevelChanges`, which both subtypes already had |
| `LocalMediaPublication` | `muted` | `isMuted` (`mutedChanges` unchanged) |
| | `stats` (stream) | `statsChanges` |
| | `currentStats` | `stats` (now the value) |
| `RemoteTrackPublication` | `muted` | `isMuted` (`mutedChanges` unchanged) |
| | `track` (stream) | `trackChanges` |
| | `currentTrack` | `track` (now the value) |
| | `stats` (stream) | `statsChanges` |
| | `currentStats` | `stats` (now the value) |
| | `layerChanges` | `layerStateChanges` |
| `LocalMediaSource` (and `CameraSource`, `MicrophoneSource`, `ScreenShareSource`) | `enabled` (stream) | `enabledChanges` (`isEnabled` unchanged) |
| | `broadcasting` (stream) | `broadcastingChanges` (`isBroadcasting` unchanged) |
| | `track` (stream) | `trackChanges` |
| | `currentTrack` | `track` (now the value) |
| | `broadcastTrack` (stream) | `broadcastTrackChanges` |
| | `currentBroadcastTrack` | `broadcastTrack` (now the value) |
| `DeviceMediaSource` (`CameraSource`, `MicrophoneSource`) | `devices` (stream) | `devicesChanges` |
| | `currentDevices` | `devices` (now the value) |
| | `preferredDevice` (stream) | `preferredDeviceChanges` |
| | `currentPreferredDevice` | `preferredDevice` (now the value) |
| | `activeDevice` (stream) | `activeDeviceChanges` |
| | `currentActiveDevice` | `activeDevice` (now the value) |
| `CameraSource` | `currentFacing` | `facing` |
| `ScreenShareSource` | `audioTrack` (stream) | `audioTrackChanges` |
| | `currentAudioTrack` | `audioTrack` (now the value) |
| | `broadcastAudioTrack` (stream) | `broadcastAudioTrackChanges` |
| | `currentBroadcastAudioTrack` | `broadcastAudioTrack` (now the value) |
| `ScreenSourcePicker` | `state` (stream) | `stateChanges` |
| | `currentState` | `state` (now the value) |
| `MediaDeviceList` | `devices` (stream) | `devicesChanges` |
| | `currentDevices` | `devices` (now the value) |
| | `devicesOfKind(kind)` (stream) | `devicesOfKindChanges(kind)` |
| | `currentDevicesOfKind(kind)` | `devicesOfKind(kind)` (now the value) |
| | `audioInputs`, `videoInputs`, `audioOutputs` (streams) | `audioInputsChanges`, `videoInputsChanges`, `audioOutputsChanges`; `audioInputs`, `videoInputs`, `audioOutputs` are now the lists |
| `SfuSession` (`broker.dart`) | `connectionState` (stream) | `connectionStateChanges` |
| | `currentConnectionState` | `connectionState` (now the value) |
| `LocalTrackPublication`, `RemoteTrackSubscription` (`broker.dart`), `SfuDataChannel` (`LocalDataChannel`, `RemoteDataChannel`) | `states` | `stateChanges` |
| `RemoteTrackSubscription` (`broker.dart`) | `trackStream` | `trackChanges` |
| `SystemCall` | `muted` | `isMuted` (`mutedChanges` unchanged) |
| | `outgoing` | `isOutgoing` |
| | `video` | `isVideo` |
| `SystemCalls`, `VoipPush` | `supported` | `isSupported` |
| `HttpBrokerClient` (`broker.dart`) | `HttpBrokerClient(config: …)`, `.config` | `HttpBrokerClient(options: …)`, `.options` |

Unchanged on purpose: streams of things that happen rather than of state (`Room.events`, `LocalMediaSource.errors`, `SfuSession.failures`, `ScreenShareSource.ended`, the `messages` of DataChannels, and the `changes` stream of a participant or a publication, which emits the object itself), the interfaces your app implements (`Signaling.participants`, `NetworkChangeSource.changes`, `AppLifecycleSource.states`), and `RemoteTrackPublication.currentRid`, which is the rid asked for now as opposed to `RemoteTrackLayerState.targetRid`.

## 4. Exceptions

`BrokerException` and `SfuSessionException` are now `sealed`, like `MediaException` already was, so a `switch` over them is exhaustive. `catch (e) on BrokerException` works as before.

| Before | After |
|---|---|
| A plain `BrokerException` for any other error response (a non-2xx status other than 401, 403 and 410, or an SFU error in a 2xx `sessions/new` body) | `BrokerResponseException` (same fields). A custom `BrokerClient` that threw `BrokerException(...)` throws `BrokerResponseException(...)` |
| A plain `SfuSessionException` when a publication, subscription or DataChannel was unpublished, closed, interrupted or moved before the operation completed | `SfuInterruptedException` |
| A plain `SfuSessionException` when the SFU's answer was unusable (no result for a request, no answer, a renegotiation without an offer, a transceiver without a `mid`) | `SfuProtocolException` |
| `SfuDataChannelException` | unchanged name; now in the same sealed family as the other `SfuSessionException`s |
| `Room.setAudioOutputDevice` threw the platform's error unchanged when it refused the device: in a browser a JavaScript `DOMException` (not an `Exception`, untyped under WebAssembly), on native platforms a `PlatformException` | `AudioOutputException`, with `reason` (`AudioOutputFailure.needsUserGesture`, `notFound`, `permissionDenied` or `other`), `deviceId` and the platform's error as `cause`. Replace `catch (e)` and matching on `'$e'.contains('NotAllowedError')` with `on AudioOutputException catch (e)` and `e.reason == AudioOutputFailure.needsUserGesture` |

`e.runtimeType == BrokerException` is never true any more; use `is` or a `switch`.

**`toString()` no longer includes text from outside the package** (`docs/design.md` §4.9), so that an app printing an exception doesn't log a broker's response body. The fields are unchanged; read them if you matched on the string:

| Exception | No longer in `toString()` | Still there as |
|---|---|---|
| `BrokerException` and its subtypes | `errorDescription` | `e.errorDescription` |
| `SfuTrackException`, `SfuRequestException`, `SfuDataChannelException` | `errorDescription` | `e.errorDescription` |
| `MediaException` and its subtypes | the cause's text (its type is shown) | `e.cause` |
| `AudioOutputException` | the cause's text (its type is shown) | `e.cause` |
| `SystemCallException` | the platform's message | `e.message` |

The package's own log lines changed the same way: they show an error's type and code, and `CloudflareRealtime.logger` receives the full error.

## 5. Class modifiers

These classes are now `final`: they can't be extended or implemented outside the package. Build them with their constructors (they all have public ones, most of them `const`) instead of subclassing or mocking them.

- **Options:** `RoomOptions`, `AutoSubscribe`, `ReconnectOptions`, `RoomStatsOptions`, `LayerPausingOptions`, `LayerSelectionOptions`, `ActiveSpeakerOptions`, `ConnectionQualityOptions`, `QualityThresholds`, `BackoffOptions`, `ReconnectTriggerOptions`, `CameraOptions`, `MicrophoneOptions`, `ScreenShareOptions`, `VideoPreset`, `SfuSessionOptions`, `SfuSessionDefaults`, `PublishOptions`, `SendEncoding`, `BrokerOptions`, `SystemCallsOptions`.
- **Values:** `ParticipantState`, `TrackInfo`, `SimulcastInfo`, `MediaDevice`, `ScreenSource`, `CapturedTrack`, `RenderableTrack`, `AudioRoute`, `CallHandle`, `ScreenPickerState`, `RemoteTrackLayerState`, `TileDemand`, `BroadcastExtensionStatus`, `DataChannelMessage`, `RoomDataMessage`. `RoomDataMessage` has a public constructor now, `RoomDataMessage(message, participantId)`, for tests.
- **Stats:** `RoomStats`, `ConnectionStats`, `IceCandidateStats`, `LocalTrackStats`, `OutboundLayerStats`, `RemoteTrackStats`.
- **Wire models** (`broker.dart`): every request, response and result class listed in section 1.
- **Exceptions:** every subtype of `BrokerException` and `SfuSessionException`, `AudioRouteUnavailableException`, `SystemCallException`, and the new `AudioOutputException`.

Still open for mocking (`class MockRoom extends Mock implements Room`): `CloudflareRealtime`, `Room`, `LocalParticipant`, `RemoteParticipant`, `LocalMediaPublication`, `RemoteTrackPublication`, `RemoteTrackLease`, `RoomData`, `RemoteDataSubscription`, the media sources, `MediaDeviceList`, `ScreenSourcePicker`, `SystemCalls`, `SystemCall`, `VoipPush`, and in `broker.dart` `SfuSession`, `LocalTrackPublication`, `RemoteTrackSubscription` and `HttpBrokerClient`. The interfaces you implement (`Signaling`, `BrokerClient`, `MediaBackend` and its parts, `VideoRenderer`, `NetworkChangeSource`, `AppLifecycleSource`, `LayerDemandReporter`) are unchanged.
