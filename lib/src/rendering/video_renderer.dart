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

  @override
  Future<void> initialize() => _renderer.initialize();

  @override
  Future<void> setStream(MediaStream? stream) async {
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
      _renderer.srcObject = null;
    } catch (_) {
      // Not initialized: nothing to detach.
    }
    await _renderer.dispose();
  }
}
