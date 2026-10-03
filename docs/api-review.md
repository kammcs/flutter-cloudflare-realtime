# API review for the first pub.dev release (M8)

October 2026, before 0.1.0. The public API is everything `lib/cloudflare_realtime.dart` exports: **212 symbols**. This page lists them, records what the review changed, and lists the judgement calls left open because they would break code that the first consumer already writes against the API.

How the inventory was made: an `analyzer`-based script read the barrel's export namespace (names, kinds, class modifiers, `@visibleForTesting`/`@protected` members, documentation) and checked every public signature (supertypes, constructors, methods, getters, fields, typedefs) for package types that the barrel doesn't export. Result: **no leaked internal types**, and every exported symbol and public member has a doc comment (the `public_member_api_docs` lint is now on, with zero issues).

## Inventory

Modifiers are shown where a class has them; "–" means a plain class. Events and exceptions are grouped.

### Entry point and rooms (`src/room/`)

| Symbol | Kind | Notes |
|---|---|---|
| `CloudflareRealtime` | class | Entry point: `join(roomId, signaling:, participantId:, metadata:, options:)` |
| `BrokerClientFactory`, `SfuSessionConnector` | typedefs | Test seams for `CloudflareRealtime` |
| `Room` | class | The call. Includes `debugSimulateConnectionFailure()` (see below) |
| `Participant` | sealed class | `LocalParticipant`, `RemoteParticipant` |
| `LocalParticipant`, `RemoteParticipant` | classes | |
| `LocalMediaPublication`, `RemoteTrackPublication` | classes | Room-level publications |
| `RemoteTrackLease`, `RemoteTrackLayerState` | classes | Subscription lease; layer state for debug UIs |
| `RoomData`, `RemoteDataSubscription`, `RoomDataMessage` | classes | DataChannels between participants |
| `RoomOptions`, `AutoSubscribe`, `ReconnectOptions` | classes | Options |
| `RoomConnectionState`, `SimulcastLayer` | enums | |
| `ScreenSharePresets` | abstract final class | Static encodings |
| `RoomEvent` | sealed class | 22 final subclasses: `ParticipantJoinedEvent`, `ParticipantLeftEvent`, `ParticipantUpdatedEvent`, `TrackPublishedEvent`, `TrackUnpublishedEvent`, `TrackMutedEvent`, `TrackSubscribedEvent`, `TrackSubscriptionFailedEvent`, `LocalTrackPublishedEvent`, `LocalTrackUnpublishedEvent`, `LocalScreenShareStalledEvent`, `LocalCameraPausedEvent`, `LocalCameraResumedEvent`, `CallInterruptedEvent`, `CallResumedEvent`, `ConnectionQualityChangedEvent`, `RoomConnectionStateChangedEvent`, `RoomReconnectingEvent`, `RoomReconnectedEvent`, `RoomReconnectFailedEvent`, `RoomSessionFailedEvent`, `RoomErrorEvent` |

### Phones: audio, background, system calls (`src/audio/`, `src/background/`, `src/calls/`)

| Symbol | Kind |
|---|---|
| `AudioRoute`, `AudioRouteKind`, `AudioRouteUnavailableException` | class, enum, exception |
| `CallInterruptionReason`, `CameraPauseReason` | enums |
| `SystemCalls`, `SystemCall`, `VoipPush`, `SystemCallsConfig`, `CallHandle` | classes (`SystemCalls.debugReset()` is `@visibleForTesting`) |
| `CallHandleType`, `SystemCallEndReason`, `SystemCallErrorCode`, `SystemCallState` | enums |
| `SystemCallException` | exception |
| `SystemCallEvent` | sealed class, with 8 final subclasses (`SystemCallAddedEvent`, `…AnsweredEvent`, `…EndedEvent`, `…HeldEvent`, `…MutedEvent`, `…DtmfEvent`, `…AudioActivatedEvent`, `…AudioDeactivatedEvent`) |

### Rendering (`src/rendering/`)

