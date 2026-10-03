/// @docImport '../room/room.dart';
/// @docImport '../room/room_options.dart';
/// @docImport '../signaling/participant_state.dart';
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../util/coalescing_runner.dart';

/// Publisher-side simulcast layer pausing (`docs/design.md` §6.2): a
/// publisher stops encoding the simulcast layers of its video that no one
/// in the room pulls, and resumes them as soon as someone asks.
///
/// The SFU doesn't tell a publisher which layers its subscribers pull, so
/// rooms tell each other through signaling: each participant announces the
/// layer it pulls of every track ([ParticipantState.layerDemand]), and each
/// publisher keeps every layer from the lowest up to the highest one
/// anyone asks for. Layers above that are paused (`active: false` on the
/// encoding), which saves the publisher's uplink, CPU and battery, and the
/// SFU's work.
///
/// Set with [RoomOptions.layerPausing]. **Pausing is off by default**
/// ([enabled]); reporting is on. Measured against the real SFU (M12), a
/// subscriber that switches up (`tracks/update`) to a layer that was paused
/// often stays on a lower layer for good, although a new pull of the
/// resumed layer gets it in about 1.5 s; see `docs/design.md` §6.2. Turn
/// it on ([LayerPausingOptions.on]) where uplink and battery matter more
/// than how fast a view gets sharper, for example for big rooms of small
/// tiles.
///
/// **Not on Windows or Linux:** flutter_webrtc ignores encoding changes
/// there, so such a publisher keeps every layer on and reports a
/// [RoomErrorEvent] `layerPausing` once. Its participants still report
/// their demand.
@immutable
final class LayerPausingOptions {
  /// Creates layer pausing options.
  const LayerPausingOptions({
    this.enabled = false,
    this.reportDemand = true,
    this.minActiveLayers = 1,
    this.pauseDelay = const Duration(seconds: 5),
  }) : assert(minActiveLayers >= 1, 'minActiveLayers must be at least 1');

  /// Pausing on, with the default delay and floor.
  static const on = LayerPausingOptions(enabled: true);

  /// Whether this room pauses the layers of its own simulcast video that no
  /// one pulls. Default `false` (see above). Without it the room still
  /// reports which layers it pulls ([reportDemand]), so publishers that
  /// pause can.
  final bool enabled;

  /// Whether this room announces the layer it pulls of each remote track
  /// ([ParticipantState.layerDemand]). Default `true`. Without it, other
  /// publishers assume this participant pulls every layer of every track,
  /// and pause nothing while it is in the room.
  final bool reportDemand;

  /// How many of the lowest layers always stay on, whatever the demand.
  /// Default 1: the lowest layer, so a new subscriber gets a frame at once
  /// (the SFU falls back to it while the layer it asked for resumes).
  final int minActiveLayers;

  /// How long a layer must have been unwanted before it is paused. A layer
  /// that someone asks for again within this time is never paused, so a
  /// view that shrinks and grows back (a layout change, scrolling) doesn't
  /// wait for the layer to resume. Resuming is immediate. Default 5 s.
  final Duration pauseDelay;

  @override
  bool operator ==(Object other) =>
      other is LayerPausingOptions &&
      other.enabled == enabled &&
      other.reportDemand == reportDemand &&
      other.minActiveLayers == minActiveLayers &&
      other.pauseDelay == pauseDelay;

  @override
  int get hashCode =>
      Object.hash(enabled, reportDemand, minActiveLayers, pauseDelay);

  @override
  String toString() =>
      'LayerPausingOptions(enabled: $enabled, reportDemand: $reportDemand, '
      'minActiveLayers: $minActiveLayers, pauseDelay: $pauseDelay)';
}

