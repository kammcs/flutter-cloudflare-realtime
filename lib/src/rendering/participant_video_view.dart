import 'dart:async';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show MediaStream;

import '../media/local_media_source.dart';
import '../media/media_types.dart' show CameraFacing;
import '../quality/layer_selection_controller.dart';
import '../quality/simulcast_layer_reporter.dart';
import '../room/room.dart';
import '../signaling/participant_state.dart';
import 'video_renderer.dart';

/// Shows a participant's video: a remote track from a [Room], or a local
/// camera or screen capture.
///
/// A thin wrapper around a [VideoRenderer] (by default `flutter_webrtc`'s
/// `RTCVideoRenderer` and `RTCVideoView`):
///
/// - **Remote** ([ParticipantVideoView.remote]): with [subscribe] (the
///   default), the view keeps the track subscribed while it is mounted,
///   through a [RemoteTrackLease], so a gallery pulls only the videos on
///   screen. Several views of one track share the pull. While the publisher
///   has muted the track, or nothing is pulled yet, the [placeholder] shows.
/// - **Local** ([ParticipantVideoView.local]): shows the source's captured
///   track (a self-view), mirrored for cameras by default. It shows while
///   the source captures, even if muted with `MutePolicy.keepCapture`.
///
/// The native renderer is created only once there is something to show, so
/// the widget builds without the plugin (for example in widget tests) while
/// nothing is subscribed. Tests can replace it through [rendererFactory] or
/// [defaultRendererFactory].
///
/// **Layer selection.** A remote video view reports its on-screen size and
/// [visible] to the room ([Room.layerReporter]), keyed by
/// [RemoteTrackPublication.id], through a [SimulcastLayerReporter]; the room
/// pulls the simulcast layer that fits the biggest visible view
/// (`docs/design.md` §6.1). Pass [automaticLayers] `false` to opt out, or
/// [layerReporter] to report elsewhere.
class ParticipantVideoView extends StatefulWidget {
  /// Shows the remote video track of [publication].
  const ParticipantVideoView.remote(
    RemoteTrackPublication this.publication, {
    super.key,
    this.subscribe = true,
    this.fit = VideoViewFit.cover,
    this.mirror,
    this.placeholder,
    this.filterQuality = FilterQuality.low,
    this.layerReporter,
    this.automaticLayers = true,
    this.visible = true,
    this.rendererFactory,
  }) : localSource = null;

  /// Shows the local capture of [localSource], such as a published camera's
  /// `LocalMediaPublication.mediaSource` or a camera previewed before
  /// joining.
  const ParticipantVideoView.local(
    LocalMediaSource this.localSource, {
    super.key,
    this.fit = VideoViewFit.cover,
    this.mirror,
    this.placeholder,
    this.filterQuality = FilterQuality.low,
    this.rendererFactory,
  }) : publication = null,
       subscribe = false,
       layerReporter = null,
       automaticLayers = false,
       visible = true;

  /// The remote track shown, for [ParticipantVideoView.remote].
  final RemoteTrackPublication? publication;

  /// The local source shown, for [ParticipantVideoView.local].
  final LocalMediaSource? localSource;

  /// Whether the view keeps the remote track subscribed while mounted.
  /// With `false`, it shows the track only while something else subscribes
  /// to it.
  final bool subscribe;

  /// How the video fills the view. Default [VideoViewFit.cover].
  final VideoViewFit fit;

  /// Whether to mirror the video horizontally. Defaults to `true` for a
  /// local camera (a self-view reads like a mirror), except a back camera
  /// ([CameraFacing.environment]), and `false` otherwise.
  final bool? mirror;

  /// Shown while there is no video: not subscribed yet, muted, or not
  /// capturing. Defaults to a dark box with a "video off" icon.
  final Widget? placeholder;

  /// The renderer's filter quality.
  final FilterQuality filterQuality;

  /// Receives the view's on-screen size for layer selection, keyed by the
  /// remote publication's [RemoteTrackPublication.id]. Defaults to the
  /// room's [Room.layerReporter] while [automaticLayers] is on. Ignored for
  /// audio and local views.
  final LayerDemandReporter? layerReporter;

  /// Whether the view reports its size to the room, so the room picks the
  /// simulcast layer for it. Default `true`. With `false` (and no
  /// [layerReporter]), the view has no say in the layer: the track keeps
  /// [RoomOptions.defaultVideoLayer], what other views ask for, or
  /// [RemoteTrackPublication.setPreferredLayer].
  final bool automaticLayers;

  /// Whether the view is on screen as far as the app knows (for example
  /// scrolled out of a list, or behind another tab). Reported with the
  /// size: a track whose views are all hidden drops to its lowest layer,
  /// and its pull is released after [RoomOptions.hiddenVideoLinger].
  final bool visible;

  /// Creates the renderer. Defaults to [defaultRendererFactory].
  final VideoRendererFactory? rendererFactory;

