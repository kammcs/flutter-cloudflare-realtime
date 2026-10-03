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

  /// The user stopped it outside the app: the browser's "Stop sharing"
  /// button (web), the system's stop control or the share's notification
  /// (Android), or the broadcast's stop in the status bar or Control
  /// Center (iOS).
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
/// - **Android:** [start] without a source; the system's consent dialog is
///   the picker (on Android 14+ it offers a single app or the entire
///   screen). Cancelling it is like cancelling the browser's picker. The
///   share runs under this package's foreground service (its manifest
///   entries merge into the app's); see `docs/design.md` §10. Every start
///   asks for consent again, including unmuting with
///   [MutePolicy.releaseCapture].
/// - **iOS:** [start] without a source; the system's broadcast picker
///   ("Start Broadcast") is the picker, and the host app's Broadcast Upload
///   Extension captures the screen (set up as the README's "iOS screen
///   share setup" says; `docs/design.md` §10). If the setup is incomplete,
///   [start] returns `false` and reports a [ScreenShareSetupException] on
///   [errors]. [start] completes once the user has started the broadcast;
///   if that doesn't happen within [ScreenShareOptions.broadcastStartTimeout]
///   (the picker was dismissed, or the user waited), it returns `false` and
///   reports nothing.
///
/// [usesSystemPicker] tells the two kinds apart: `true` where the browser
/// or the system picks what to share, `false` where the app passes a
/// [ScreenSource].
///
/// **Ending.** [ended] reports every end of a share with its reason, and the
/// source turns off. On the web the browser ends the track when the user
/// clicks "Stop sharing". Native `flutter_webrtc` never fires a track's
/// `onEnded`, so on desktop the source watches the capturer's source list
/// instead, and ends the share when the shared window or display goes away.
/// On Android the package's native code reports the projection stopping
/// (the system's stop control) and the notification's "Stop sharing"; on
/// iOS, the broadcast finishing. Both end the share as
/// [ScreenShareEndReason.userStopped].
///
/// [trackChanges] carries the video track. With [ScreenShareOptions.captureAudio]
/// on a platform that supports it, [audioTrackChanges] carries system or tab
/// audio; broadcasting applies to both. Android and iOS don't capture
/// screen audio: the option is ignored there and [audioTrackChanges] stays
/// `null`.
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

  /// How long a release waits on iOS for the extension to report the end
  /// of the broadcast, so the next share doesn't find it still running.
  static const _broadcastEndTimeout = Duration(seconds: 3);

  ScreenShareOptions _wantedOptions;
  ScreenSource? _selected;
  String? _capturedSourceId;
  ScreenShareOptions? _capturedOptions;
  ScreenShareEndReason? _endReason;
  bool _serviceRunning = false;
  StreamSubscription<ScreenSource>? _removedSubscription;
  StreamSubscription<String?>? _serviceStoppedSubscription;
  StreamSubscription<BroadcastExtensionEvent>? _broadcastSubscription;
  bool _broadcastFinished = false;
  Completer<void>? _wake;
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

  /// Whether screen share is implemented on this platform (desktop, web,
  /// Android and iOS). On iOS it also needs the host app's setup, which
  /// [start] checks.
  bool get isSupported =>
      _media.platform.isDesktop ||
      _media.platform == MediaPlatform.web ||
      _service != null ||
      _broadcast != null;

  /// Whether the browser (web), the system's consent dialog (Android) or
  /// its broadcast picker (iOS) picks what to share, rather than the app
  /// passing a [ScreenSource] (desktop). When `true`, call [start] without
  /// a source.
  bool get usesSystemPicker =>
      _media.platform == MediaPlatform.web ||
      _service != null ||
      _broadcast != null;

  /// Whether the browser picks the source (web). See [usesSystemPicker],
  /// which also covers Android's consent dialog.
  bool get usesBrowserPicker => _media.platform == MediaPlatform.web;

  /// The Android consent and foreground service, or `null` elsewhere.
  ScreenCaptureServiceBackend? get _service =>
      _media.platform == MediaPlatform.android
      ? _media.screenCaptureService
      : null;

  /// The iOS broadcast extension, or `null` elsewhere.
  BroadcastExtensionBackend? get _broadcast =>
      _media.platform == MediaPlatform.ios ? _media.broadcastExtension : null;

  /// The desktop source chosen with [start] or [select]. Always `null` on
  /// the web and phones.
  ScreenSource? get selectedSource => _selected;

  /// The capture options.
  ScreenShareOptions get options => _wantedOptions;

  /// The system or tab audio track, if the share has one. Replays the
  /// current value.
  Stream<CapturedTrack?> get audioTrackChanges => _audioTrack.stream;

  /// The system or tab audio track, or `null`.
  CapturedTrack? get audioTrack => _audioTrack.value;

  /// [audioTrack] while broadcasting, else `null`. Replays the
  /// current value.
  Stream<CapturedTrack?> get broadcastAudioTrackChanges => _broadcastAudioTrack.stream;

  /// [audioTrack] while broadcasting, else `null`.
  CapturedTrack? get broadcastAudioTrack => _broadcastAudioTrack.value;

  /// Emits once each time a running share ends, with the reason.
  Stream<ScreenShareEndReason> get ended => _ended.stream;

  /// Sets the source (desktop) and options for the next capture. If a share
  /// is running, it switches to the new source and waits for that.
  ///
  /// Does not start a share.
  Future<void> select(ScreenSource source, {ScreenShareOptions? options}) {
    _checkSupported();
    if (usesSystemPicker) {
      throw UnsupportedError(
        'The browser or the system picks what to share on '
        '${_media.platform.name}; call start() without a source.',
      );
    }
    _selected = source;
    if (options != null) _wantedOptions = options;
    return requestReconcile();
  }

  /// Starts sharing [source] (desktop), or asks the browser to show its
  /// picker (web), the system its consent dialog (Android) or its
  /// broadcast picker (iOS); there [source] must be `null`
  /// ([usesSystemPicker]).
  ///
  /// If a share is already running, switches it to [source] and [options].
  /// Returns whether the share is running afterwards (`false` too when the
  /// user cancels the picker or dialog, or on iOS doesn't start the
  /// broadcast within [ScreenShareOptions.broadcastStartTimeout]); failures
  /// go to [errors].
  /// Throws an [ArgumentError] on desktop if no source was given or
  /// selected before, and [UnsupportedError] where screen share isn't
  /// available ([isSupported]).
  Future<bool> start({ScreenSource? source, ScreenShareOptions? options}) {
    _checkSupported();
    if (source != null && usesSystemPicker) {
      throw ArgumentError.value(
        source,
        'source',
        'The browser or the system picks what to share on '
            '${_media.platform.name}; pass none.',
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
    if (!usesSystemPicker && _selected == null && !isDisposed) {
      throw ArgumentError(
        'Choose a ScreenSource first: start(source: ...) or select(...).',
      );
    }
    return super.enable();
  }

  void _checkSupported() {
    if (isSupported) return;
    throw UnsupportedError(
      'Screen share is not available on ${_media.platform.name} with this '
      'MediaBackend.',
    );
  }

  @override
  void didChangeState() {
    // Stops waiting for the iOS broadcast when the share is turned off.
    final wake = _wake;
    if (!isEnabled && wake != null && !wake.isCompleted) wake.complete();
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
    final wantedId = usesSystemPicker ? null : _selected?.id;
    if (track != null &&
        _capturedSourceId == wantedId &&
        _capturedOptions == _wantedOptions) {
      return;
    }
    // Switching: release first. On Windows, stopping any desktop capturer
    // also stops the (single) loopback audio capturer, so the new share must
    // start after the old one has stopped.
    await _release(null);
    if (!isEnabled) return;

    final service = _service;
    final broadcast = _broadcast;
    final MediaStream stream;
    try {
      if (broadcast != null) {
        final captured = await _captureBroadcast(broadcast);
        if (captured == null) return;
        stream = captured;
      } else {
        if (service != null) {
          if (!await service.requestConsent()) {
            // The user cancelled the consent dialog: not an error.
            turnOff();
            return;
          }
          if (!isEnabled || isDisposed) return;
          _serviceRunning = true;
          await service.startService();
          if (!isEnabled || isDisposed) {
            await _stopService();
            return;
          }
        }
        stream = wantedId == null
            ? await _media.getDisplayMedia(webScreenConstraints(_wantedOptions))
            : await _captureDesktop(wantedId);
      }
    } on ScreenSourceNotFoundException catch (error) {
      fail(error);
      return;
    } catch (error) {
      _stopBroadcastEvents();
      await _stopService();
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
      _stopBroadcastEvents();
      await releaseStream(stream);
      await _stopService();
      fail(const MediaCaptureException('getDisplayMedia returned no video.'));
      return;
    }
    if (!isEnabled || isDisposed) {
      _stopBroadcastEvents();
      await releaseStream(stream);
      await _stopService();
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
    await _watchForEnd(video, wantedId);
  }

  /// Captures through the iOS Broadcast Upload Extension: checks the
  /// app's setup, hands the extension its settings, shows the system's
  /// broadcast picker (`getDisplayMedia`, which returns at once), then
  /// waits for the user to start the broadcast. A broadcast that is already
  /// running is used at once, without the picker.
  ///
  /// Returns `null` if the share didn't start: the setup is incomplete
  /// (reported), the wait timed out or the share was turned off meanwhile
  /// (not reported). Throws for a failing call, like `getDisplayMedia`.
  /// Leaves [_broadcastSubscription] listening for the broadcast's end.
  Future<MediaStream?> _captureBroadcast(
    BroadcastExtensionBackend broadcast,
  ) async {
    final status = await broadcast.status();
    if (!status.isReady) {
      fail(
        ScreenShareSetupException(
          'The app is not set up for screen share on iOS: '
          '${status.problems.map((p) => p.name).join(', ')}.',
          problems: status.problems,
        ),
      );
      return null;
    }
    if (!isEnabled || isDisposed) return null;
    await broadcast.prepare(
      frameRate: _wantedOptions.frameRate,
      scale: _wantedOptions.broadcastScale,
    );
    if (!isEnabled || isDisposed) return null;

    final started = Completer<bool>();
    if (status.broadcasting) started.complete(true);
    _broadcastFinished = false;
    _stopBroadcastEvents();
    _broadcastSubscription = broadcast.events.listen((event) {
      switch (event) {
        case BroadcastExtensionEvent.started:
          if (!started.isCompleted) started.complete(true);
        case BroadcastExtensionEvent.finished:
          if (!started.isCompleted) {
            started.complete(false);
            return;
          }
          _broadcastFinished = true;
          final video = track;
          if (video != null) {
            _endedExternally(video, ScreenShareEndReason.userStopped);
          }
      }
    });
    final stream = await _media.getDisplayMedia(
      iosBroadcastConstraints(pickerShown: !status.broadcasting),
    );

    final wake = _wake = Completer<void>();
    if (!isEnabled || isDisposed) wake.complete();
    final timeoutAfter = _wantedOptions.broadcastStartTimeout;
    final timeout = Timer(timeoutAfter, () {
      if (!started.isCompleted) started.complete(false);
    });
    final running = await Future.any([
      started.future,
      wake.future.then((_) => false),
    ]);
    timeout.cancel();
    _wake = null;
    if (running && isEnabled && !isDisposed) return stream;

    // Cancelled, timed out or turned off: nothing to report.
    _stopBroadcastEvents();
    await releaseStream(stream);
    try {
      // flutter_webrtc keeps listening on its socket when nothing ever
      // connected; a late broadcast mustn't find it.
      await broadcast.abandon();
    } catch (error) {
      debugPrint('cloudflare_realtime: abandoning the broadcast: $error');
    }
    if (isEnabled && !isDisposed) {
      debugPrint(
        'cloudflare_realtime: the screen broadcast did not start (the '
        'picker was dismissed or not answered within '
        '$timeoutAfter, or the broadcast ended at once).',
      );
      turnOff();
    }
    return null;
  }

  void _stopBroadcastEvents() {
    // Not awaited, like the other subscriptions (see _release).
    unawaited(_broadcastSubscription?.cancel());
    _broadcastSubscription = null;
  }

  /// Completes once the iOS broadcast has finished, or right away if none
  /// is running. Listens before its first `await`, so call it before
  /// releasing the capture whose end it waits for.
  Future<void> _broadcastEnded(BroadcastExtensionBackend broadcast) async {
    final finished = Completer<void>();
    final subscription = broadcast.events.listen((event) {
      if (event == BroadcastExtensionEvent.finished && !finished.isCompleted) {
        finished.complete();
      }
    });
    try {
      if ((await broadcast.status()).broadcasting) {
        await finished.future.timeout(_broadcastEndTimeout, onTimeout: () {});
      }
    } catch (error) {
      debugPrint('cloudflare_realtime: waiting for the broadcast: $error');
    } finally {
      unawaited(subscription.cancel());
    }
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
      if (!isSourceNotFoundError(error, platform: _media.platform)) rethrow;
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
      if (!isSourceNotFoundError(error, platform: _media.platform)) rethrow;
      throw ScreenSourceNotFoundException(
        'The screen or window to share is no longer available.',
        sourceId: sourceId,
        cause: error,
      );
    }
  }

  Future<void> _watchForEnd(CapturedTrack video, String? sourceId) async {
    video.track.onEnded = () => _endedExternally(
      video,
      usesBrowserPicker
          ? ScreenShareEndReason.userStopped
          : ScreenShareEndReason.sourceClosed,
    );
    if (_broadcast != null) {
      // _broadcastSubscription reports the end; it may already have come.
      if (_broadcastFinished) {
        _endedExternally(video, ScreenShareEndReason.userStopped);
      }
      return;
    }
    final service = _service;
    if (service != null) {
      final trackId = video.track.id;
      _serviceStoppedSubscription = service.stopped
          .where((id) => id == null || id == trackId)
          .listen(
            (_) => _endedExternally(video, ScreenShareEndReason.userStopped),
          );
      var watching = false;
      try {
        if (trackId != null) watching = await service.watch(trackId);
      } catch (error) {
        debugPrint('cloudflare_realtime: watching the projection: $error');
      }
      if (!watching) {
        debugPrint(
          'cloudflare_realtime: a share stopped from the system will only '
          'show as no frames (LocalTrackStalledEvent).',
        );
      }
      return;
    }
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
    if (!identical(track?.track, video.track) || isDisposed) return;
    _endReason = reason;
    turnOff();
    requestReconcile();
  }

  Future<void> _release(ScreenShareEndReason? reason) async {
    _watchTimer?.cancel();
    _watchTimer = null;
    // Not awaited: cancelling a broadcast subscription takes effect at once,
    // and its future (the root zone's null future) never completes under
    // fake_async, which would stall the release in tests.
    unawaited(_removedSubscription?.cancel());
    _removedSubscription = null;
    unawaited(_serviceStoppedSubscription?.cancel());
    _serviceStoppedSubscription = null;
    _stopBroadcastEvents();
    final current = track;
    _endReason = null;
    if (current == null) {
      await _stopService();
      return;
    }
    _capturedSourceId = null;
    _capturedOptions = null;
    _audioTrack.set(null);
    setTrack(null);
    // The capture first, then its foreground service (Android) or the
    // broadcast's end (iOS).
    final broadcast = _broadcast;
    final broadcastEnded = broadcast == null
        ? null
        : _broadcastEnded(broadcast);
    await releaseStream(current.stream);
    await broadcastEnded;
    await _stopService();
    if (reason != null && !_ended.isClosed) _ended.add(reason);
  }

  Future<void> _stopService() async {
    if (!_serviceRunning) return;
    _serviceRunning = false;
    try {
      await _service?.stopService();
    } catch (error) {
      debugPrint(
        'cloudflare_realtime: stopping the screen share service: '
        '$error',
      );
    }
  }

  @override
  Future<void> onDispose() async {
    await _audioTrack.close();
    await _broadcastAudioTrack.close();
    await _ended.close();
  }
}
