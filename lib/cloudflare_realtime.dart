/// Unofficial Flutter client for the Cloudflare Realtime SFU.
///
/// See `docs/design.md` for the architecture.
library;

// Broker client (design.md §4.1, §5).
export 'src/broker/broker.dart';

// Media: capture, devices and screen share (design.md §4.5, §10).
export 'src/media/constraints.dart'
    show
        CameraFacing,
        CameraOptions,
        MicrophoneOptions,
        ScreenShareOptions,
        VideoPreset;
export 'src/media/device_media_source.dart'
    show CameraSource, DeviceMediaSource, MicrophoneSource;
export 'src/media/flutter_webrtc_media_backend.dart'
    show FlutterWebrtcMediaBackend;
export 'src/media/local_media_source.dart' show LocalMediaSource, MutePolicy;
export 'src/media/media_backend.dart' show DesktopCapturerBackend, MediaBackend;
export 'src/media/media_device_list.dart' show MediaDeviceList;
export 'src/media/media_errors.dart'
    show
        DevicesExhaustedException,
        MediaCaptureException,
        MediaException,
        MediaPermissionDeniedException,
        ScreenSourceNotFoundException,
        ScreenSourcesException;
export 'src/media/media_types.dart'
    show
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
    show ParticipantState, TrackInfo, TrackKind, TrackSource;
export 'src/signaling/signaling.dart' show Signaling;

// Quality: active speaker and simulcast layer selection (design.md §6, §7).
// The detectors, the stats poller and the layer controller stay internal:
// the Room owns them and exposes their results.
export 'src/quality/active_speaker_config.dart' show ActiveSpeakerConfig;
export 'src/quality/layer_selection.dart' show LayerSelectionConfig, TileDemand;
export 'src/quality/layer_selection_controller.dart' show LayerDemandReporter;
export 'src/quality/simulcast_layer_reporter.dart' show SimulcastLayerReporter;

// Reconnection tuning (design.md §8). The decision logic stays internal.
export 'src/reconnect/backoff.dart' show BackoffConfig;
export 'src/reconnect/reconnect_trigger.dart'
    show ReconnectReason, ReconnectTriggerConfig;
