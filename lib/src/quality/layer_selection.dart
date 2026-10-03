/// @docImport 'layer_selection_controller.dart';
/// @docImport 'simulcast_layer_reporter.dart';
library;

import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';

import '../broker/models/tracks.dart';
import 'simulcast_ladder.dart';

/// Tuning for picking simulcast layers from rendered tile sizes
/// (design.md §6).
///
/// The policy picks the **lowest** layer whose height, upscaled by at most
/// [maxUpscale], covers the tile. With the defaults and a 720p publisher
/// (`a`=720, `b`=360, `c`=180 lines), a tile up to 270 physical pixels high
/// gets `c`, up to 540 gets `b`, anything bigger gets `a`. A 2×2 gallery on
/// a 1080p screen (540-pixel tiles) therefore pulls `b`.
@immutable
final class LayerSelectionOptions {
  /// Creates a layer-selection configuration.
  const LayerSelectionOptions({
    this.maxUpscale = 1.5,
    this.downgradeHysteresis = 0.15,
    this.debounce = const Duration(milliseconds: 300),
    this.ridNotAvailable = SimulcastOrdering.asciibetical,
    this.priorityOrdering,
  }) : assert(maxUpscale >= 1.0, 'maxUpscale must be at least 1'),
       assert(
         downgradeHysteresis >= 0 && downgradeHysteresis < 1,
         'downgradeHysteresis must be in [0, 1)',
       );

  /// How far a layer may be scaled up to fill a tile before a higher layer
  /// is needed. 1.0 means never upscale. Default 1.5.
  final double maxUpscale;

  /// How much smaller (as a fraction) a tile must get than the switch-up
  /// point before a lower layer is chosen. This band stops small resizes
  /// around a boundary from flipping layers. Default 0.15: with the other
  /// defaults, a tile that pulled `a` drops to `b` only at 459 lines or
  /// fewer (540 × 0.85).
  final double downgradeHysteresis;

  /// How long a new layer choice must stand before it is sent to the SFU.
  /// Coalesces bursts, such as a window being resized or a layout change
  /// that moves several tiles. The first choice for a subscription, and a
  /// change from paused to a layer, are not delayed. Default 300 ms.
  final Duration debounce;

  /// What the SFU does when the preferred layer stops (for example when the
  /// publisher's encoder drops a layer under CPU or bandwidth pressure).
  /// Default [SimulcastOrdering.asciibetical]: fall back to the next
  /// available RID. The client keeps its preferred RID; the SFU is meant to
  /// return to it when the layer comes back, but against the real SFU it
  /// sometimes stays on the lower layer (`docs/design.md` §6.2).
  final SimulcastOrdering ridNotAvailable;

  /// Whether the SFU may step down from the preferred layer under the
  /// subscriber's bandwidth pressure ([SimulcastOrdering.asciibetical]).
  /// Default `null`, which leaves the SFU default (`none`): the subscriber
  /// gets exactly the layer the client chose, which keeps layer switching
  /// predictable. Revisit after measuring on constrained links.
  final SimulcastOrdering? priorityOrdering;

  @override
  bool operator ==(Object other) =>
      other is LayerSelectionOptions &&
      other.maxUpscale == maxUpscale &&
      other.downgradeHysteresis == downgradeHysteresis &&
      other.debounce == debounce &&
      other.ridNotAvailable == ridNotAvailable &&
      other.priorityOrdering == priorityOrdering;

  @override
  int get hashCode => Object.hash(
    maxUpscale,
    downgradeHysteresis,
    debounce,
    ridNotAvailable,
    priorityOrdering,
  );
}

/// How big a video view is on screen, and whether it is visible.
///
/// [width] and [height] are **physical** pixels: logical size ×
/// device-pixel ratio. [SimulcastLayerReporter] measures them.
@immutable
final class TileDemand {
  /// Creates a demand from physical pixel sizes.
  const TileDemand({
    required this.width,
    required this.height,
    this.visible = true,
  });

  /// Creates a demand from a logical [size] and [devicePixelRatio].
  factory TileDemand.fromLogicalSize(
    Size size,
    double devicePixelRatio, {
    bool visible = true,
  }) => TileDemand(
    width: size.width * devicePixelRatio,
    height: size.height * devicePixelRatio,
    visible: visible,
  );

  /// A view that isn't shown.
  static const hidden = TileDemand(width: 0, height: 0, visible: false);

  /// Width in physical pixels.
  final double width;

  /// Height in physical pixels.
  final double height;

