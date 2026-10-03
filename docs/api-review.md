# API review for the first pub.dev release (M8)

October 2026, before 0.1.0. The public API is three libraries, **219 symbols**, none exported twice:

| Library | Symbols | For |
|---|---|---|
| `package:cloudflare_realtime/cloudflare_realtime.dart` | 167 | What apps use (165 after the cleanup, plus `AudioOutputException` and `AudioOutputFailure`) |
| `package:cloudflare_realtime/broker.dart` | 36 | The plumbing under `Room`: a custom `BrokerClient`, the SFU API's wire models, direct use of `SfuSession` |
| `package:cloudflare_realtime/testing.dart` | 16 | Seams for testing an app without native WebRTC, and for single-process demos |

This page lists them, records what the M8 review changed, and the decisions of the cleanup that followed it (one breaking pass before 0.1.0; [doc/migrating-to-0.1.md](../doc/migrating-to-0.1.md) has the exact old → new table). Before the cleanup the API was one library of 213 symbols.

How the inventory was made: an `analyzer`-based script read each library's export namespace (names, kinds, class modifiers, `@visibleForTesting`/`@protected` members, documentation, and every public getter's type) and checked every public signature (supertypes, constructors, methods, getters, fields, typedefs) for package types that none of the three libraries export. Result: **no leaked internal types**, and every exported symbol and public member has a doc comment (the `public_member_api_docs` lint is on, with zero issues). The main library's signatures name some types that only `broker.dart` or `testing.dart` export, on purpose: the test seams (`CloudflareRealtime(mediaBackend:, createBrokerClient:, connectSession:, wrapTrack:)`, the sources' `backend:`, `ParticipantVideoView`'s renderer factories) and the escape hatches to the session layer (`Room.session`, `LocalMediaPublication.publication`, `RemoteTrackPublication.subscription`, `SfuDataChannel.session`). Apps use those members without importing the other library; they import it only to name the type.

## Inventory

Modifiers are shown where a class has them; "–" means a plain class. Events and exceptions are grouped. Everything is in the main library unless marked **(broker)** or **(testing)**.

### Entry point and rooms (`src/room/`)

| Symbol | Kind | Notes |
|---|---|---|
| `CloudflareRealtime` | class | Entry point: `join(roomId, signaling:, participantId:, metadata:, options:)` |
| `BrokerClientFactory`, `SfuSessionConnector` **(testing)** | typedefs | Test seams for `CloudflareRealtime` |
| `Room` | class | The call. Includes `debugSimulateConnectionFailure()` (see below) |
| `Participant` | sealed class | `LocalParticipant`, `RemoteParticipant` |
| `LocalParticipant`, `RemoteParticipant` | classes | |
| `LocalMediaPublication`, `RemoteTrackPublication` | classes | Room-level publications |
| `RemoteTrackLease` | class | Subscription lease |
| `RemoteTrackLayerState` | final class | Layer state for debug UIs |
| `RoomData`, `RemoteDataSubscription` | classes | DataChannels between participants |
| `RoomDataMessage` | final class | |
| `RoomOptions`, `AutoSubscribe`, `ReconnectOptions` | final classes | Options |
| `RoomConnectionState`, `SimulcastLayer`, `KeepScreenAwake` | enums | |
| `ScreenSharePresets` | abstract final class | Static encodings |
| `RoomEvent` | sealed class | 23 final subclasses. **Participant:** `ParticipantJoinedEvent`, `ParticipantLeftEvent`, `ParticipantUpdatedEvent`, `ParticipantConnectionQualityChangedEvent`. **Remote track:** `TrackPublishedEvent`, `TrackUnpublishedEvent`, `TrackMutedEvent`, `TrackSubscribedEvent`, `TrackSubscriptionFailedEvent`. **Local track:** `LocalTrackPublishedEvent`, `LocalTrackUnpublishedEvent`, `LocalTrackStalledEvent`. **Room:** `RoomConnectionStateChangedEvent`, `RoomSessionFailedEvent`, `RoomReconnectingEvent`, `RoomReconnectAttemptEvent`, `RoomReconnectedEvent`, `RoomReconnectFailedEvent`, `RoomAudioInterruptedEvent`, `RoomAudioResumedEvent`, `RoomCameraPausedEvent`, `RoomCameraResumedEvent`, `RoomErrorEvent` |

