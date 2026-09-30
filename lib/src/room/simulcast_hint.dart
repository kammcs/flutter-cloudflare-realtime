import 'dart:math' as math;

import '../media/constraints.dart';
import '../quality/simulcast_ladder.dart';
import '../session/publish_options.dart';
import '../signaling/participant_state.dart';

/// The [SimulcastInfo] to advertise for a video track sent with
/// [encodings], captured at [width]×[height] (the highest layer's size).
///
/// Returns `null` unless at least two active encodings have a `rid`: a
/// single encoding isn't simulcast, and subscribers then pull it without a
/// `preferredRid`. Layers are ordered highest first (smallest
/// `scaleResolutionDownBy` first).
///
/// Internal: not exported from the package barrel.
SimulcastInfo? simulcastInfoFor(
  List<SendEncoding> encodings, {
  int? width,
  int? height,
}) {
  final layers = [
    for (final e in encodings)
      if (e.rid != null && e.active) (e.rid!, e.scaleResolutionDownBy ?? 1.0),
  ]..sort((a, b) => a.$2.compareTo(b.$2));
  if (layers.length < 2) return null;
  return SimulcastInfo(
    rids: [for (final l in layers) l.$1],
    width: width,
    height: height,
    scaleDownBy: [for (final l in layers) l.$2],
  );
}

/// The publisher ladder for a remote track's [SimulcastInfo], for layer
/// selection (`docs/design.md` §6.1), or `null` when [info] has no size.
///
/// A missing width assumes 16:9, and missing scale factors assume the
/// package's 1, 2, 4, ... The encoder layer limit is applied, as in
/// [SimulcastLadder.fromPreset].
///
/// Internal: not exported from the package barrel.
SimulcastLadder? simulcastLadderFor(SimulcastInfo info) {
  final height = info.height;
  if (height == null) return null;
  final width = info.width ?? (height * 16 / 9).round();
  return SimulcastLadder.fromPreset(
    VideoPreset(width: width, height: height, frameRate: 30),
    rids: info.rids,
    scaleDownBy:
        info.scaleDownBy ??
        [for (var i = 0; i < info.rids.length; i++) math.pow(2, i)],
  );
}