`ParticipantVideoView` (widget), `RenderableTrack`, `VideoRenderer` (interface), `FlutterWebrtcVideoRenderer`, `VideoRendererFactory` (typedef), `VideoViewFit` (enum), `MediaStreamWrapper` (typedef) and `wrapTrackInMediaStream` (function; the default for `CloudflareRealtime(wrapTrack:)`).

### Broker client (`src/broker/`)

- **Client:** `BrokerClient` (interface), `HttpBrokerClient`, `BrokerConfig`, `BrokerHeadersProvider` (typedef), `BrokerHeaders` (abstract final, header names).
- **Exceptions:** `BrokerException` and its subclasses `BrokerUnauthorizedException`, `BrokerForbiddenException`, `SessionGoneException`, `BrokerNetworkException` (→ `BrokerTimeoutException`), `BrokerProtocolException`.
- **Wire models** (needed by anyone implementing `BrokerClient`): `NewSessionRequest`/`Response`, `SessionState`, `SessionTrackState`, `SessionDataChannelState`, `TracksRequest`/`Response`, `UpdateTracksRequest`, `CloseTracksRequest`, `RenegotiateRequest`/`Response`, `TrackObject`, `TrackResult`, `SimulcastConfig`, `DataChannelsRequest`/`Response`, `EstablishDataChannelsRequest`/`Response`, `DataChannelObject`, `DataChannelResult`, `SessionDescription`, `IceServer`, `IceServersResponse`, the `SfuErrorFields` mixin, and the enums `SdpType`, `TrackLocation`, `ResourceStatus`, `SimulcastOrdering`.

### SFU session (`src/session/`, `src/data/`)

- `SfuSession`, `SfuSessionOptions`, `SfuSessionDefaults`, `PublishOptions`, `SendEncoding`, `SimulcastPresets` (abstract final), `VideoCodec`, `defaultVideoCodecPreferences()`.
- `LocalTrackPublication`, `RemoteTrackSubscription`, `SfuTrackState`, `SfuConnectionState`, `PeerConnectionFailureKind`.
- `SfuSessionFailure` (sealed: `SfuPeerConnectionFailed`, `SfuSessionGone`); exceptions `SfuSessionException` → `SfuSessionClosedException`, `SfuSessionFailedException`, `SfuTrackException`, `SfuRequestException`, `SfuDataChannelException`.
- `SfuDataChannel` (sealed: `LocalDataChannel`, `RemoteDataChannel`), `SfuDataChannelState`, `DataChannelProfile`, `DataChannelMessage`.
- `SfuSession.debugSimulateFailure()` (see below).

### Media (`src/media/`)

- Sources: `LocalMediaSource` (abstract; `@protected` hooks for subclasses), `DeviceMediaSource` (abstract), `CameraSource`, `MicrophoneSource`, `ScreenShareSource`, `ScreenSourcePicker`, `ScreenPickerState`, `MediaDeviceList`, `MutePolicy`.
- Options: `CameraOptions`, `MicrophoneOptions`, `ScreenShareOptions`, `VideoPreset`.
- Types: `MediaDevice`, `MediaDeviceKind`, `CameraFacing`, `CapturedTrack`, `MediaPlatform`, `ScreenSource`, `ScreenSourceType`, `ScreenShareEndReason`.
- Backends (seams for tests and other capture paths): `MediaBackend`, `DesktopCapturerBackend`, `ScreenCaptureServiceBackend`, `BroadcastExtensionBackend` (interfaces), `FlutterWebrtcMediaBackend`, `BroadcastExtensionStatus`, `BroadcastExtensionEvent`, `BroadcastSetupProblem`.
- Exceptions: `MediaException` (sealed) → `MediaPermissionDeniedException` (→ `ScreenCapturePermissionException`), `ScreenShareSetupException`, `DevicesExhaustedException`, `MediaCaptureException`, `ScreenSourcesException`, `ScreenSourceNotFoundException`, all final.

### Signaling (`src/signaling/`)

`Signaling` (interface), `ParticipantState`, `TrackInfo`, `SimulcastInfo`, `TrackKind`, `TrackSource`, `InMemorySignaling`, `InMemorySignalingHub`.

