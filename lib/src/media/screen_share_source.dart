/// @docImport 'screen_source_picker.dart';
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../signaling/participant_state.dart';
import '../util/state_stream.dart';
import 'constraints.dart';
import 'flutter_webrtc_media_backend.dart';
import 'local_media_source.dart';
import 'media_backend.dart';
import 'media_errors.dart';
import 'media_types.dart';
import 'release.dart';

/// Why a screen share ended.
enum ScreenShareEndReason {
  /// The app stopped it: [LocalMediaSource.disable], [ScreenShareSource.stop],
  /// muting with [MutePolicy.releaseCapture], or dispose.
  stopped,

  /// The user stopped it outside the app, with the browser's "Stop sharing"
  /// button (web only).
  userStopped,

  /// The shared window closed or the shared display went away (desktop), or
  /// the platform ended the track.
  sourceClosed,
}

/// A screen, window or browser-tab share, with the same mute model as the
/// camera and microphone.
///
/// - **Desktop** (Windows, macOS, Linux): pick a [ScreenSource] with a
///   [ScreenSourcePicker], then [start] with it. The share is captured with
///   `getDisplayMedia` and `deviceId: {exact: source.id}`.
/// - **Web:** [start] without a source; the browser shows its own picker.
///   If the user cancels it, [start] returns `false` and nothing is
///   reported on [errors].
/// - **Android and iOS** need host-app setup (a MediaProjection foreground
///   service; a Broadcast Upload Extension) that this package doesn't cover
///   yet (roadmap M6). [start] and [enable] throw [UnsupportedError] there.
///
/// **Ending.** [ended] reports every end of a share with its reason, and the
/// source turns off. On the web the browser ends the track when the user
/// clicks "Stop sharing". Native `flutter_webrtc` never fires a track's
/// `onEnded`, so on desktop the source watches the capturer's source list
/// instead, and ends the share when the shared window or display goes away.
///
/// [track] carries the video track. With [ScreenShareOptions.captureAudio]
/// on a platform that supports it, [audioTrack] carries system or tab
/// audio; broadcasting applies to both.
///
/// Defaults to [MutePolicy.releaseCapture]: [stopBroadcasting] ends the
/// share.
class ScreenShareSource extends LocalMediaSource {
  /// Creates a screen share source. It captures nothing until [start].
  ///
  /// On desktop, [sourceWatchInterval] is how often the source list is
  /// re-scanned while sharing, to notice the shared window closing.
  ScreenShareSource({
    MediaBackend backend = const FlutterWebrtcMediaBackend(),
    ScreenShareOptions options = const ScreenShareOptions(),
    super.mutePolicy = MutePolicy.releaseCapture,
    this.sourceWatchInterval = const Duration(seconds: 3),
  }) : _media = backend,
       _wantedOptions = options,
       super(kind: TrackKind.video, source: TrackSource.screen);

  /// All source types, re-scanned together so the plugin's source list
  /// always has every source `getDisplayMedia` might be asked for.
  static const _allTypes = {ScreenSourceType.screen, ScreenSourceType.window};

  final MediaBackend _media;

  /// How often the desktop source list is re-scanned while sharing.
  final Duration sourceWatchInterval;

  ScreenShareOptions _wantedOptions;
  ScreenSource? _selected;
  String? _capturedSourceId;
  ScreenShareOptions? _capturedOptions;
  ScreenShareEndReason? _endReason;
  StreamSubscription<ScreenSource>? _removedSubscription;
  Timer? _watchTimer;
  final StateStream<CapturedTrack?> _audioTrack = StateStream(
    null,
    distinct: true,
  );
  final StateStream<CapturedTrack?> _broadcastAudioTrack = StateStream(
    null,
    distinct: true,
  );
  final StreamController<ScreenShareEndReason> _ended =
      StreamController.broadcast();

  /// Whether screen share is implemented on this platform (desktop and
  /// web).
  bool get isSupported =>
      _media.platform.isDesktop || _media.platform == MediaPlatform.web;

  /// Whether the browser picks the source (web) rather than the app
  /// (desktop).
  bool get usesBrowserPicker => _media.platform == MediaPlatform.web;