### Phones: audio, background, system calls (`src/audio/`, `src/background/`, `src/calls/`)

| Symbol | Kind |
|---|---|
| `AudioRoute`, `AudioRouteKind`, `AudioRouteUnavailableException` | final class, enum, final exception |
| `AudioOutputException`, `AudioOutputFailure` | final exception, enum: a refused `Room.setAudioOutputDevice` (any platform), added after the cleanup |
| `CallInterruptionReason`, `CameraPauseReason` | enums |
| `SystemCalls`, `SystemCall`, `VoipPush` | classes (`SystemCalls.debugReset()` is `@visibleForTesting`) |
| `SystemCallsOptions`, `CallHandle` | final classes |
| `CallHandleType`, `SystemCallEndReason`, `SystemCallErrorCode`, `SystemCallState` | enums |
| `SystemCallException` | final exception |
| `SystemCallEvent` | sealed class, with 8 final subclasses (`SystemCallAddedEvent`, `…AnsweredEvent`, `…EndedEvent`, `…HeldEvent`, `…MutedEvent`, `…DtmfEvent`, `…AudioActivatedEvent`, `…AudioDeactivatedEvent`) |

### Rendering (`src/rendering/`)

`ParticipantVideoView` (widget), `RenderableTrack` (final), `VideoViewFit` (enum). **(testing):** `VideoRenderer` (interface), `FlutterWebrtcVideoRenderer`, `VideoRendererFactory` (typedef), `MediaStreamWrapper` (typedef) and `wrapTrackInMediaStream` (function; the default for `CloudflareRealtime(wrapTrack:)`).

### Broker (`src/broker/`)

- **Main library:** `BrokerOptions` (final), `BrokerHeadersProvider` (typedef), and the exceptions: `BrokerException` (sealed) with the final `BrokerUnauthorizedException`, `BrokerForbiddenException`, `SessionGoneException`, `BrokerNetworkException` (→ `BrokerTimeoutException`), `BrokerProtocolException` and `BrokerResponseException`. `SimulcastOrdering` (enum), because `LayerSelectionOptions` uses it.
- **(broker):** `BrokerClient` (interface), `HttpBrokerClient`, `BrokerHeaders` (abstract final, header names), and the wire models, all final: `NewSessionRequest`/`Response`, `SessionState`, `SessionTrackState`, `SessionDataChannelState`, `TracksRequest`/`Response`, `UpdateTracksRequest`, `CloseTracksRequest`, `RenegotiateRequest`/`Response`, `TrackObject`, `TrackResult`, `SimulcastOptions`, `DataChannelsRequest`/`Response`, `EstablishDataChannelsRequest`/`Response`, `DataChannelObject`, `DataChannelResult`, `SessionDescription`, `IceServer`, `IceServersResponse`; the `SfuErrorFields` mixin, and the enums `SdpType`, `TrackLocation`, `ResourceStatus`.

### SFU session (`src/session/`, `src/data/`)

- **Main library** (what the room API shares with the session): `SfuSessionOptions`, `SfuSessionDefaults`, `SendEncoding` (final classes), `SimulcastPresets` (abstract final), `VideoCodec`, `SfuTrackState`, `PeerConnectionFailureKind` (enums); `SfuSessionFailure` (sealed: `SfuPeerConnectionFailed`, `SfuSessionGone`); `SfuSessionException` (sealed) with the final `SfuSessionClosedException`, `SfuSessionFailedException`, `SfuInterruptedException`, `SfuTrackException`, `SfuDataChannelException`, `SfuRequestException`, `SfuProtocolException`; `SfuDataChannel` (sealed: `LocalDataChannel`, `RemoteDataChannel`), `SfuDataChannelState`, `DataChannelProfile`, `DataChannelMessage` (final).
- **(broker):** `SfuSession`, `LocalTrackPublication`, `RemoteTrackSubscription`, `SfuConnectionState`, `PublishOptions` (final), `defaultVideoCodecPreferences()`. `SfuSession.debugSimulateFailure()` (see below).

