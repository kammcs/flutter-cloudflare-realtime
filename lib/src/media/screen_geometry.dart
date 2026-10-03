/// Maps desktop capture sources to their geometry (internal).
///
/// The operating system is asked through a [NativeScreenGeometry], a small
/// seam with one `dart:ffi` implementation per platform
/// (`screen_geometry_ffi.dart`: Core Graphics on macOS, user32 on
/// Windows), so the mapping here is unit-tested with fakes.
library;

import 'dart:math' as math;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart';

import 'media_types.dart';

/// A display as the operating system reports it, keyed by the ID that
/// `flutter_webrtc` gives its screen source.
typedef NativeDisplay = ({
  String id,
  Rect bounds,
  double scaleFactor,
  bool isPrimary,
});

/// What the operating system says about displays and windows, in its
/// desktop coordinates (see [ScreenGeometry]).
abstract interface class NativeScreenGeometry {
  /// The active displays. The `id`s are `flutter_webrtc`'s screen source
  /// IDs: the `CGDirectDisplayID` on macOS, libwebrtc's display device
  /// index on Windows.
  List<NativeDisplay> displays();

  /// The frame of the window with `flutter_webrtc`'s window source ID [id]
  /// (a `CGWindowID` on macOS, an `HWND` on Windows), or `null` if there
  /// is no such window (or, on Windows, it is minimized).
  Rect? windowFrame(String id);
}

/// Looks up the [ScreenGeometry] of capture sources through a
/// [NativeScreenGeometry]. Answers `null` where there is none (the web,
/// phones, Linux) and when the operating system can't say; never throws.
class ScreenGeometryLookup {
  /// Creates a lookup on [native], or one that always answers `null`.
  ScreenGeometryLookup(this._native);

  final NativeScreenGeometry? _native;
  bool _warned = false;

  /// Whether this lookup can answer at all.
  bool get isAvailable => _native != null;

  /// The geometry of the source with [id] and [type], or `null`.
  ///
  /// Pass [displays] when looking up many sources at once, so the displays
  /// are read once.
  ScreenGeometry? geometryOf(
    ScreenSourceType type,
    String id, {
    List<NativeDisplay>? displays,
  }) {
    final native = _native;
    if (native == null) return null;
    try {
      final all = displays ?? native.displays();
      switch (type) {
        case ScreenSourceType.screen:
          for (final display in all) {
            if (display.id == id) {
              return ScreenGeometry(
                bounds: display.bounds,
                scaleFactor: display.scaleFactor,
                isPrimary: display.isPrimary,
              );
            }
          }
          return null;
        case ScreenSourceType.window:
          final frame = native.windowFrame(id);
          if (frame == null) return null;
          return ScreenGeometry(
            bounds: frame,
            scaleFactor: windowScaleFactor(frame, all),
          );
      }
    } catch (error) {
      _warn(error);
      return null;
    }
  }

  /// [sources] with their [ScreenSource.geometry] filled in (left as they
  /// are where the lookup has nothing).
  List<ScreenSource> withGeometry(List<ScreenSource> sources) {
    final native = _native;
    if (native == null || sources.isEmpty) return sources;
    final List<NativeDisplay> displays;
    try {
      displays = native.displays();
    } catch (error) {
      _warn(error);
      return sources;
    }
    return [
      for (final source in sources)
        _attach(source, geometryOf(source.type, source.id, displays: displays)),
    ];
  }

  /// [source] with its geometry filled in, if found.
  ScreenSource withGeometryOf(ScreenSource source) {
    if (_native == null) return source;
    return _attach(source, geometryOf(source.type, source.id));
  }

  static ScreenSource _attach(ScreenSource source, ScreenGeometry? geometry) =>
      geometry == null ? source : source.copyWith(geometry: geometry);

  void _warn(Object error) {
    if (_warned) return;
    _warned = true;
    debugPrint('cloudflare_realtime: reading screen geometry failed: $error');
  }
}

/// The scale factor of the display that shows most of [frame]; if none
/// shows any of it, the nearest display's; with no displays, 1.
@visibleForTesting
double windowScaleFactor(Rect frame, List<NativeDisplay> displays) {
  if (displays.isEmpty) return 1;
  NativeDisplay? best;
  var bestArea = 0.0;
  for (final display in displays) {
    final overlap = display.bounds.intersect(frame);
    if (overlap.width <= 0 || overlap.height <= 0) continue;
    final area = overlap.width * overlap.height;
    if (area > bestArea) {
      bestArea = area;
      best = display;
    }
  }
  if (best != null) return best.scaleFactor;
  var nearest = displays.first;
  var nearestDistance = double.infinity;
  for (final display in displays) {
    final distance = _distance(display.bounds, frame.center);
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearest = display;
    }
  }
  return nearest.scaleFactor;
}

/// The distance from [point] to the nearest point of [rect].
double _distance(Rect rect, Offset point) {
  final dx = math.max(
    math.max(rect.left - point.dx, 0.0),
    point.dx - rect.right,
  );
  final dy = math.max(
    math.max(rect.top - point.dy, 0.0),
    point.dy - rect.bottom,
  );
  return math.sqrt(dx * dx + dy * dy);
}
