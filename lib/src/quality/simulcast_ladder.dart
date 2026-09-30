import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../media/constraints.dart';

/// One simulcast encoding a publisher sends: its RID and its size.
@immutable
class SimulcastLayerSpec {
  /// Creates a layer description.
  const SimulcastLayerSpec({
    required this.rid,
    required this.width,
    required this.height,
  });

  /// The encoding's RID, such as `a`.
  final String rid;

  /// Width in pixels.
  final int width;

  /// Height in pixels.
  final int height;

  @override
  bool operator ==(Object other) =>
      other is SimulcastLayerSpec &&
      other.rid == rid &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(rid, width, height);

  @override
  String toString() => 'SimulcastLayerSpec($rid: ${width}x$height)';
}

/// The layers a publisher sends, highest resolution first.
///
/// The package publishes `a` at full size, `b` at ½ and `c` at ¼
/// (design.md §6), so a 720p camera gives `a`=1280×720, `b`=640×360 and
/// `c`=320×180 ([h720]).
///
/// Internal: not exported from the package barrel. The Room builds one per
/// subscription.
@immutable
class SimulcastLadder {
  /// Creates a ladder from [layers], which must be non-empty and ordered
  /// highest first.
  SimulcastLadder(List<SimulcastLayerSpec> layers)
    : assert(layers.isNotEmpty, 'A ladder needs at least one layer'),
      layers = List.unmodifiable(layers);

  /// The layers a publisher capturing [preset] sends.
  ///
  /// [rids] and [scaleDownBy] describe the encodings, highest first; the
  /// defaults are the package's `a`/`b`/`c` at 1, 2 and 4.
  ///
  /// With [applyEncoderLayerLimit] (the default), the ladder keeps only as
  /// many layers as libwebrtc's legacy simulcast limit allows for the
  /// capture size, dropping the lowest ones: 3 layers from 960×540 up, 2
  /// from 480×270 up, else 1. libwebrtc doesn't send the rest, so asking
  /// for them would lean on `ridNotAvailable`. This is an expectation of
  /// the encoder's behaviour, not a guarantee: capture can also come out
  /// smaller than requested. `ridNotAvailable: asciibetical` covers the
  /// remaining mismatch.
  factory SimulcastLadder.fromPreset(
    VideoPreset preset, {
    List<String> rids = const ['a', 'b', 'c'],
    List<num> scaleDownBy = const [1, 2, 4],
    bool applyEncoderLayerLimit = true,
  }) {
    assert(rids.length == scaleDownBy.length && rids.isNotEmpty);
    var count = rids.length;
    if (applyEncoderLayerLimit) {
      final limit = maxLayersFor(preset.width, preset.height);
      if (limit < count) count = limit;
    }
    return SimulcastLadder([
      for (var i = 0; i < count; i++)
        SimulcastLayerSpec(
          rid: rids[i],
          width: preset.scaledDownBy(scaleDownBy[i]).width,
          height: preset.scaledDownBy(scaleDownBy[i]).height,
        ),
    ]);
  }

  /// The ladder of a 720p camera: `a`=1280×720, `b`=640×360, `c`=320×180.
  static final SimulcastLadder h720 = SimulcastLadder.fromPreset(
    VideoPreset.h720,
  );

  /// The number of simulcast layers libwebrtc's legacy layer limit allows
  /// for a [width]×[height] capture (its `kSimulcastFormats` table).
  static int maxLayersFor(int width, int height) {
    final pixels = width * height;
    if (pixels >= 960 * 540) return 3;
    if (pixels >= 480 * 270) return 2;
    return 1;
  }

  /// The layers, highest resolution first.
  final List<SimulcastLayerSpec> layers;

  /// The highest layer.
  SimulcastLayerSpec get highest => layers.first;

  /// The lowest layer.
  SimulcastLayerSpec get lowest => layers.last;

  /// The layer with [rid], or `null` if the publisher doesn't send it.
  SimulcastLayerSpec? layer(String rid) =>
      layers.firstWhereOrNull((l) => l.rid == rid);

  /// The rank of [rid]: 0 for the highest layer, or `null` if absent.
  int? rankOf(String rid) {
    final index = layers.indexWhere((l) => l.rid == rid);
    return index < 0 ? null : index;
  }

  @override
  bool operator ==(Object other) =>
      other is SimulcastLadder && listEquals(other.layers, layers);

  @override
  int get hashCode => Object.hashAll(layers);

  @override
  String toString() => 'SimulcastLadder($layers)';
}