### Media (`src/media/`)

- Sources: `LocalMediaSource` (abstract; `@protected` hooks for subclasses), `DeviceMediaSource` (abstract), `CameraSource`, `MicrophoneSource`, `ScreenShareSource`, `ScreenSourcePicker`, `MediaDeviceList`; `ScreenPickerState` (final), `MutePolicy`.
- Options: `CameraOptions`, `MicrophoneOptions`, `ScreenShareOptions`, `VideoPreset` (final).
- Types: `MediaDevice`, `CapturedTrack`, `ScreenSource` (final); `MediaDeviceKind`, `CameraFacing`, `MediaPlatform`, `ScreenSourceType`, `ScreenShareEndReason`, `BroadcastSetupProblem` (enums).
- Exceptions: `MediaException` (sealed) → `MediaPermissionDeniedException` (→ `ScreenCapturePermissionException`), `ScreenShareSetupException`, `DevicesExhaustedException`, `MediaCaptureException`, `ScreenSourcesException`, `ScreenSourceNotFoundException`, all final.
- **(testing):** `MediaBackend`, `DesktopCapturerBackend`, `ScreenCaptureServiceBackend`, `BroadcastExtensionBackend` (interfaces), `FlutterWebrtcMediaBackend`, `BroadcastExtensionStatus` (final), `BroadcastExtensionEvent`.

### Signaling (`src/signaling/`)

`Signaling` (interface), `ParticipantState`, `TrackInfo`, `SimulcastInfo` (final), `TrackKind`, `TrackSource`. **(testing):** `InMemorySignaling`, `InMemorySignalingHub`.

### Quality and reconnection (`src/quality/`, `src/reconnect/`)

- Stats (final): `RoomStats`, `ConnectionStats`, `LocalTrackStats`, `OutboundLayerStats`, `RemoteTrackStats`, `IceCandidateStats`; enums `IceCandidateType`, `QualityLimitationReason`.
- Quality: `ConnectionQuality` (enum), `ConnectionQualityOptions`, `QualityThresholds`, `RoomStatsOptions`, `ActiveSpeakerOptions` (final).
- Layers: `LayerSelectionOptions`, `TileDemand`, `LayerPausingOptions` (final), `LayerDemandReporter` (interface), `SimulcastLayerReporter` (widget).
- Reconnection: `BackoffOptions`, `ReconnectTriggerOptions` (final), `ReconnectReason`, `NetworkChangeSource` and `AppLifecycleSource` (interfaces), `FlutterAppLifecycleSource`.

## Changed in the M8 review

- **dartdoc warnings fixed** (16 before, from `dart doc`): three unresolved references (`[close]` on `SfuDataChannelState.interrupted`, `[source]` on `ParticipantVideoView.local`, a reference split over two lines in `RoomData.subscribe`), a Markdown link definition in `VoipPush.supported` that dartdoc turned into a broken link, and eleven README links that pointed at repository files. The README now links to GitHub with absolute URLs, which also work on pub.dev.
- **`public_member_api_docs`** is on in `analysis_options.yaml`. It reported nothing: every public member was already documented.
- **Internal constructors** no longer use private named parameters (`required this._x`), a Dart 3.12 feature, so the SDK floor could go below 3.12. The named arguments callers pass are the same. Affected (all internal or private constructors): `Room._`, `LocalMediaPublication._`, `SfuSession._`, `LocalTrackPublication._`, `RemoteTrackSubscription._`, `RemoteDataChannel._`, `SystemCallAudioBackend`, `RoomAudioLevelSource`, `StatsAudioLevelSource`, `ActiveSpeakerMonitor`, `CallStatsReader`.
- The review itself renamed nothing and changed no modifier; it listed the judgement calls below, which the cleanup then decided.

