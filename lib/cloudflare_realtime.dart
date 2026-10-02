/// Unofficial Flutter client for the Cloudflare Realtime SFU.
///
/// See `docs/design.md` for the architecture.
library;

// Entry point and rooms (design.md §4.3, §11).
export 'src/room/cloudflare_realtime.dart'
    show BrokerClientFactory, CloudflareRealtime, SfuSessionConnector;
export 'src/room/room.dart' hide joinRoom;
export 'src/room/room_options.dart';
export 'src/room/screen_share_presets.dart';

// Call audio routing on phones (design.md §4.6).
export 'src/audio/audio_route.dart' show AudioRoute, AudioRouteKind;
export 'src/audio/call_audio.dart' show AudioRouteUnavailableException;

// Rendering (design.md §4.3).
export 'src/rendering/participant_video_view.dart' show ParticipantVideoView;
export 'src/rendering/renderable_track.dart'
    show MediaStreamWrapper, RenderableTrack, wrapTrackInMediaStream;
export 'src/rendering/video_renderer.dart'
    show
        FlutterWebrtcVideoRenderer,
        VideoRenderer,
        VideoRendererFactory,
        VideoViewFit;

// Broker client (design.md §4.1, §5).
export 'src/broker/broker.dart';

// SFU session (design.md §4.2).
export 'src/session/session.dart';

// DataChannels (design.md §9).
export 'src/data/data.dart';

// Media: capture, devices and screen share (design.md §4.5, §10).
export 'src/media/constraints.dart'
    show CameraOptions, MicrophoneOptions, ScreenShareOptions, VideoPreset;
export 'src/media/device_media_source.dart'
    show CameraSource, DeviceMediaSource, MicrophoneSource;
export 'src/media/flutter_webrtc_media_backend.dart'
    show FlutterWebrtcMediaBackend;
export 'src/media/local_media_source.dart' show LocalMediaSource, MutePolicy;
export 'src/media/media_backend.dart'
    show
        BroadcastExtensionBackend,
        BroadcastExtensionEvent,
        BroadcastExtensionStatus,
        BroadcastSetupProblem,
        DesktopCapturerBackend,
        MediaBackend,
        ScreenCaptureServiceBackend;
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
        ScreenSource,
        ScreenSourceType;
export 'src/media/screen_share_source.dart'
    show ScreenShareEndReason, ScreenShareSource;
export 'src/media/screen_source_picker.dart'
    show ScreenPickerState, ScreenSourcePicker;

// Signaling (design.md §4.4).
export 'src/signaling/in_memory_signaling.dart'
    show InMemorySignaling, InMemorySignalingHub;
export 'src/signaling/participant_state.dart'
    show ParticipantState, SimulcastInfo, TrackInfo, TrackKind, TrackSource;
export 'src/signaling/signaling.dart' show Signaling;

// Quality: active speaker and simulcast layer selection (design.md §6, §7).
// The detectors, the stats poller and the layer controller stay internal:
// the Room owns them and exposes their results.
export 'src/quality/active_speaker_config.dart' show ActiveSpeakerConfig;
export 'src/quality/layer_selection.dart' show LayerSelectionConfig, TileDemand;
export 'src/quality/layer_selection_controller.dart' show LayerDemandReporter;
export 'src/quality/simulcast_layer_reporter.dart' show SimulcastLayerReporter;

// Reconnection tuning and event sources (design.md §8). The decision logic
// stays internal.
export 'src/reconnect/app_lifecycle_source.dart'
    show AppLifecycleSource, FlutterAppLifecycleSource;
export 'src/reconnect/backoff.dart' show BackoffConfig;
export 'src/reconnect/network_change_source.dart' show NetworkChangeSource;
export 'src/reconnect/reconnect_trigger.dart'
    show ReconnectReason, ReconnectTriggerConfig;
