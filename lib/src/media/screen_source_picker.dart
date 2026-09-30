/// @docImport 'screen_share_source.dart';
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';

import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'flutter_webrtc_media_backend.dart';
import 'media_backend.dart';
import 'media_errors.dart';
import 'media_types.dart';

/// A snapshot of a [ScreenSourcePicker]: the sources to show, whether a
/// listing is in progress, and the last listing error.
@immutable
class ScreenPickerState {
  /// Creates a snapshot.
  ScreenPickerState({
    List<ScreenSource> sources = const [],
    this.isLoading = false,
    this.error,
  }) : sources = List.unmodifiable(sources);

  /// Every listed source: screens first, then windows, each in the
  /// platform's order.
  final List<ScreenSource> sources;

  /// Whether a listing is in progress. [sources] still holds the previous
  /// list meanwhile.
  final bool isLoading;

  /// Why the last listing failed, or `null` if it succeeded. [sources] may
  /// still hold a usable list (the previous one, or the windows when no
  /// screen was listed). Call [ScreenSourcePicker.refresh] to retry.
  final ScreenSourcesException? error;

  /// The whole-display sources.
  List<ScreenSource> get screens =>
      sources.where((s) => s.type == ScreenSourceType.screen).toList();

  /// The single-window sources.
  List<ScreenSource> get windows =>
      sources.where((s) => s.type == ScreenSourceType.window).toList();

  /// Returns a copy with the given fields replaced. [error] is always
  /// replaced (pass it again to keep it).
  ScreenPickerState copyWith({
    List<ScreenSource>? sources,
    bool? isLoading,
    ScreenSourcesException? error,
  }) => ScreenPickerState(
    sources: sources ?? this.sources,
    isLoading: isLoading ?? this.isLoading,
    error: error,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenPickerState &&
      const ListEquality<ScreenSource>().equals(other.sources, sources) &&
      other.isLoading == isLoading &&
      other.error == error;

  @override
  int get hashCode => Object.hash(
    const ListEquality<ScreenSource>().hash(sources),
    isLoading,
    error,
  );

  @override
  String toString() =>
      'ScreenPickerState(${sources.length} sources, loading: $isLoading, '
      'error: $error)';
}

/// The model behind a desktop "choose what to share" dialog: the screens
/// and windows that can be shared, with thumbnails, kept up to date.
///
/// It lists sources with `desktopCapturer.getSources`, then re-scans every
/// [refreshInterval] so that opened and closed windows, renamed windows and
/// new thumbnails show up (the plugin only reports changes while someone
/// re-scans). On Windows the first listing has no thumbnails; they follow
/// with the first re-scan, which starts right away.
///
/// Listing failures (flutter-webrtc #1539, #1085) never throw: they appear
/// as [ScreenPickerState.error], and [refresh] retries.
///
/// Only one picker should be active at a time, because the plugin keeps a
/// single, global source list. Hand the chosen [ScreenSource] to
/// [ScreenShareSource.start]. Desktop only; see [isSupported].
class ScreenSourcePicker {
  /// Creates a picker. It lists nothing until [start].
  ///
  /// [retries] is how many times a failed listing is retried at once before
  /// the error is shown.
  ScreenSourcePicker({
    MediaBackend backend = const FlutterWebrtcMediaBackend(),
    Set<ScreenSourceType> types = const {
      ScreenSourceType.screen,
      ScreenSourceType.window,
    },
    this.thumbnailSize = (width: 320, height: 180),
    this.refreshInterval = const Duration(seconds: 3),
    this.retries = 1,
  }) : _media = backend,
       types = Set.unmodifiable(types);

  final MediaBackend _media;

  /// The source types listed.
  final Set<ScreenSourceType> types;

  /// The requested thumbnail size. Platforms scale to fit.
  final ({int width, int height})? thumbnailSize;

  /// How often sources are re-scanned while started.
  final Duration refreshInterval;

  /// How many times a failed listing is retried at once.
  final int retries;

  final StateStream<ScreenPickerState> _state = StateStream(
    ScreenPickerState(),
    distinct: true,
  );
  late final CoalescingRunner _loader = CoalescingRunner(_load);
  final List<StreamSubscription<ScreenSource>> _subscriptions = [];
  Timer? _timer;
  Future<void>? _started;
  bool _disposed = false;

  /// Whether desktop source listing exists on this platform. `false` on
  /// the web (the browser has its own picker) and on mobile.
  bool get isSupported => _media.desktopCapturer != null;