## The 0.1.0 cleanup: decisions

Breaking, before the first release, with the project owner's approval; the one consumer migrates with [doc/migrating-to-0.1.md](../doc/migrating-to-0.1.md). The member renames were made with an analyzer-based tool (every resolved reference, including overrides in tests and doc-comment references), so nothing was renamed by text matching in code.

### 1. One style for observable state

**Counted** on the public API before the change:

| Style | Pairs | Where |
|---|---|---|
| Stream `x` + value `currentX` | 20 | `Room` (participants, connection state, active speakers, dominant speaker, stats, audio routes), the publications' stats and track, the media sources' tracks and devices, `ScreenSourcePicker.state`, `MediaDeviceList`, `SfuSession.connectionState` |
| ... with `isX` for the value | 2 | `LocalMediaSource.enabled` / `isEnabled`, `broadcasting` / `isBroadcasting` |
| Value `x` + stream `xChanges` | 20 | `Room` (audio playback blocked, audio route, speakerphone, audio interruption, proximity sensor, screen awake, camera pause), `connectionQuality`, `isSpeaking`, `isSpeakingWhileMuted`, `muted`, `pausedLayers`, `layerState`, `SystemCall`, `SystemCalls.calls`, `VoipPush.token` |
| ... with another stream name | 6 | `audioLevel` / `audioLevels` (×2), `state` / `states` (×3), `RemoteTrackSubscription.track` / `trackStream` |

**Decision: a getter `x` for the value now, and `Stream xChanges`** that replays the current value to each new listener, then emits each change (they are all backed by the internal `StateStream`, so the replay was already there). Booleans are `isX` (or `hasX`, `canX`), and the stream drops the `is`: `isMuted` / `mutedChanges`, `isSpeaking` / `speakingChanges`.

**Why:** it was already the larger family (26 against 22), it reads better where apps read state (`room.participants.length`, `if (publication.isMuted)`), and it is how Flutter reads state elsewhere: `ValueListenable.value`, and `StreamBuilder(stream: room.participantsChanges, initialData: room.participants)`. With stream-first names, every synchronous read needs a `current` prefix, and the stream is the one you type less often.

**Applied** to 67 getters on `Room`, `LocalParticipant`, `RemoteParticipant`, `LocalMediaPublication`, `RemoteTrackPublication`, `LocalMediaSource`, `DeviceMediaSource`, `CameraSource`, `ScreenShareSource`, `ScreenSourcePicker`, `MediaDeviceList`, `SfuSession`, `LocalTrackPublication`, `RemoteTrackSubscription`, `SfuDataChannel`, `SystemCall`, `SystemCalls` and `VoipPush`. `MediaDeviceList` gained `audioInputs`, `videoInputs` and `audioOutputs` as lists next to their `…Changes`, and the sealed `Participant` now declares `speakingChanges`, `audioLevel` and `audioLevelChanges`, which both participants had. `CallAudio` (the internal audio-route engine behind `Room`) isn't public and wasn't renamed.

