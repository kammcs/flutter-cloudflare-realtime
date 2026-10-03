/// Seams for testing an app that uses `cloudflare_realtime` without native
/// WebRTC (`flutter_webrtc`'s plugin doesn't run in `flutter test`), and for
/// single-process demos.
///
/// - [MediaBackend] and its platform parts replace capture, device lists
///   and screen sources: pass a fake to `CloudflareRealtime(mediaBackend:)`,
///   `CameraSource(backend:)` or `ScreenSourcePicker(backend:)`.
///   [FlutterWebrtcMediaBackend] is the default.
/// - [BrokerClientFactory] and [SfuSessionConnector] replace the broker
///   client and the SFU session (`CloudflareRealtime(createBrokerClient:,
///   connectSession:)`), and [MediaStreamWrapper] the wrapping of pulled
///   tracks (`wrapTrack:`).
/// - [VideoRenderer] and [VideoRendererFactory] replace the video renderer
///   (`ParticipantVideoView.defaultRendererFactory`).
/// - [InMemorySignaling] connects participants in one process.
///
/// Import it from tests (and demos) only; apps need
/// `package:cloudflare_realtime/cloudflare_realtime.dart`. README, "Testing
/// your app", has the rest.
library;

export 'src/media/flutter_webrtc_media_backend.dart'
    show FlutterWebrtcMediaBackend;
export 'src/media/media_backend.dart'
    show
        BroadcastExtensionBackend,
        BroadcastExtensionEvent,
        BroadcastExtensionStatus,
        DesktopCapturerBackend,
        MediaBackend,
        ScreenCaptureServiceBackend;
export 'src/rendering/renderable_track.dart'
    show MediaStreamWrapper, wrapTrackInMediaStream;
export 'src/rendering/video_renderer.dart'
    show FlutterWebrtcVideoRenderer, VideoRenderer, VideoRendererFactory;
export 'src/room/cloudflare_realtime.dart'
    show BrokerClientFactory, SfuSessionConnector;
export 'src/signaling/in_memory_signaling.dart'
    show InMemorySignaling, InMemorySignalingHub;