  /// The renderer factory used when [rendererFactory] is null. Widget tests
  /// can point it at a fake, because plugins don't run under
  /// `flutter test`.
  static VideoRendererFactory defaultRendererFactory =
      FlutterWebrtcVideoRenderer.new;

  @override
  State<ParticipantVideoView> createState() => _ParticipantVideoViewState();
}

class _ParticipantVideoViewState extends State<ParticipantVideoView> {
  final List<StreamSubscription<Object?>> _subscriptions = [];
  RemoteTrackLease? _lease;
  MediaStream? _stream;
  bool _muted = false;
  VideoRenderer? _renderer;
  bool _rendererReady = false;
  // Renderer calls run in order, one at a time.
  Future<void> _rendererOps = Future.value();

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(ParticipantVideoView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged =
        !identical(oldWidget.publication, widget.publication) ||
        !identical(oldWidget.localSource, widget.localSource);
    if (sourceChanged) {
      _detach();
      _attach();
    } else if (oldWidget.subscribe != widget.subscribe) {
      _updateLease();
    }
  }

  @override
  void dispose() {
    _detach(disposing: true);
    final renderer = _renderer;
    _renderer = null;
    if (renderer != null) {
      _rendererOps = _rendererOps.then((_) => _quietly(renderer.dispose));
    }
    super.dispose();
  }

  void _attach() {
    final publication = widget.publication;
    final local = widget.localSource;
    if (publication != null) {
      _muted = publication.muted;
      _updateLease();
      _subscriptions
        ..add(publication.track.listen((t) => _show(t?.stream)))
        ..add(
          publication.mutedChanges.listen((muted) {
            if (mounted && muted != _muted) setState(() => _muted = muted);
          }),
        );
    } else if (local != null) {
      _muted = false;
      _subscriptions.add(local.track.listen((t) => _show(t?.stream)));
    }
  }

  void _detach({bool disposing = false}) {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _lease?.release();
    _lease = null;
    if (disposing) {
      // dispose() tears the renderer down, which detaches the stream.
      _stream = null;
    } else {
      _show(null);
    }
  }

  void _updateLease() {
    final publication = widget.publication;
    final wantLease =
        widget.subscribe &&
        publication != null &&
        publication.kind == TrackKind.video;
    if (wantLease && _lease == null) {
      _lease = publication.retain();
    } else if (!wantLease && _lease != null) {
      _lease!.release();
      _lease = null;
    }
  }

  void _show(MediaStream? stream) {
    if (identical(stream, _stream)) return;
    _stream = stream;
    // No renderer yet and nothing to show: the placeholder is already up.
    if (stream == null && _renderer == null) return;
    _rendererOps = _rendererOps.then((_) => _apply(stream));
  }

  Future<void> _apply(MediaStream? stream) async {
    if (!mounted || !identical(stream, _stream)) return;
    var renderer = _renderer;
    if (renderer == null) {
      final created =
          (widget.rendererFactory ??
          ParticipantVideoView.defaultRendererFactory)();
      _renderer = renderer = created;
      try {
        await created.initialize();
      } catch (error, stackTrace) {
        _report(error, stackTrace);
        _renderer = null;
        return;
      }
      if (!mounted) {
        await _quietly(created.dispose);
        return;
      }
      _rendererReady = true;
    }
    try {
      await renderer.setStream(_stream);
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
    if (mounted) setState(() {});
  }

  void _report(Object error, StackTrace stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'cloudflare_realtime',
        context: ErrorDescription('while updating a ParticipantVideoView'),
      ),
    );
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Best effort.
    }
  }

  // A self-view reads like a mirror, except from a back camera, where text
  // in front of it would show reversed.
  bool get _mirror {
    final explicit = widget.mirror;
    if (explicit != null) return explicit;
    final local = widget.localSource;
    if (local == null || local.source != TrackSource.camera) return false;
    final device = local.currentTrack?.device;
    return device?.facing != CameraFacing.environment;
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    final showVideo =
        _rendererReady && renderer != null && _stream != null && !_muted;
    Widget child = showVideo
        ? renderer.build(
            context,
            fit: widget.fit,
            mirror: _mirror,
            filterQuality: widget.filterQuality,
          )
        : widget.placeholder ?? const _VideoPlaceholder();
    final publication = widget.publication;
    final reporter =
        widget.layerReporter ??
        (widget.automaticLayers && publication != null
            ? publication.participant.room.layerReporter
            : null);
    if (publication != null &&
        reporter != null &&
        publication.kind == TrackKind.video) {
      child = SimulcastLayerReporter(
        reporter: reporter,
        subscriptionId: publication.id,
        visible: widget.visible,
        child: child,
      );
    }
    return child;
  }
}

class _VideoPlaceholder extends StatelessWidget {
  const _VideoPlaceholder();

  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Color(0xFF202124),
    child: Center(
      child: Icon(Icons.videocam_off, color: Color(0x8AFFFFFF), size: 32),
    ),
  );
}