**Not state, so not renamed:** streams of things that happen keep plain plural names (`Room.events`, `SystemCalls.events`, `LocalMediaSource.errors`, `SfuSession.failures`, `ScreenShareSource.ended`, the DataChannels' `messages` and `bufferedAmountLow`, and the `changes` stream of a participant or a publication, which emits the object itself). The interfaces an app implements are feeds into the package, not its state, and keep their names: `Signaling.participants` (renaming it would break every adapter for no gain), `NetworkChangeSource.changes`, `AppLifecycleSource.states`, and the `MediaBackend` parts' `onAdded`/`stopped`/`events`.

**Booleans** on stateful objects were renamed where they lacked a verb, which was cheap: `Room.isAudioPlaybackBlocked`, `isSpeakerphoneOn`, `isProximitySensorActive`, `isKeepingScreenAwake`; `LocalMediaPublication.isMuted`, `RemoteTrackPublication.isMuted`, `SystemCall.isMuted`, `isOutgoing`, `isVideo`; `SystemCalls.isSupported` and `VoipPush.isSupported` (like `ScreenShareSource.isSupported`). Fields of value classes and named parameters keep adjectives, as Effective Dart suggests for parameters and as their JSON does (`TrackInfo.muted`, `AutoSubscribe.audio`, `ReconnectOptions.enabled`). Verb phrases stay (`ownsMediaSource`, `usesSystemPicker`, `hasNegotiated`).

### 2. One suffix: `…Options`

**Counted:** 9 `…Options` (`RoomOptions`, `ReconnectOptions`, `RoomStatsOptions`, `LayerPausingOptions`, `CameraOptions`, `MicrophoneOptions`, `ScreenShareOptions`, `SfuSessionOptions`, `PublishOptions`) against 8 `…Config` (`ActiveSpeakerConfig`, `BackoffConfig`, `BrokerConfig`, `ConnectionQualityConfig`, `LayerSelectionConfig`, `ReconnectTriggerConfig`, `SystemCallsConfig`, and the wire model `SimulcastConfig`). **Decision: `…Options`**, the majority and the suffix of the two classes every app writes (`RoomOptions`, `SfuSessionOptions`). The eight `…Config` classes were renamed, and `HttpBrokerClient(config:)` / `.config` became `options`. `SfuSessionDefaults` keeps its name: it is the session's defaults, held in `SfuSessionOptions.defaults`.

### 3. Event names

Every `RoomEvent` subtype ends in `Event` and starts with what it is about: `Participant…` (a remote participant), `Track…` (a remote track), `LocalTrack…` (a local publication) or `Room…` (the room, its connection, and the device's call audio and camera, which `Room` exposes). Six outliers were renamed: `ConnectionQualityChangedEvent` → `ParticipantConnectionQualityChangedEvent` (it is about a participant, local or remote), `LocalScreenShareStalledEvent` → `LocalTrackStalledEvent` (it carries the publication), `CallInterruptedEvent` / `CallResumedEvent` → `RoomAudioInterruptedEvent` / `RoomAudioResumedEvent` (they match `Room.audioInterruption`), `LocalCameraPausedEvent` / `LocalCameraResumedEvent` → `RoomCameraPausedEvent` / `RoomCameraResumedEvent` (they carry no publication and match `Room.cameraPause`). `RoomReconnectAttemptEvent`, added during the cleanup, already fit. `SystemCallEvent`'s subtypes were already consistent (`SystemCall…Event`).

### 4. Class modifiers

- **`final`:** the options (21 classes), the value types (`ParticipantState`, `TrackInfo`, `SimulcastInfo`, `MediaDevice`, `ScreenSource`, `CapturedTrack`, `RenderableTrack`, `AudioRoute`, `CallHandle`, `ScreenPickerState`, `RemoteTrackLayerState`, `TileDemand`, `BroadcastExtensionStatus`, `RoomDataMessage`; `DataChannelMessage` already was), the six stats classes and the 23 wire models. All have public constructors, so tests build them instead of subclassing; `RoomDataMessage` got one (it only had a private one). Nothing in the tests, the example or the integration tests extended or implemented them.
- **`sealed`:** `BrokerException` and `SfuSessionException`, like `MediaException`, `RoomEvent`, `SystemCallEvent`, `SfuSessionFailure`, `SfuDataChannel` and `Participant` already were, so apps can `switch` over them exhaustively (`test/api_shape_test.dart` pins it). Every subtype is `final`. Both roots used to be thrown directly, so each got a final subtype for those cases: `BrokerResponseException` (any other error response: a non-2xx status other than 401/403/410, or an SFU error in a 2xx `sessions/new` body), `SfuInterruptedException` (unpublished, closed, interrupted or moved before the operation completed) and `SfuProtocolException` (an unusable answer from the SFU). `sealed` needs every subtype in the root's library: `SfuDataChannelException` lived in the DataChannel library (`data_channel_manager.dart` and its parts) and moved to `sfu_session_events.dart`, next to the other session exceptions; it only holds strings, so no `part` restructuring was needed. `AudioRouteUnavailableException` and `SystemCallException` are `final`, and so is `AudioOutputException`, added after the cleanup for a refused output device (`docs/design.md` §4.3; not a `MediaException`, which is the capture side's family).
- **Events** are `final` under their sealed roots (they already were).
- **Left open, for mocks** (`class MockRoom extends Mock implements Room`): `CloudflareRealtime`, `Room`, `LocalParticipant`, `RemoteParticipant`, `LocalMediaPublication`, `RemoteTrackPublication`, `RemoteTrackLease`, `RoomData`, `RemoteDataSubscription`, the media sources, `MediaDeviceList`, `ScreenSourcePicker`, `SystemCalls`, `SystemCall`, `VoipPush`, `SfuSession`, `LocalTrackPublication`, `RemoteTrackSubscription`. Mocks implement them, which `final`, `base` or `sealed` would forbid outside the package; most also have private constructors, so they can't be extended anyway. The interfaces apps implement are `abstract interface` (`Signaling`, `BrokerClient`, `MediaBackend` and its parts, `VideoRenderer`, `NetworkChangeSource`, `AppLifecycleSource`, `LayerDemandReporter`).
- **Left open on purpose:** the default implementations of those interfaces (`HttpBrokerClient`, `FlutterWebrtcMediaBackend`, `FlutterWebrtcVideoRenderer`, `FlutterAppLifecycleSource`, `InMemorySignaling`, `InMemorySignalingHub`), which an app may wrap or extend (a logging broker client, a backend that overrides one capture call), and the widgets (`ParticipantVideoView`, `SimulcastLayerReporter`).

### 5. Three libraries

- **`cloudflare_realtime.dart`** keeps what apps use.
- **`broker.dart`** holds the plumbing: `BrokerClient`, `HttpBrokerClient`, `BrokerHeaders` and the wire models, which only a custom `BrokerClient` needs, and **the low-level `SfuSession`** with `LocalTrackPublication`, `RemoteTrackSubscription`, `SfuConnectionState`, `PublishOptions` and `defaultVideoCodecPreferences()`. Why the session moved: apps that use `Room` reach a session only through `Room.session` (and `LocalMediaPublication.publication`, `RemoteTrackPublication.subscription`), use it there without naming its type, and rarely touch it otherwise; and the session's `LocalTrackPublication` next to the room's `LocalMediaPublication` in one import was the API's most confusing pair of names (the review's call 4). What the room API shares with the session stays in the main library rather than being exported twice: `SfuSessionOptions` and `SfuSessionDefaults` (`RoomOptions.sessionOptions`), `SfuTrackState` (`RemoteTrackPublication.subscriptionState`), `SendEncoding`, `SimulcastPresets` and `VideoCodec` (`publishCamera`), the failures and exceptions (`Room.failure`, `RoomSessionFailedEvent`, errors from publishing), the DataChannels (`Room.data` returns them), `BrokerOptions` and the broker's exceptions, and `SimulcastOrdering` (`LayerSelectionOptions`).
- **`testing.dart`** holds the test seams: `MediaBackend` and its platform parts with `FlutterWebrtcMediaBackend` and `BroadcastExtensionStatus`/`Event`, `VideoRenderer` with `FlutterWebrtcVideoRenderer` and `VideoRendererFactory`, `MediaStreamWrapper` with `wrapTrackInMediaStream`, `BrokerClientFactory`, `SfuSessionConnector`, and `InMemorySignaling` with its hub. The example app imports it for its demo mode (in-memory signaling and an injectable media backend), which is what it is for. `NetworkChangeSource` and `AppLifecycleSource` stay in the main library: apps plug their connectivity source into the first, and the two belong together. `SystemCalls.debugReset()` is a member and stays `@visibleForTesting`.
- The main import went from 213 symbols to 165.