### Quality and reconnection (`src/quality/`, `src/reconnect/`)

- Stats: `RoomStats`, `ConnectionStats`, `LocalTrackStats`, `OutboundLayerStats`, `RemoteTrackStats`, `IceCandidateStats`, `IceCandidateType`, `QualityLimitationReason`.
- Quality: `ConnectionQuality`, `ConnectionQualityConfig`, `QualityThresholds`, `RoomStatsOptions`, `ActiveSpeakerConfig`.
- Layers: `LayerSelectionConfig`, `TileDemand`, `LayerDemandReporter` (interface), `SimulcastLayerReporter` (widget), `LayerPausingOptions`.
- Reconnection: `BackoffConfig`, `ReconnectTriggerConfig`, `ReconnectReason`, `NetworkChangeSource` and `AppLifecycleSource` (interfaces), `FlutterAppLifecycleSource`.

## Changed in this review

- **dartdoc warnings fixed** (16 before, from `dart doc`): three unresolved references (`[close]` on `SfuDataChannelState.interrupted`, `[source]` on `ParticipantVideoView.local`, a reference split over two lines in `RoomData.subscribe`), a Markdown link definition in `VoipPush.supported` that dartdoc turned into a broken link, and eleven README links that pointed at repository files. The README now links to GitHub with absolute URLs, which also work on pub.dev.
- **`public_member_api_docs`** is on in `analysis_options.yaml`. It reported nothing: every public member was already documented.
- **No exported symbol was removed or renamed**, and no class modifier changed: see the open calls.
- **Internal constructors** no longer use private named parameters (`required this._x`), a Dart 3.12 feature, so the SDK floor could go below 3.12. The named arguments callers pass are the same. Affected (all internal or private constructors): `Room._`, `LocalMediaPublication._`, `SfuSession._`, `LocalTrackPublication._`, `RemoteTrackSubscription._`, `RemoteDataChannel._`, `SystemCallAudioBackend`, `RoomAudioLevelSource`, `StatsAudioLevelSource`, `ActiveSpeakerMonitor`, `CallStatsReader`.

## Kept on purpose

- **Debug hooks.** `Room.debugSimulateConnectionFailure()` and `SfuSession.debugSimulateFailure()` stay public and unannotated: the example app's "simulate network drop" uses them in normal builds, and the integration tests too, so `@visibleForTesting` would flag legitimate demo use. Their docs say "debug and demo only" and that they exercise the real failure path; the `debug` prefix follows Flutter's convention. `SystemCalls.debugReset()` stays `@visibleForTesting`: only tests need to forget the singleton.
- **Test seams.** `CloudflareRealtime`'s `mediaBackend`, `createBrokerClient`, `connectSession` and `wrapTrack` parameters, the `MediaBackend` family, `VideoRenderer` and `ParticipantVideoView.defaultRendererFactory` are public because apps need them to test their own code without native WebRTC (README, "Testing your app").
- **The low-level layers.** `SfuSession` (with its publications, subscriptions and DataChannels) and the broker wire models are public for apps that need something `Room` doesn't do, and for custom `BrokerClient`s. `Room.session` exposes the current session.
- **`@protected` members** on `LocalMediaSource` and `DeviceMediaSource` are hooks for subclasses (custom capture through `publishMediaSource`), correctly annotated.

## Open judgement calls (not changed)

Each of these would break code that compiles today. They are cheapest to do before 0.1.0, or else in a planned 0.2.0; the first consumer's code decides.