  /// The desktop source chosen with [start] or [select]. Always `null` on
  /// the web.
  ScreenSource? get selectedSource => _selected;

  /// The capture options.
  ScreenShareOptions get options => _wantedOptions;

  /// The system or tab audio track, if the share has one. Replays the
  /// current value.
  Stream<CapturedTrack?> get audioTrack => _audioTrack.stream;

  /// The system or tab audio track, or `null`.
  CapturedTrack? get currentAudioTrack => _audioTrack.value;

  /// [currentAudioTrack] while broadcasting, else `null`. Replays the
  /// current value.
  Stream<CapturedTrack?> get broadcastAudioTrack => _broadcastAudioTrack.stream;

  /// [currentAudioTrack] while broadcasting, else `null`.
  CapturedTrack? get currentBroadcastAudioTrack => _broadcastAudioTrack.value;

  /// Emits once each time a running share ends, with the reason.
  Stream<ScreenShareEndReason> get ended => _ended.stream;

  /// Sets the source (desktop) and options for the next capture. If a share
  /// is running, it switches to the new source and waits for that.
  ///
  /// Does not start a share.
  Future<void> select(ScreenSource source, {ScreenShareOptions? options}) {
    _checkSupported();
    if (usesBrowserPicker) {
      throw UnsupportedError(
        'On the web the browser picks the source; call start() without one.',
      );
    }
    _selected = source;
    if (options != null) _wantedOptions = options;
    return requestReconcile();
  }

  /// Starts sharing [source] (desktop), or asks the browser to show its
  /// picker (web; [source] must be `null`).
  ///
  /// If a share is already running, switches it to [source] and [options].
  /// Returns whether the share is running afterwards; failures go to
  /// [errors]. Throws [UnsupportedError] on Android and iOS, and an
  /// [ArgumentError] on desktop if no source was given or selected before.
  Future<bool> start({ScreenSource? source, ScreenShareOptions? options}) {
    _checkSupported();
    if (source != null && usesBrowserPicker) {
      throw ArgumentError.value(
        source,
        'source',
        'The browser picks the source on the web; pass none.',
      );
    }
    if (source != null) _selected = source;
    if (options != null) _wantedOptions = options;
    return enable();
  }

  /// Ends the share. Same as [disable].
  Future<void> stop() => disable();

  /// Starts the share with the selected source. See [start].
  @override
  Future<bool> enable() {
    _checkSupported();
    if (!usesBrowserPicker && _selected == null && !isDisposed) {
      throw ArgumentError(
        'Choose a ScreenSource first: start(source: ...) or select(...).',
      );
    }
    return super.enable();
  }

  void _checkSupported() {
    if (isSupported) return;
    throw UnsupportedError(
      'Screen share on ${_media.platform.name} is not implemented yet. '
      'Android needs a MediaProjection foreground service and iOS a '
      'Broadcast Upload Extension in the host app (roadmap M6).',
    );
  }

  @override
  void didChangeState() {
    if (_broadcastAudioTrack.isClosed) return;
    _broadcastAudioTrack.set(
      isEnabled && isBroadcasting ? _audioTrack.value : null,
    );
  }