### 6. Left as they were

- **`LocalMediaPublication`** keeps its name, and **`ParticipantVideoView.defaultRendererFactory`** stays a static (decided before the cleanup).
- **`RemoteTrackPublication.currentRid`** and **`RemoteTrackLayerState.currentRid`**: here "current" means the rid the live pull asks for, as opposed to `targetRid`, not the value of a stream.
- **File names** under `lib/src/` (`broker_config.dart`, `active_speaker_config.dart`) still say "config"; they are internal.
- **Debug hooks** (below).

## Kept on purpose

- **Debug hooks.** `Room.debugSimulateConnectionFailure()` and `SfuSession.debugSimulateFailure()` stay public and unannotated: the example app's "simulate network drop" uses them in normal builds, and the integration tests too, so `@visibleForTesting` would flag legitimate demo use. Their docs say "debug and demo only" and that they exercise the real failure path; the `debug` prefix follows Flutter's convention. `SystemCalls.debugReset()` stays `@visibleForTesting`: only tests need to forget the singleton.
- **Test seams.** `CloudflareRealtime`'s `mediaBackend`, `createBrokerClient`, `connectSession` and `wrapTrack` parameters, the `MediaBackend` family, `VideoRenderer` and `ParticipantVideoView.defaultRendererFactory` are public because apps need them to test their own code without native WebRTC (README, "Testing your app"). Their types are in `testing.dart`.
- **The low-level layers.** `SfuSession` (with its publications, subscriptions and DataChannels) and the broker wire models are public, in `broker.dart`, for apps that need something `Room` doesn't do, and for custom `BrokerClient`s. `Room.session` exposes the current session.
- **`@protected` members** on `LocalMediaSource` and `DeviceMediaSource` are hooks for subclasses (custom capture through `publishMediaSource`), correctly annotated.