  /// Whether the view is on screen.
  final bool visible;

  /// Whether the view needs any video: visible, with a non-empty size.
  bool get needsVideo =>
      visible && width > 0 && height > 0 && width.isFinite && height.isFinite;

  @override
  bool operator ==(Object other) =>
      other is TileDemand &&
      other.width == width &&
      other.height == height &&
      other.visible == visible;

  @override
  int get hashCode => Object.hash(width, height, visible);

  @override
  String toString() =>
      'TileDemand(${width.toStringAsFixed(0)}x${height.toStringAsFixed(0)}'
      '${visible ? '' : ', hidden'})';
}

/// The layer a subscription should receive: a RID, or paused.
@immutable
class LayerPreference {
  /// Receive the layer with [rid].
  const LayerPreference.rid(String this.rid);

  /// Receive nothing: no view shows the track.
  const LayerPreference.paused() : rid = null;

  /// The preferred RID, or `null` when [isPaused].
  final String? rid;

  /// Whether no view needs the track.
  ///
  /// The SFU has no "pause" for a pulled track; the Room decides what it
  /// means (for example switch to the lowest layer, or close the track
  /// after it has stayed paused for a while).
  bool get isPaused => rid == null;

  @override
  bool operator ==(Object other) =>
      other is LayerPreference && other.rid == rid;

  @override
  int get hashCode => rid.hashCode;

  @override
  String toString() =>
      isPaused ? 'LayerPreference.paused' : 'LayerPreference($rid)';
}

/// Maps a [TileDemand] to a [LayerPreference] for a publisher's
/// [SimulcastLadder], with hysteresis.
///
/// Algorithm, for a visible tile of `w×h` physical pixels:
///
/// 1. The height a layer must cover is `max(h, w × layerHeight /
///    layerWidth)`: the tile is assumed to be filled ("cover"), so a wide
///    tile needs as many lines as its width implies. This errs towards
///    quality.
/// 2. **Up:** the lowest layer with `height × maxUpscale ≥ required`, or the
///    highest layer if none is big enough.
/// 3. **Down:** the same with `height × maxUpscale × (1 −
///    downgradeHysteresis)`, which is stricter.
/// 4. With no current layer, choose "up". Otherwise choose "up" if it is
///    higher than the current layer, "down" if that is lower than it, and
///    stay put in between.
///
/// A hidden or empty tile is [LayerPreference.paused]. The policy only
/// returns RIDs in the ladder, so it never asks for a layer the publisher
/// doesn't send.
///
/// Internal: not exported from the package barrel.
class SimulcastLayerPolicy {
  /// Creates a policy.
  const SimulcastLayerPolicy([this.config = const LayerSelectionOptions()]);

  /// The tuning.
  final LayerSelectionOptions config;

  /// Chooses a layer for [demand] from [ladder]. [currentRid] is the layer
  /// already requested, for hysteresis.
  LayerPreference choose(
    TileDemand demand,
    SimulcastLadder ladder, {
    String? currentRid,
  }) {
    if (!demand.needsVideo) return const LayerPreference.paused();
    final up = _lowestCovering(demand, ladder, config.maxUpscale);
    final currentRank = currentRid == null ? null : ladder.rankOf(currentRid);
    if (currentRank == null || up < currentRank) {
      return LayerPreference.rid(ladder.layers[up].rid);
    }
    final down = _lowestCovering(
      demand,
      ladder,
      config.maxUpscale * (1 - config.downgradeHysteresis),
    );
    final rank = down > currentRank ? down : currentRank;
    return LayerPreference.rid(ladder.layers[rank].rid);
  }

  /// The `simulcast` object to send with a pull or `tracks/update` for
  /// [rid], with this policy's fallback settings.
  SimulcastOptions simulcastConfig(String rid) => SimulcastOptions(
    preferredRid: rid,
    ridNotAvailable: config.ridNotAvailable,
    priorityOrdering: config.priorityOrdering,
  );

  // The rank (0 = highest) of the lowest layer that covers the demand when
  // upscaled by [upscale]; the highest layer if none does.
  static int _lowestCovering(
    TileDemand demand,
    SimulcastLadder ladder,
    double upscale,
  ) {
    for (var rank = ladder.layers.length - 1; rank >= 0; rank--) {
      final layer = ladder.layers[rank];
      final aspect = layer.width > 0 ? layer.height / layer.width : 0.0;
      final required = math.max(demand.height, demand.width * aspect);
      if (layer.height * upscale >= required) return rank;
    }
    return 0;
  }
}