1. **Class modifiers.** Most classes have none, so apps can `implements` and `extends` them. That keeps mocking easy (`class MockRoom extends Mock implements Room` with mocktail), which matters for `Room`, `LocalParticipant`, `RemoteParticipant`, the publications, `SfuSession` and `SystemCalls`; keep those open. Candidates for `final`: the value types (the `*Options`/`*Config` classes, `ParticipantState`, `TrackInfo`, `SimulcastInfo`, `MediaDevice`, `ScreenSource`, `AudioRoute`, `CallHandle`), the stats snapshots and the broker wire models. Candidates for `sealed`: `BrokerException` (exhaustive `switch` over broker errors) and `SfuSessionException`. Making them `final` later is a breaking change, so decide before 1.0.
2. **Two naming styles for observable state.** Some state is a stream plus a `current…` getter (`participants` / `currentParticipants`, `activeSpeakers`, `dominantSpeaker`, `connectionState`, `audioRoutes`, `stats`, `track`, `devices`); other state is a getter plus a `…Changes` stream (`audioPlaybackBlocked` / `audioPlaybackBlockedChanges`, `connectionQuality`, `muted`, `isSpeaking` / `speakingChanges`, `cameraPause`, `audioInterruption`, `proximitySensorActive`, `speakerphone`, `pausedLayers`, `currentAudioRoute` / `audioRouteChanges`). Suggestion for 1.0: lists and snapshots keep the first style, single values the second, with deprecated aliases for a release.
3. **`…Options` and `…Config`.** `RoomOptions`, `ReconnectOptions`, `RoomStatsOptions`, `LayerPausingOptions`, `CameraOptions`, `SfuSessionOptions` against `BackoffConfig`, `ReconnectTriggerConfig`, `ActiveSpeakerConfig`, `LayerSelectionConfig`, `ConnectionQualityConfig`, `SystemCallsConfig`, `BrokerConfig`. One suffix would read better; renaming is breaking.
4. **Publication names.** The room's local publication is `LocalMediaPublication` because the session layer already has `LocalTrackPublication`; the room's remote one is `RemoteTrackPublication`, and the session's `RemoteTrackSubscription`. A cleaner set would be `LocalTrackPublication` / `RemoteTrackPublication` at room level and `Sfu…` names at session level.
5. **Event names.** Room-wide events mix prefixes: `RoomReconnectingEvent`, `RoomErrorEvent` and `RoomConnectionStateChangedEvent` against `CallInterruptedEvent`, `ConnectionQualityChangedEvent` and `LocalCameraPausedEvent`. Harmless, but worth one rule before 1.0.
6. **A second library for the plumbing.** The barrel exports 212 symbols, about 40 of them broker wire models and media backends that most apps never touch. They could move to `package:cloudflare_realtime/broker.dart` and `…/testing.dart`. That would break imports of custom `BrokerClient`s and test fakes.
7. **`ParticipantVideoView.defaultRendererFactory`** is a mutable static (global state for tests). An `InheritedWidget` or a `CloudflareRealtime` parameter would scope it; it works as is.

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
- **The dartdoc that pana activates from pub.dev works:** in pana (Flutter 3.47.3, Linux) it documented the package with **0 warnings and 0 errors**, and 1436 of 1437 API elements had doc comments (the missing one, `InMemorySignalingHub`'s implicit constructor, is now documented). pub.dev builds the API reference the same way.
- **pana: 135 / 160** on the working copy (Flutter 3.47.3, Linux, `publish_to` removed in a copy):

  | Section | Points | Notes |
  |---|---|---|
  | Follow Dart file conventions | 15 / 30 | `pubspec.yaml` 0/10: the repository's `pubspec.yaml` on `main` still has `publish_to`, and the `documentation` URL (`doc/`) isn't on GitHub yet; both pass once the release commit is pushed. `CHANGELOG.md` 0/5: no `0.0.1` entry; passes once the version is 0.1.0 with a `## 0.1.0` heading. README 5/5, license 10/10 |
  | Provide documentation | 20 / 20 | |
  | Platform support | 10 / 20 | Android, iOS, macOS, Windows and web detected (Linux isn't supported). Not Wasm-compatible by pana's static check: `flutter_webrtc` imports `package:logger`, which imports `dart:io`. The package does run as Wasm in Chrome and Firefox (roadmap M13); only `flutter_webrtc` can fix the check |
  | Pass static analysis | 50 / 50 | |
  | Support up-to-date dependencies | 40 / 40 | including the downgrade check |

  Expected after publishing 0.1.0 from a pushed release commit: **150 / 160**; the last 10 depend on `flutter_webrtc`'s Wasm compatibility.