## The M8 review's open judgement calls, and what became of them

1. **Class modifiers:** decided, §4 above.
2. **Two naming styles for observable state:** decided, §1 (one style, no deprecated aliases: nothing was released).
3. **`…Options` and `…Config`:** decided, §2.
4. **Publication names:** kept (`LocalMediaPublication` at room level); the session's `LocalTrackPublication` moved to `broker.dart`, out of the main import (§5).
5. **Event names:** decided, §3.
6. **A second library for the plumbing:** done, two (§5).
7. **`ParticipantVideoView.defaultRendererFactory`:** kept as a static.

## SDK constraint

`sdk: ^3.11.0`, `flutter: ">=3.41.0"` (was `^3.13.0` / `>=3.47.0`), the lowest the code allows:

- **`flutter_webrtc` 1.6.2** allows Dart 3.3 and Flutter 1.22; `dart_webrtc` 1.8 Dart 3.3; `http` 1.6, `web` 1.1, `clock` 1.1 and `collection` 1.19 Dart 3.4. None of them sets the floor. (`flutter_lints` 6, a dev dependency, needs Dart 3.8.)
- **Language features:** null-aware collection elements (Dart 3.8) and wildcard variables (3.7) are used throughout. Private named parameters (3.12) were rewritten (above).
- **Flutter APIs:** `TickerMode.valuesOf` (used by `SimulcastLayerReporter` to treat views in a disabled `TickerMode` as hidden) first shipped in Flutter 3.41.0. Before it, only `TickerMode.of` exists, which is deprecated since; using it would buy Flutter 3.32–3.38 at the cost of breaking when Flutter removes it. Flutter 3.38.0 also shipped a pre-release Dart (`3.10.0-290.4.beta`).
- **Android build:** the plugin was written for AGP 9's built-in Kotlin (Flutter 3.47's template). The app templates of older Flutter releases use AGP 8 with the Kotlin Gradle plugin, where its `kotlin { }` block didn't compile. It now applies the Kotlin Gradle plugin itself when built-in Kotlin is off (AGP 8, or AGP 9 with `android.builtInKotlin=false`), the rule `flutter_webrtc` uses, and sets the JVM target on the compile tasks. Flutter's migration guide asks plugins that rely on built-in Kotlin to require Flutter 3.44; this keeps 3.41 working instead.
- **iOS:** `Package.swift` depends on the `FlutterFramework` package of recent Flutter releases; with Swift Package Manager on an older Flutter, use CocoaPods (the podspec is unaffected). Not built on a Mac with Flutter 3.41.

