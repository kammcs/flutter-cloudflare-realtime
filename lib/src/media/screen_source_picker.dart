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
import 'thumbnail_check.dart';

/// A snapshot of a [ScreenSourcePicker]: the sources to show, whether a
/// listing is in progress, the last listing error, and whether the OS
/// seems to block screen capture.
@immutable
class ScreenPickerState {
  /// Creates a snapshot.
  ScreenPickerState({
    List<ScreenSource> sources = const [],
    this.isLoading = false,
    this.error,
    this.permissionProblem,
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

  /// Set when the listing looks like the OS denies screen capture (macOS
  /// only): no screens were listed, or every screen's thumbnail is empty or
  /// black. Show its [ScreenCapturePermissionException.guidance]; a share
  /// would start but send no frames. It clears once a listing looks normal.
  final ScreenCapturePermissionException? permissionProblem;

  /// The whole-display sources.
  List<ScreenSource> get screens =>
      sources.where((s) => s.type == ScreenSourceType.screen).toList();

  /// The single-window sources.
  List<ScreenSource> get windows =>
      sources.where((s) => s.type == ScreenSourceType.window).toList();

  /// Returns a copy with the given fields replaced. [error] is always
  /// replaced (pass it again to keep it); [permissionProblem] is kept
  /// unless given.
  ScreenPickerState copyWith({
    List<ScreenSource>? sources,
    bool? isLoading,
    ScreenSourcesException? error,
    ScreenCapturePermissionException? permissionProblem,
  }) => ScreenPickerState(
    sources: sources ?? this.sources,
    isLoading: isLoading ?? this.isLoading,
    error: error,
    permissionProblem: permissionProblem ?? this.permissionProblem,
  );

  @override
  bool operator ==(Object other) =>
      other is ScreenPickerState &&
      const ListEquality<ScreenSource>().equals(other.sources, sources) &&
      other.isLoading == isLoading &&
      other.error == error &&
      other.permissionProblem == permissionProblem;

  @override
  int get hashCode => Object.hash(
    const ListEquality<ScreenSource>().hash(sources),
    isLoading,
    error,
    permissionProblem,
  );

  @override
  String toString() =>
      'ScreenPickerState(${sources.length} sources, loading: $isLoading, '
      'error: $error${permissionProblem == null ? '' : ', permission'})';
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
/// Thumbnails are kept across listings: `flutter_webrtc` delivers them in
/// source events (macOS: while listing; Windows: on the first re-scan) and
/// a fresh listing carries none, so each source keeps its last thumbnail.
/// An empty thumbnail (macOS sends one when it can't capture) reads as
/// none.
///
/// **macOS Screen Recording permission.** `flutter_webrtc` doesn't report
/// it, so on macOS the picker looks for its symptoms: no screens listed, or
/// every screen's thumbnail empty or black. Then
/// [ScreenPickerState.permissionProblem] is set (see
/// [ScreenCapturePermissionException]).
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
  bool _listed = false;

  /// The last non-empty thumbnail seen per source ID, so that a new listing
  /// (which carries none) keeps them.
  final Map<String, Uint8List> _thumbnails = {};

  /// Per source ID, whether its last thumbnail was blank (macOS only).
  final Map<String, bool> _blank = {};

  bool get _checksPermission => _media.platform == MediaPlatform.macos;

  /// Whether desktop source listing exists on this platform. `false` on
  /// the web (the browser has its own picker) and on mobile.
  bool get isSupported => _media.desktopCapturer != null;

  /// The picker's state. Replays the current value.
  Stream<ScreenPickerState> get stateChanges => _state.stream;

  /// The picker's current state.
  ScreenPickerState get state => _state.value;

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
      state.copyWith(isLoading: true, error: state.error),
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
        final sources = _ordered(
          listed.where((s) => types.contains(s.type)).map(_remember),
        );
        _listed = true;
        final ids = {for (final s in sources) s.id};
        _thumbnails.removeWhere((id, _) => !ids.contains(id));
        _blank.removeWhere((id, _) => !ids.contains(id));
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
      state.copyWith(
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

  /// Records [source]'s thumbnail (and, on macOS, whether it is blank), and
  /// returns [source] with its latest non-empty thumbnail, or none.
  ScreenSource _remember(ScreenSource source) {
    final thumbnail = source.thumbnail;
    if (thumbnail == null) {
      final kept = _thumbnails[source.id];
      return kept == null ? source : source.copyWith(thumbnail: kept);
    }
    if (_checksPermission) {
      final blank = thumbnailLooksBlank(thumbnail);
      if (blank != null) _blank[source.id] = blank;
    }
    if (thumbnail.isNotEmpty) {
      _thumbnails[source.id] = thumbnail;
      return source;
    }
    _thumbnails.remove(source.id);
    return ScreenSource(id: source.id, name: source.name, type: source.type);
  }

  void _onAdded(ScreenSource source) {
    if (!types.contains(source.type)) return;
    final sources = state.sources;
    if (sources.any((s) => s.id == source.id)) {
      // Announced again (the plugin re-lists): keep its new thumbnail.
      _onChanged(source);
      return;
    }
    _setState(
      state.copyWith(
        sources: _ordered([...sources, _remember(source)]),
        error: state.error,
      ),
    );
  }

  void _onRemoved(ScreenSource source) {
    _thumbnails.remove(source.id);
    _blank.remove(source.id);
    final sources = state.sources;
    if (!sources.any((s) => s.id == source.id)) return;
    _setState(
      state.copyWith(
        sources: [
          for (final s in sources)
            if (s.id != source.id) s,
        ],
        error: state.error,
      ),
    );
  }

  void _onChanged(ScreenSource source) {
    final sources = state.sources;
    if (!sources.any((s) => s.id == source.id)) return;
    final changed = _remember(source);
    _setState(
      state.copyWith(
        sources: [
          for (final s in sources)
            if (s.id == source.id)
              ScreenSource(
                id: s.id,
                name: changed.name,
                type: s.type,
                thumbnail: changed.thumbnail,
              )
            else
              s,
        ],
        error: state.error,
      ),
    );
  }

  void _setState(ScreenPickerState state) {
    if (_state.isClosed) return;
    _state.set(
      ScreenPickerState(
        sources: state.sources,
        isLoading: state.isLoading,
        error: state.error,
        permissionProblem: _permissionProblem(state),
      ),
    );
  }

  /// The macOS Screen Recording symptoms in [state], if any.
  ScreenCapturePermissionException? _permissionProblem(
    ScreenPickerState state,
  ) {
    if (!_checksPermission || !_listed) return null;
    if (!types.contains(ScreenSourceType.screen)) return null;
    final screens = state.screens;
    if (screens.isEmpty) {
      return (state.error?.noScreens ?? false)
          ? const ScreenCapturePermissionException(
              'No screens were listed: Screen Recording permission is '
              'probably missing.',
            )
          : null;
    }
    if (screens.every((s) => _blank[s.id] ?? false)) {
      return const ScreenCapturePermissionException(
        'Every screen thumbnail is empty or black: Screen Recording '
        'permission is probably missing.',
      );
    }
    return null;
  }

  /// Stops watching sources and completes [stateChanges].
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
