/// @docImport 'simulcast_layer_reporter.dart';
library;

import 'dart:async';

import 'layer_selection.dart';
import 'simulcast_ladder.dart';

/// Receives the rendered size of video views, per subscription.
///
/// [SimulcastLayerReporter] reports into this. The Room implements it (by
/// delegating to its [LayerSelectionController]) and hands it to the app,
/// so the widget stays decoupled from the Room.
///
/// A subscription can be shown by several views at once (a gallery tile and
/// a picture-in-picture, say). Each view reports under its own [viewKey];
/// the subscription gets the layer the biggest visible view needs.
abstract interface class LayerDemandReporter {
  /// Records that [viewKey] shows [subscriptionId] at [demand].
  void reportDemand(String subscriptionId, Object viewKey, TileDemand demand);

  /// Records that [viewKey] no longer shows [subscriptionId].
  void removeView(String subscriptionId, Object viewKey);
}

/// Called when a subscription's chosen layer changes.
typedef LayerPreferenceListener =
    void Function(String subscriptionId, LayerPreference preference);

class _Subscription {
  _Subscription(this.ladder);

  SimulcastLadder ladder;
  final Map<Object, TileDemand> views = {};
  LayerPreference? emitted;
  LayerPreference? pending;
  Timer? timer;
}

/// Aggregates view sizes per subscription, picks a layer with a
/// [SimulcastLayerPolicy], and debounces the changes.
///
/// - **Aggregation:** each view's demand is run through the policy (with
///   the subscription's current layer, for hysteresis), and the highest
///   resulting layer wins. With no visible view, the subscription is
///   [LayerPreference.paused].
/// - **Debounce:** the first choice for a subscription (after its first
///   view reports) is emitted at once, so a new pull can start with the
///   right layer, and so is a change from paused to a layer, so video
///   appears as soon as a tile scrolls into view. Every other change
///   (between layers, or to paused) is emitted only after the new choice
///   has stood for [LayerSelectionConfig.debounce]; if the choice goes back
///   to the emitted one before then, nothing is emitted.
/// - [onChange] is called synchronously, from [reportDemand],
///   [removeView] or [setLadder] for the immediate cases and from a timer
///   otherwise.
///
/// Subscription IDs are the Room's; typically the pulled track's SFU
/// `trackName` together with the publisher's session.
///
/// Internal: not exported from the package barrel. The Room owns one.
class LayerSelectionController implements LayerDemandReporter {
  /// Creates a controller that reports changes to [onChange].
  ///
  /// [defaultLadder] is used for a subscription until [setLadder] is called
  /// for it; it defaults to [SimulcastLadder.h720].
  LayerSelectionController({
    required this.onChange,
    this.config = const LayerSelectionConfig(),
    SimulcastLadder? defaultLadder,
  }) : _policy = SimulcastLayerPolicy(config),
       defaultLadder = defaultLadder ?? SimulcastLadder.h720;

  /// The tuning.
  final LayerSelectionConfig config;

  /// The ladder assumed for subscriptions without their own.
  final SimulcastLadder defaultLadder;

  /// Receives layer changes.
  final LayerPreferenceListener onChange;

  final SimulcastLayerPolicy _policy;
  final Map<String, _Subscription> _subscriptions = {};
  bool _disposed = false;

  /// The policy in use, for building `simulcast` request objects with
  /// [SimulcastLayerPolicy.simulcastConfig].
  SimulcastLayerPolicy get policy => _policy;

  /// The subscription IDs currently tracked.
  Iterable<String> get subscriptionIds => _subscriptions.keys;

  /// The layer last emitted for [subscriptionId], or `null` if none was.
  LayerPreference? preferenceFor(String subscriptionId) =>
      _subscriptions[subscriptionId]?.emitted;

  /// Sets the publisher's ladder for [subscriptionId], and re-evaluates.
  void setLadder(String subscriptionId, SimulcastLadder ladder) {
    if (_disposed) return;
    final sub = _subscriptions.putIfAbsent(
      subscriptionId,
      () => _Subscription(ladder),
    );
    if (sub.ladder == ladder) return;
    sub.ladder = ladder;
    _evaluate(subscriptionId, sub);
  }

  @override
  void reportDemand(String subscriptionId, Object viewKey, TileDemand demand) {
    if (_disposed) return;
    final sub = _subscriptions.putIfAbsent(
      subscriptionId,
      () => _Subscription(defaultLadder),
    );
    if (sub.views[viewKey] == demand) return;
    sub.views[viewKey] = demand;
    _evaluate(subscriptionId, sub);
  }

  @override
  void removeView(String subscriptionId, Object viewKey) {
    if (_disposed) return;
    final sub = _subscriptions[subscriptionId];
    if (sub == null || sub.views.remove(viewKey) == null) return;
    _evaluate(subscriptionId, sub);
  }

  /// Forgets [subscriptionId] (the track was closed). Emits nothing.
  void removeSubscription(String subscriptionId) {
    _subscriptions.remove(subscriptionId)?.timer?.cancel();
  }

  /// Emits any pending change now instead of after the debounce.
  void flush() {
    for (final entry in _subscriptions.entries.toList()) {
      final sub = entry.value;
      if (sub.timer?.isActive ?? false) {
        sub.timer!.cancel();
        _fire(entry.key, sub);
      }
    }
  }

  /// Cancels the timers. Nothing is emitted afterwards.
  void dispose() {
    _disposed = true;
    for (final sub in _subscriptions.values) {
      sub.timer?.cancel();
    }
    _subscriptions.clear();
  }

  LayerPreference _desired(_Subscription sub) {
    String? best;
    int? bestRank;
    final current = sub.emitted?.rid;
    for (final demand in sub.views.values) {
      final choice = _policy.choose(demand, sub.ladder, currentRid: current);
      final rid = choice.rid;
      if (rid == null) continue;
      final rank = sub.ladder.rankOf(rid)!;
      if (bestRank == null || rank < bestRank) {
        best = rid;
        bestRank = rank;
      }
    }
    return best == null
        ? const LayerPreference.paused()
        : LayerPreference.rid(best);
  }

  void _evaluate(String subscriptionId, _Subscription sub) {
    final emitted = sub.emitted;
    // Nothing to say before the first view reports.
    if (emitted == null && sub.views.isEmpty) return;
    final desired = _desired(sub);
    if (emitted == null || (emitted.isPaused && !desired.isPaused)) {
      // First choice, or a paused track becoming visible: no delay.
      sub.timer?.cancel();
      sub.timer = null;
      sub.pending = null;
      sub.emitted = desired;
      onChange(subscriptionId, desired);
      return;
    }
    if (desired == emitted) {
      sub.timer?.cancel();
      sub.timer = null;
      sub.pending = null;
      return;
    }
    if (desired == sub.pending && (sub.timer?.isActive ?? false)) return;
    sub.pending = desired;
    sub.timer?.cancel();
    sub.timer = Timer(config.debounce, () => _fire(subscriptionId, sub));
  }

  void _fire(String subscriptionId, _Subscription sub) {
    sub.timer = null;
    sub.pending = null;
    if (_disposed || !identical(_subscriptions[subscriptionId], sub)) return;
    // Re-evaluate: the views may have changed without changing the choice.
    final desired = _desired(sub);
    if (desired == sub.emitted) return;
    sub.emitted = desired;
    onChange(subscriptionId, desired);
  }
}