**Checked** in Linux containers (the Flutter SDK cloned at the tag, and the `ghcr.io/cirruslabs/flutter` images for Android builds):

| Flutter | Result |
|---|---|
| 3.41.0 (Dart 3.11.0) | `flutter pub get` resolves; `flutter analyze lib test` passes (one `use_null_aware_elements` info, a false positive of that SDK's lint on an `if case … when`) and all `flutter test` tests pass. `flutter pub downgrade` resolves (`flutter_webrtc` 1.6.2, `dart_webrtc` 1.8.0, `http` 1.6.0, `web` 1.1.0, `clock` 1.1.2, `collection` 1.19.1) and `flutter analyze` passes with no issues; the tests then don't compile, because of `file` 6.0.0 and `platform` 3.0.0, old transitive lower bounds in `flutter_webrtc`'s dependency tree, not this package's constraints. A new app depending on the package builds an Android debug APK with 3.41.0's template (AGP 8, Kotlin Gradle plugin) |
| 3.38.1, 3.35.0 | `TickerMode.valuesOf` missing: analysis errors |
| 3.32.0 | `TickerMode.valuesOf` missing; before the Gradle change, the Android build also failed (`kotlin { }` unresolved under AGP 8.7) |
| 3.47.3 (CI, Windows) | `flutter analyze`, `flutter test`, the example's Android debug build with `android.builtInKotlin=false` (the template's setting) and with `true` |

## dartdoc and pana

- **`dart doc` in the SDK crashes locally.** The `dart doc` of Dart 3.13 (dartdoc 9.0.6) stops before writing anything, in `_stripDocImports`, on four library comments of `package:platform` 3.2.0 (a transitive dependency through `flutter_webrtc` → `path_provider`); on Windows with a CRLF checkout of the Flutter SDK it also trips on Flutter's own comments. A copy patched to skip those comments documented the package with the 16 warnings above, then with none after the fixes.
- **The dartdoc that pana activates from pub.dev works:** in pana (Flutter 3.47.3, Linux) it documented the package with **0 warnings and 0 errors**, and 1436 of 1437 API elements had doc comments (the missing one, `InMemorySignalingHub`'s implicit constructor, is now documented). pub.dev builds the API reference the same way. After the 0.1.0 cleanup it documented the three libraries with **0 warnings and 0 errors**, and 1463 of 1463 API elements have doc comments.
- **pana: 135 / 160** on the working copy (Flutter 3.47.3, Linux, `publish_to` removed in a copy), the same before and after the 0.1.0 cleanup:

  | Section | Points | Notes |
  |---|---|---|
  | Follow Dart file conventions | 15 / 30 | `pubspec.yaml` 0/10: the repository's `pubspec.yaml` on `main` still has `publish_to`, and the `documentation` URL (`doc/`) isn't on GitHub yet; both pass once the release commit is pushed. `CHANGELOG.md` 0/5: no `0.0.1` entry; passes once the version is 0.1.0 with a `## 0.1.0` heading. README 5/5, license 10/10 |
  | Provide documentation | 20 / 20 | |
  | Platform support | 10 / 20 | Android, iOS, macOS, Windows and web detected (Linux isn't supported). Not Wasm-compatible by pana's static check: `flutter_webrtc` imports `package:logger`, which imports `dart:io`. The package does run as Wasm in Chrome and Firefox (roadmap M13); only `flutter_webrtc` can fix the check |
  | Pass static analysis | 50 / 50 | |
  | Support up-to-date dependencies | 40 / 40 | including the downgrade check |

  Expected after publishing 0.1.0 from a pushed release commit: **150 / 160**; the last 10 depend on `flutter_webrtc`'s Wasm compatibility.