/// The layers of one publication to keep sending.
///
/// [ladder] is the publication's layers that the encoder sends, highest
/// first. [wishes] has one entry per participant that may pull the track:
/// the RID it asks for, or `null` for one that wants every layer (it
/// doesn't report its demand, or asks for a RID the publisher doesn't
/// know). A RID of the announced simulcast that the encoder doesn't send
/// ([allRids] but not [ladder], below the ladder's lowest layer) counts as
/// the lowest layer.
///
/// Keeps every layer from the lowest up to the highest one wished for,
/// plus the lowest [minActiveLayers]. Lower layers stay on even when no
/// one asks for them: they are cheap, the SFU falls back to them while a
/// paused layer resumes, and a subscriber whose SFU steps down under
/// bandwidth pressure (`priorityOrdering`) needs them.
///
/// Internal: not exported from the package barrel.
Set<String> layersToSend({
  required List<String> ladder,
  required Iterable<String?> wishes,
  List<String>? allRids,
  int minActiveLayers = 1,
}) {
  if (ladder.isEmpty) return const {};
  var ceiling = ladder.length; // No wish: none above the floor.
  for (final wish in wishes) {
    var rank = wish == null ? 0 : ladder.indexOf(wish);
    if (rank < 0) {
      // A RID the encoder doesn't send: the lowest layer if the publisher
      // announced it (the encoder's layer limit dropped it), else unknown.
      rank = (allRids?.contains(wish) ?? false) ? ladder.length - 1 : 0;
    }
    if (rank < ceiling) ceiling = rank;
    if (ceiling == 0) break;
  }
  final floor = (ladder.length - minActiveLayers).clamp(0, ladder.length);
  final from = ceiling < floor ? ceiling : floor;
  return {...ladder.sublist(from)};
}

/// Pauses and resumes the layers of one publication: a layer is resumed as
/// soon as it is wanted, and paused only after it has been unwanted for
/// [pauseDelay].
///
/// [update] takes the layers that can be paused and the ones to send;
/// [apply] is called (never concurrently, with the latest set) whenever
/// [paused] changes.
///
/// Internal: not exported from the package barrel.
class LayerPauser {
  /// Creates a pauser that applies the paused set with [apply].
  LayerPauser({required this.apply, required this.pauseDelay});

  /// Applies the paused set to the encoder. Errors are the caller's to
  /// handle; they don't stop later calls.
  final Future<void> Function(Set<String> paused) apply;

  /// How long a layer must stay unwanted before it is paused.
  final Duration pauseDelay;

  late final CoalescingRunner _runner = CoalescingRunner(_apply);
  Set<String> _paused = const {};
  Set<String>? _applied = const {};
  // Unwanted layers waiting out [pauseDelay], with the time they became
  // unwanted.
  final Map<String, DateTime> _pending = {};
  Timer? _timer;
  bool _disposed = false;

  /// The layers paused now.
  Set<String> get paused => _paused;

  /// Layers unwanted now but not paused yet.
  Set<String> get pending => Set.unmodifiable(_pending.keys);

  /// Called when [paused] changes.
  VoidCallback? onChanged;

  /// Takes the current demand: [send] are the layers to keep sending, out
  /// of the [layers] that can be paused (others are left as they are).
  void update({required Set<String> layers, required Set<String> send}) {
    if (_disposed) return;
    final unwanted = layers.difference(send);
    // Resume at once whatever is wanted again (or no longer pausable).
    final keep = _paused.intersection(unwanted);
    final now = clock.now();
    _pending.removeWhere((rid, _) => !unwanted.contains(rid));
    for (final rid in unwanted) {
      if (!keep.contains(rid)) _pending.putIfAbsent(rid, () => now);
    }
    _setPaused(keep);
    _schedule();
  }

  /// Resumes every layer and stops pausing.
  void resumeAll() {
    _pending.clear();
    _timer?.cancel();
    _timer = null;
    _setPaused(const {});
  }

  /// Makes the encoder state match [paused] again, for example after the
  /// publication moved to a new session.
  void reapply() {
    if (_disposed) return;
    _applied = null;
    unawaited(_runner.run());
  }

  void _setPaused(Set<String> next) {
    if (setEquals(next, _paused)) return;
    _paused = Set.unmodifiable(next);
    onChanged?.call();
    unawaited(_runner.run());
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (_pending.isEmpty) return;
    final first = _pending.values.reduce((a, b) => a.isBefore(b) ? a : b);
    var wait = first.add(pauseDelay).difference(clock.now());
    if (wait.isNegative) wait = Duration.zero;
    _timer = Timer(wait, _onTimer);
  }

  void _onTimer() {
    _timer = null;
    if (_disposed) return;
    final now = clock.now();
    final due = [
      for (final MapEntry(key: rid, value: since) in _pending.entries)
        if (!since.add(pauseDelay).isAfter(now)) rid,
    ];
    for (final rid in due) {
      _pending.remove(rid);
    }
    _setPaused({..._paused, ...due});
    _schedule();
  }

  Future<void> _apply() async {
    if (_disposed) return;
    final target = _paused;
    if (_applied != null && setEquals(_applied, target)) return;
    try {
      await apply(target);
      _applied = target;
    } catch (_) {
      // Reported by [apply]'s owner; the next change tries again.
      _applied = null;
    }
  }

  /// Stops the timer. Nothing is applied afterwards.
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _pending.clear();
  }
}