  @override
  Future<void> reconcile() async {
    if (!isEnabled) {
      await _release(_endReason ?? ScreenShareEndReason.stopped);
      return;
    }
    final wantedId = usesBrowserPicker ? null : _selected?.id;
    if (currentTrack != null &&
        _capturedSourceId == wantedId &&
        _capturedOptions == _wantedOptions) {
      return;
    }
    // Switching: release first. On Windows, stopping any desktop capturer
    // also stops the (single) loopback audio capturer, so the new share must
    // start after the old one has stopped.
    await _release(null);
    if (!isEnabled) return;

    final MediaStream stream;
    try {
      stream = wantedId == null
          ? await _media.getDisplayMedia(webScreenConstraints(_wantedOptions))
          : await _captureDesktop(wantedId);
    } on ScreenSourceNotFoundException catch (error) {
      fail(error);
      return;
    } catch (error) {
      if (usesBrowserPicker && isPermissionError(error)) {
        // The user closed the browser's picker: not an error.
        turnOff();
      } else if (isPermissionError(error)) {
        fail(
          MediaPermissionDeniedException(
            'Screen capture permission was denied.',
            cause: error,
          ),
        );
      } else {
        fail(MediaCaptureException('Screen capture failed.', cause: error));
      }
      return;
    }
    final videoTracks = stream.getVideoTracks();
    if (videoTracks.isEmpty) {
      await releaseStream(stream);
      fail(const MediaCaptureException('getDisplayMedia returned no video.'));
      return;
    }
    if (!isEnabled || isDisposed) {
      await releaseStream(stream);
      return;
    }
    _capturedSourceId = wantedId;
    _capturedOptions = _wantedOptions;
    _endReason = null;
    final audioTracks = stream.getAudioTracks();
    final video = CapturedTrack(track: videoTracks.first, stream: stream);
    _audioTrack.set(
      audioTracks.isEmpty
          ? null
          : CapturedTrack(track: audioTracks.first, stream: stream),
    );
    setTrack(video);
    _watchForEnd(video, wantedId);
  }

  /// Captures a desktop source, working around flutter-webrtc #1085: the
  /// plugin looks the source up in the list from its last `getSources`
  /// call, and fails with "source not found!" if that list is stale or was
  /// never built. Rebuild it and retry once.
  Future<MediaStream> _captureDesktop(String sourceId) async {
    final constraints = desktopScreenConstraints(
      _wantedOptions,
      sourceId: sourceId,
    );
    try {
      return await _media.getDisplayMedia(constraints);
    } catch (error) {
      if (!isSourceNotFoundError(error)) rethrow;
    }
    final capturer = _media.desktopCapturer;
    try {
      await capturer?.getSources(types: _allTypes);
    } catch (error) {
      debugPrint(
        'cloudflare_realtime: re-listing screen sources failed: '
        '$error',
      );
    }
    try {
      return await _media.getDisplayMedia(constraints);
    } catch (error) {
      if (!isSourceNotFoundError(error)) rethrow;
      throw ScreenSourceNotFoundException(
        'The screen or window to share is no longer available.',
        sourceId: sourceId,
        cause: error,
      );
    }
  }

  void _watchForEnd(CapturedTrack video, String? sourceId) {
    video.track.onEnded = () => _endedExternally(
      video,
      usesBrowserPicker
          ? ScreenShareEndReason.userStopped
          : ScreenShareEndReason.sourceClosed,
    );
    final capturer = _media.desktopCapturer;
    if (sourceId == null || capturer == null) return;
    _removedSubscription = capturer.onRemoved
        .where((source) => source.id == sourceId)
        .listen(
          (_) => _endedExternally(video, ScreenShareEndReason.sourceClosed),
        );
    // The capturer only reports removals while someone re-scans.
    _watchTimer = Timer.periodic(sourceWatchInterval, (_) async {
      try {
        await capturer.updateSources(types: _allTypes);
      } catch (error) {
        debugPrint('cloudflare_realtime: updateSources failed: $error');
      }
    });
  }

  void _endedExternally(CapturedTrack video, ScreenShareEndReason reason) {
    if (!identical(currentTrack?.track, video.track) || isDisposed) return;
    _endReason = reason;
    turnOff();
    requestReconcile();
  }

  Future<void> _release(ScreenShareEndReason? reason) async {
    _watchTimer?.cancel();
    _watchTimer = null;
    final removed = _removedSubscription;
    _removedSubscription = null;
    await removed?.cancel();
    final current = currentTrack;
    _endReason = null;
    if (current == null) return;
    _capturedSourceId = null;
    _capturedOptions = null;
    _audioTrack.set(null);
    setTrack(null);
    await releaseStream(current.stream);
    if (reason != null && !_ended.isClosed) _ended.add(reason);
  }

  @override
  Future<void> onDispose() async {
    await _audioTrack.close();
    await _broadcastAudioTrack.close();
    await _ended.close();
  }
}