  /// The picker's state. Replays the current value.
  Stream<ScreenPickerState> get state => _state.stream;

  /// The picker's current state.
  ScreenPickerState get currentState => _state.value;

  /// Starts listing and watching sources. Completes when the first listing
  /// has finished (successfully or not). Calling it again does nothing.
  ///
  /// Throws [UnsupportedError] if not [isSupported].
  Future<void> start() {
    final capturer = _media.desktopCapturer;
    if (capturer == null) {
      throw UnsupportedError(
        'Listing screens and windows needs a desktop platform. On the web, '
        'ScreenShareSource.start() shows the browser picker.',
      );
    }
    if (_disposed) throw StateError('This ScreenSourcePicker was disposed.');
    final started = _started;
    if (started != null) return started;
    _subscriptions.addAll([
      capturer.onAdded.listen(_onAdded),
      capturer.onRemoved.listen(_onRemoved),
      capturer.onNameChanged.listen(_onChanged),
      capturer.onThumbnailChanged.listen(_onChanged),
    ]);
    return _started = _loader.run();
  }

  /// Lists the sources again from scratch. Use it to retry after an
  /// [ScreenPickerState.error].
  Future<void> refresh() {
    if (_started == null || _disposed) return Future.value();
    return _loader.run();
  }

  Future<void> _load() async {
    final capturer = _media.desktopCapturer!;
    _timer?.cancel();
    _timer = null;
    _setState(
      currentState.copyWith(isLoading: true, error: currentState.error),
    );
    Object? lastError;
    for (var attempt = 0; attempt <= retries; attempt++) {
      if (_disposed) return;
      try {
        final listed = await capturer.getSources(
          types: types,
          thumbnailSize: thumbnailSize,
        );
        if (_disposed) return;
        final sources = _ordered(listed.where((s) => types.contains(s.type)));
        final noScreens =
            types.contains(ScreenSourceType.screen) &&
            !sources.any((s) => s.type == ScreenSourceType.screen);
        _setState(
          ScreenPickerState(
            sources: sources,
            error: noScreens
                ? const ScreenSourcesException(
                    'No screens were listed.',
                    noScreens: true,
                  )
                : null,
          ),
        );
        _startUpdates();
        return;
      } catch (error) {
        lastError = error;
      }
    }
    _setState(
      currentState.copyWith(
        isLoading: false,
        error: ScreenSourcesException(
          'Listing screens and windows failed.',
          cause: lastError,
        ),
      ),
    );
    // Keep watching: a later re-scan may still report sources.
    _startUpdates();
  }

  void _startUpdates() {
    if (_disposed) return;
    _timer?.cancel();
    _timer = Timer.periodic(refreshInterval, (_) => _update());
    _update(); // Thumbnails on Windows arrive with the first re-scan.
  }

  Future<void> _update() async {
    if (_disposed) return;
    try {
      await _media.desktopCapturer!.updateSources(types: types);
    } catch (error) {
      debugPrint('cloudflare_realtime: updateSources failed: $error');
    }
  }

  List<ScreenSource> _ordered(Iterable<ScreenSource> sources) => [
    ...sources.where((s) => s.type == ScreenSourceType.screen),
    ...sources.where((s) => s.type == ScreenSourceType.window),
  ];

  void _onAdded(ScreenSource source) {
    if (!types.contains(source.type)) return;
    final sources = currentState.sources;
    if (sources.any((s) => s.id == source.id)) return;
    _setState(
      currentState.copyWith(
        sources: _ordered([...sources, source]),
        error: currentState.error,
      ),
    );
  }

  void _onRemoved(ScreenSource source) {
    final sources = currentState.sources;
    if (!sources.any((s) => s.id == source.id)) return;
    _setState(
      currentState.copyWith(
        sources: [
          for (final s in sources)
            if (s.id != source.id) s,
        ],
        error: currentState.error,
      ),
    );
  }

  void _onChanged(ScreenSource source) {
    final sources = currentState.sources;
    if (!sources.any((s) => s.id == source.id)) return;
    _setState(
      currentState.copyWith(
        sources: [
          for (final s in sources)
            if (s.id == source.id)
              s.copyWith(name: source.name, thumbnail: source.thumbnail)
            else
              s,
        ],
        error: currentState.error,
      ),
    );
  }

  void _setState(ScreenPickerState state) {
    if (!_state.isClosed) _state.set(state);
  }

  /// Stops watching sources and completes [state].
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _state.close();
  }
}
