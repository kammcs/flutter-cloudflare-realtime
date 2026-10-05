import 'dart:async';
import 'dart:collection' show HashMap;

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
/// **Keep it in place.** The renderer is bound once per track: rebuilding
/// the view, even as a new widget with other settings, never sets its
/// stream again, and a publisher's mute doesn't either. Each native
/// renderer change blocks the UI thread on iOS and macOS (in
/// `flutter_webrtc`; `docs/design.md` §4.3, Fewer renderer calls), so the
/// view makes one only when the track changes. A view that Flutter
/// re-creates for the same track (a layout change, a parent whose shape
/// changed) takes over the renderer of the view it replaces, when that one
/// goes in the same frame or up to 500 ms before. Still, keep the widgets
/// above it the same shape whatever else changes (for example, a speaking
/// highlight drawn with a transparent decoration while off, rather than a
/// `Container` whose `foregroundDecoration` comes and goes), and to move a
/// view between layouts, give it (or its tile) a `GlobalKey`. Two views of
/// one track on screen at once have a renderer each.
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
  ///
  /// With [VideoViewFit.contain] (for screen shares), the frame is
  /// letterboxed in the middle of the view and the bars are transparent:
  /// put a background behind the view, or a portrait share in a wide tile
  /// reads as a strip floating beside the tile's label.
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

  /// The stream [_renderer] was last given: video shows only while it is
  /// [_stream], so a renderer still on an old track never shows its frame.
  MediaStream? _rendererStream;
  // Renderer calls run in order, one at a time.
  Future<void> _rendererOps = Future.value();
  int _pendingOps = 0;

  /// Whether [deactivate] left the renderer for another view
  /// ([_RendererHandOver]).
  bool _parked = false;

  @override
  void initState() {
    super.initState();
    _attach();
    // A view of the same stream that Flutter removed in this frame (a
    // layout change that re-creates the view) left its renderer: take it,
    // and the video shows from the first frame, with no native call.
    final initial =
        widget.publication?.track?.stream ?? widget.localSource?.track?.stream;
    final handedOver = initial == null ? null : _RendererHandOver.take(initial);
    if (handedOver != null) {
      _renderer = handedOver;
      _rendererReady = true;
      _rendererStream = _stream = initial;
    }
  }

  @override
  void deactivate() {
    // Leave an idle renderer for a view of the same stream built in this
    // frame (see initState). A view that only moves (a GlobalKey) takes it
    // back in activate().
    final renderer = _renderer;
    final stream = _rendererStream;
    if (renderer != null &&
        _rendererReady &&
        _pendingOps == 0 &&
        stream != null &&
        identical(stream, _stream)) {
      _RendererHandOver.park(stream, renderer);
      _renderer = null;
      _rendererReady = false;
      _parked = true;
    }
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    if (!_parked) return;
    _parked = false;
    final stream = _rendererStream!;
    final back = _RendererHandOver.take(stream);
    if (back != null) {
      _renderer = back;
      _rendererReady = true;
      return;
    }
    // Another view took it: get a renderer of this view's own.
    _rendererStream = null;
    final current = _stream;
    _stream = null;
    _show(current);
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
    if (renderer != null) _enqueue(() => _release(renderer));
    super.dispose();
  }

  /// Runs [op] after the renderer calls before it.
  void _enqueue(Future<void> Function() op) {
    _pendingOps++;
    _rendererOps = _rendererOps
        .then((_) => op())
        .whenComplete(() => _pendingOps--);
  }

  /// Leaves [renderer], whose calls were still running when the view went,
  /// for a view of the same stream that comes right after this one
  /// ([_RendererHandOver]), or releases it.
  Future<void> _release(VideoRenderer renderer) async {
    final stream = _rendererStream;
    if (_rendererReady && stream != null) {
      _RendererHandOver.park(stream, renderer);
    } else {
      await _quietly(renderer.dispose);
    }
  }

  void _attach() {
    final publication = widget.publication;
    final local = widget.localSource;
    if (publication != null) {
      _muted = publication.isMuted;
      _updateLease();
      _subscriptions
        ..add(publication.trackChanges.listen((t) => _show(t?.stream)))
        ..add(
          publication.mutedChanges.listen((muted) {
            if (mounted && muted != _muted) setState(() => _muted = muted);
          }),
        );
    } else if (local != null) {
      _muted = false;
      _subscriptions.add(local.trackChanges.listen((t) => _show(t?.stream)));
    }
  }

  void _detach({bool disposing = false}) {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    _lease?.release();
    _lease = null;
    // dispose() hands the renderer over or tears it down.
    _stream = null;
    if (!disposing && _renderer != null) {
      // A new source: its track arrives in a later microtask (the streams
      // replay their value), and the renderer moves to it with one call.
      // Detach only if it has none by then (each call blocks the UI thread
      // on iOS and macOS, docs/design.md §4.3, Fewer renderer calls).
      _enqueue(() async {
        await Future<void>.delayed(Duration.zero);
        await _apply(null);
      });
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
    _enqueue(() => _apply(stream));
  }

  Future<void> _apply(MediaStream? stream) async {
    if (!mounted || !identical(stream, _stream)) return;
    if (_renderer == null) {
      if (stream == null) return;
      // A view of this stream that just went with its renderer still busy
      // leaves it once its calls are done ([_release]): let that run
      // first, then take the renderer over, with no native call.
      await Future<void>.delayed(Duration.zero);
      if (!mounted || !identical(stream, _stream)) return;
    }
    var renderer = _renderer;
    if (renderer == null) {
      final handedOver = _RendererHandOver.take(stream!);
      if (handedOver != null) {
        _renderer = handedOver;
        _rendererReady = true;
        _rendererStream = stream;
        setState(() {});
        return;
      }
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
    final target = _stream;
    _rendererStream = target;
    try {
      await renderer.setStream(target);
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
    final device = local.track?.device;
    return device?.facing != CameraFacing.environment;
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    final showVideo =
        _rendererReady &&
        renderer != null &&
        _stream != null &&
        identical(_rendererStream, _stream) &&
        !_muted;
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

/// Renderers whose view went while they showed a stream, each kept for
/// [_linger] in case Flutter creates a view of the same stream right after
/// (a layout change that re-creates the view, a tile moved without a
/// `GlobalKey`, a parent whose shape changed). That view takes the renderer
/// over as it is: no native renderer is created, attached, detached or
/// released, calls that block the UI thread on iOS and macOS
/// (docs/design.md §4.3, Fewer renderer calls). One view at a time: two
/// views on screen at once each have their own renderer (on the web, a
/// renderer's fit and mirroring are its own).
abstract final class _RendererHandOver {
  static const _linger = Duration(milliseconds: 500);
  static final Map<MediaStream, (VideoRenderer, Timer)> _parked =
      HashMap.identity();

  static void park(MediaStream stream, VideoRenderer renderer) {
    final previous = _parked.remove(stream);
    if (previous != null) {
      previous.$2.cancel();
      unawaited(_quietly(previous.$1.dispose));
    }
    _parked[stream] = (
      renderer,
      Timer(_linger, () {
        _parked.remove(stream);
        unawaited(_quietly(renderer.dispose));
      }),
    );
  }

  static VideoRenderer? take(MediaStream stream) {
    final parked = _parked.remove(stream);
    parked?.$2.cancel();
    return parked?.$1;
  }

  static Future<void> _quietly(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      // Best effort.
    }
  }
}
