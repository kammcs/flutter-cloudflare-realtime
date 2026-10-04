/// Unofficial Flutter client for the Cloudflare Realtime SFU: rooms,
/// participants, publishing, rendering, signaling, call audio and quality.
///
/// This is the library apps import. Two more libraries hold what most apps
/// never touch:
///
/// - `package:cloudflare_realtime/broker.dart`: the plumbing under `Room`,
///   for a custom `BrokerClient` or direct use of the SFU session (the
///   broker client, the SFU API's wire models and `SfuSession`).
/// - `package:cloudflare_realtime/testing.dart`: seams for testing an app
///   without native WebRTC (media and renderer backends, factories, and
///   in-memory signaling).
///
/// See `docs/design.md` for the architecture.
library;

// Entry point and rooms (design.md §4.3, §11).
export 'src/room/cloudflare_realtime.dart' show CloudflareRealtime;
export 'src/room/room.dart' hide joinRoom;
export 'src/room/room_options.dart';
export 'src/room/screen_share_presets.dart';

// A debug aid: timing platform calls and event-loop gaps
// (CloudflareRealtime.debugPlatformCallTiming; design.md §4.2).
export 'src/diagnostics/platform_call_timing.dart'
    show
        EventLoopGapEvent,
        PlatformCall,
        PlatformCallAnsweredEvent,
        PlatformCallTimingBinding,
        PlatformCallTimingEvent,
        PlatformCallTimingOptions,
        flutterWebrtcMethodChannel;

// Call audio routing on phones (design.md §4.6), and a refused output
// device elsewhere (Room.setAudioOutputDevice, §4.3).
export 'src/audio/audio_output_exception.dart'
    show AudioOutputException, AudioOutputFailure;
export 'src/audio/audio_route.dart' show AudioRoute, AudioRouteKind;
export 'src/audio/call_audio.dart' show AudioRouteUnavailableException;

// Calls outside the foreground: interruptions, the camera paused by the
// system, the background service and the proximity sensor (design.md §4.7).
export 'src/audio/call_interruption.dart' show CallInterruptionReason;
export 'src/background/camera_pause.dart' show CameraPauseReason;

// System calls: CallKit, PushKit and Android Telecom (design.md §4.8).
export 'src/calls/system_call_types.dart'
    show
        CallHandle,
        CallHandleType,
        SystemCallEndReason,
        SystemCallErrorCode,
        SystemCallException,
        SystemCallState,
        SystemCallsOptions;
export 'src/calls/system_calls.dart'
    show
        SystemCall,
        SystemCallAddedEvent,
        SystemCallAnsweredEvent,
        SystemCallAudioActivatedEvent,
        SystemCallAudioDeactivatedEvent,
        SystemCallDtmfEvent,
        SystemCallEndedEvent,
        SystemCallEvent,
        SystemCallHeldEvent,
        SystemCallMutedEvent,
        SystemCalls,
        VoipPush;

// Rendering (design.md §4.3).
export 'src/rendering/participant_video_view.dart' show ParticipantVideoView;
export 'src/rendering/renderable_track.dart' show RenderableTrack;
export 'src/rendering/video_renderer.dart' show VideoViewFit;

// Broker options and errors (design.md §4.1, §5). The client and the wire
// models are in broker.dart.
export 'src/broker/broker_config.dart'
    show BrokerHeadersProvider, BrokerOptions;
export 'src/broker/broker_exception.dart';
// The SFU's simulcast fallback order, which LayerSelectionOptions sets.
export 'src/broker/models/tracks.dart' show SimulcastOrdering;

// What the room API shares with the SFU session (design.md §4.2): session
// options, send encodings and codecs, track states, session failures and
// errors. `SfuSession` itself and its publications are in broker.dart.
export 'src/session/publish_options.dart'
    show SendEncoding, SfuSessionDefaults, SimulcastPresets, VideoCodec;
export 'src/session/sfu_session.dart' show SfuSessionOptions, SfuTrackState;
export 'src/session/sfu_session_events.dart' hide SfuConnectionState;

// DataChannels (design.md §9).
export 'src/data/data.dart';

// Media: capture, devices and screen share (design.md §4.5, §10).
export 'src/media/constraints.dart'
    show CameraOptions, MicrophoneOptions, ScreenShareOptions, VideoPreset;
export 'src/media/device_media_source.dart'
    show CameraSource, DeviceMediaSource, MicrophoneSource;
export 'src/media/local_media_source.dart' show LocalMediaSource, MutePolicy;
export 'src/media/media_backend.dart' show BroadcastSetupProblem;
export 'src/media/media_device_list.dart' show MediaDeviceList;
export 'src/media/media_errors.dart'
    show
        DevicesExhaustedException,
        MediaCaptureException,
        MediaException,
        MediaPermissionDeniedException,
        ScreenCapturePermissionException,
        ScreenShareSetupException,
        ScreenSourceNotFoundException,
        ScreenSourcesException;
export 'src/media/media_types.dart'
    show
        CameraFacing,
        CapturedTrack,
        MediaDevice,
        MediaDeviceKind,
        MediaPlatform,
        ScreenGeometry,
        ScreenSource,
        ScreenSourceType;
export 'src/media/screen_share_source.dart'
    show ScreenShareEndReason, ScreenShareSource;
export 'src/media/screen_source_picker.dart'
    show ScreenPickerState, ScreenSourcePicker;

// Signaling (design.md §4.4). InMemorySignaling is in testing.dart.
export 'src/signaling/participant_state.dart'
    show ParticipantState, SimulcastInfo, TrackInfo, TrackKind, TrackSource;
export 'src/signaling/signaling.dart' show Signaling;

// Quality: active speaker, simulcast layer selection, typed stats and
// connection quality (design.md §6, §7, §7.1).
// The detectors, the stats poller and the layer controller stay internal:
// the Room owns them and exposes their results.
export 'src/quality/active_speaker_config.dart' show ActiveSpeakerOptions;
export 'src/quality/call_stats.dart';
export 'src/quality/connection_quality.dart'
    show
        ConnectionQuality,
        ConnectionQualityOptions,
        QualityThresholds,
        RoomStatsOptions;
export 'src/quality/layer_pausing.dart' show LayerPausingOptions;
export 'src/quality/layer_selection.dart'
    show LayerSelectionOptions, TileDemand;
export 'src/quality/layer_selection_controller.dart' show LayerDemandReporter;
export 'src/quality/simulcast_layer_reporter.dart' show SimulcastLayerReporter;

// Reconnection tuning and event sources (design.md §8). The decision logic
// stays internal.
export 'src/reconnect/app_lifecycle_source.dart'
    show AppLifecycleSource, FlutterAppLifecycleSource;
export 'src/reconnect/backoff.dart' show BackoffOptions;
export 'src/reconnect/network_change_source.dart' show NetworkChangeSource;
export 'src/reconnect/reconnect_trigger.dart'
    show ReconnectReason, ReconnectTriggerOptions;
