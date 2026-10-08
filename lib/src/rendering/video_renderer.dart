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
///
/// On iOS and macOS every stream change blocks the platform thread, which
/// is also the UI thread there (docs/design.md §4.3, Fewer renderer
/// calls), so it makes no platform call for a change that changes nothing:
/// setting the stream it already shows, or none when it shows none.
class FlutterWebrtcVideoRenderer implements VideoRenderer {
  /// Creates the renderer. It does nothing native until [initialize].
  FlutterWebrtcVideoRenderer();

  final RTCVideoRenderer _renderer = RTCVideoRenderer();

  /// The stream the native renderer was last given, or `null` for none.
  MediaStream? _attached;

  @override
  Future<void> initialize() => _renderer.initialize();

  @override
  Future<void> setStream(MediaStream? stream) async {
    if (identical(stream, _attached)) return;
    _attached = stream;
    if (stream == null) {
      await _detach();
    } else {
      _renderer.srcObject = stream;
    }
  }

  /// Detaches the stream and waits for the plugin's answer: after it, the
  /// track no longer hands frames to the native renderer. Best effort, as
  /// the `srcObject` setter was: a renderer that isn't initialized (or is
  /// already released) has nothing to detach.
  Future<void> _detach() async {
    try {
      await _renderer.setSrcObject(stream: null);
    } catch (_) {
      // Nothing attached natively.
    }
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
    if (_attached != null) {
      _attached = null;
      await _detach();
    }
    await _renderer.dispose();
  }
}
