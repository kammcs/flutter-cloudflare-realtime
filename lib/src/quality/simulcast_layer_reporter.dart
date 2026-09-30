import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import 'layer_selection.dart';
import 'layer_selection_controller.dart';

/// Wraps a remote video view and reports its on-screen size, so the
/// package can pull the simulcast layer that fits it (design.md §6).
///
/// ```dart
/// SimulcastLayerReporter(
///   reporter: room.layerReporter,          // provided by the Room
///   subscriptionId: remoteVideo.id,
///   visible: isOnScreen,
///   child: RTCVideoView(renderer, objectFit: ...),
/// )
/// ```
///
/// - **Size:** the child's laid-out size, in logical pixels, times
///   `MediaQuery.devicePixelRatioOf`. The child should fill the tile (as
///   `RTCVideoView` does); the reporter doesn't change layout.
/// - **Visibility:** the view counts as hidden when [visible] is `false`
///   (the app knows about scrolling, tabs and collapsed panels) or when
///   tickers are disabled here ([TickerMode]), which is the case for routes
///   covered by an opaque route. A hidden view asks for no video.
/// - Reports go out after the frame that produced them, and only when the
///   demand changed. Several reporters may show the same subscription; the
///   biggest visible one wins. On dispose, or when [subscriptionId] or
///   [reporter] changes, the view is removed from the old subscription.
class SimulcastLayerReporter extends StatefulWidget {
  /// Creates a reporter around [child].
  const SimulcastLayerReporter({
    super.key,
    required this.reporter,
    required this.subscriptionId,
    this.visible = true,
    required this.child,
  });

  /// Where sizes are reported, usually the Room's.
  final LayerDemandReporter reporter;

  /// The subscription (pulled video track) the child shows.
  final String subscriptionId;

  /// Whether the child is on screen, as far as the app knows. Default
  /// `true`.
  final bool visible;

  /// The video view.
  final Widget child;

  @override
  State<SimulcastLayerReporter> createState() => _SimulcastLayerReporterState();
}

class _SimulcastLayerReporterState extends State<SimulcastLayerReporter> {
  Size? _size;
  TileDemand? _reported;
  LayerDemandReporter? _reportedTo;
  String? _reportedFor;
  bool _scheduled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _schedule();
  }

  @override
  void didUpdateWidget(SimulcastLayerReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.subscriptionId != widget.subscriptionId ||
        oldWidget.reporter != widget.reporter) {
      _withdraw();
    }
    _schedule();
  }

  @override
  void dispose() {
    _withdraw();
    super.dispose();
  }

  void _onSize(Size size) {
    if (size == _size) return;
    _size = size;
    _schedule();
  }

  void _schedule() {
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (mounted) _report();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  void _report() {
    final size = _size;
    if (size == null) return;
    final demand = TileDemand.fromLogicalSize(
      size,
      MediaQuery.maybeDevicePixelRatioOf(context) ??
          View.maybeOf(context)?.devicePixelRatio ??
          1.0,
      visible: widget.visible && TickerMode.valuesOf(context).enabled,
    );
    if (demand == _reported &&
        identical(_reportedTo, widget.reporter) &&
        _reportedFor == widget.subscriptionId) {
      return;
    }
    widget.reporter.reportDemand(widget.subscriptionId, this, demand);
    _reported = demand;
    _reportedTo = widget.reporter;
    _reportedFor = widget.subscriptionId;
  }

  void _withdraw() {
    final to = _reportedTo;
    final subscription = _reportedFor;
    if (to != null && subscription != null) {
      to.removeView(subscription, this);
    }
    _reported = null;
    _reportedTo = null;
    _reportedFor = null;
  }

  @override
  Widget build(BuildContext context) {
    // Depend on these so a change rebuilds and re-reports.
    MediaQuery.maybeDevicePixelRatioOf(context);
    TickerMode.valuesOf(context);
    return _SizeObserver(onSize: _onSize, child: widget.child);
  }
}

class _SizeObserver extends SingleChildRenderObjectWidget {
  const _SizeObserver({required this.onSize, super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderSizeObserver(onSize);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderSizeObserver renderObject,
  ) {
    renderObject.onSize = onSize;
  }
}

class _RenderSizeObserver extends RenderProxyBox {
  _RenderSizeObserver(this.onSize);

  ValueChanged<Size> onSize;

  @override
  void performLayout() {
    super.performLayout();
    // Only records the size; the state reports after the frame.
    onSize(size);
  }
}
