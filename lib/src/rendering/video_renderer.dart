/// @docImport 'participant_video_view.dart';
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// How video fills its box.
enum VideoViewFit {
  /// Show the whole frame, letterboxed if the aspect ratios differ.
  contain,

  /// Fill the box, cropping the frame if the aspect ratios differ.
  cover,
}

/// The native side of a [ParticipantVideoView]: something that renders a
/// [MediaStream].
///
/// [FlutterWebrtcVideoRenderer] wraps `flutter_webrtc`'s `RTCVideoRenderer`
/// and `RTCVideoView`. Widget tests pass a fake through
/// [ParticipantVideoView.rendererFactory] (or
/// [ParticipantVideoView.defaultRendererFactory]), because plugins don't run
/// under `flutter test`.
abstract interface class VideoRenderer {
  /// Prepares the renderer. Called once, before anything else.
  Future<void> initialize();

  /// Shows [stream], or nothing when it is `null`.
  Future<void> setStream(MediaStream? stream);

  /// Builds the widget that shows the video.
  Widget build(
    BuildContext context, {
    required VideoViewFit fit,
    required bool mirror,
    required FilterQuality filterQuality,
  });

  /// Releases the renderer. Nothing is called afterwards.
  Future<void> dispose();
}

/// Creates a [VideoRenderer].
typedef VideoRendererFactory = VideoRenderer Function();

/// A [VideoRenderer] backed by `flutter_webrtc`'s `RTCVideoRenderer`.
class FlutterWebrtcVideoRenderer implements VideoRenderer {
  /// Creates the renderer. It does nothing native until [initialize].
  FlutterWebrtcVideoRenderer();

  final RTCVideoRenderer _renderer = RTCVideoRenderer();

  /// Whether the renderer has ever been given a stream (and so may have
  /// frames in flight).
  bool _hadStream = false;

  @override
  Future<void> initialize() => _renderer.initialize();

  @override
  Future<void> setStream(MediaStream? stream) async {
    if (stream != null) _hadStream = true;
    _renderer.srcObject = stream;
  }

  @override
  Widget build(
    BuildContext context, {
    required VideoViewFit fit,
    required bool mirror,
    required FilterQuality filterQuality,
  }) => RTCVideoView(
    _renderer,
    mirror: mirror,
    filterQuality: filterQuality,
    objectFit: switch (fit) {
      VideoViewFit.contain =>
        RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
      VideoViewFit.cover => RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
    },
  );

  @override
  Future<void> dispose() async {
    try {
      // Awaited: once the plugin has answered, the track no longer hands
      // frames to the native renderer.
      await _renderer.setSrcObject(stream: null);
    } catch (_) {
      // Not initialized (or already disposed): nothing to detach.
    }
    // flutter_webrtc's Darwin renderer queues a block on the main queue
    // for each frame, which reads the renderer through a weak reference
    // without a nil check: a block that runs after the renderer is
    // released crashes the app. Let the blocks of the last frames run
    // first (docs/design.md §4.3,
    // Releasing a native renderer).
    if (_hadStream) await Future<void>.delayed(_releaseDelay);
    await _renderer.dispose();
  }

  /// How long [dispose] waits between detaching the stream and releasing
  /// the native renderer.
  static const _releaseDelay = Duration(milliseconds: 250);
}
