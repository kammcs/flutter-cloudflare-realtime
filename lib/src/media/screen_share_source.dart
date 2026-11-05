/// @docImport 'screen_source_picker.dart';
library;

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../diagnostics/log.dart';
import '../signaling/participant_state.dart';
import '../util/state_stream.dart';
import 'constraints.dart';
import 'flutter_webrtc_media_backend.dart';
import 'local_media_source.dart';
import 'media_backend.dart';
import 'media_errors.dart';
import 'media_types.dart';
import 'release.dart';
import 'system_screen_pick.dart';

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
  /// the platform ended the track. On desktop the window may also have been
  /// hidden or minimized; [ScreenShareSource.endCause] says which, where the
  /// operating system can tell.
  sourceClosed,
}

/// A screen, window or browser-tab share, with the same mute model as the
/// camera and microphone.
///
/// - **Desktop** (Windows, macOS, Linux on X11): pick a [ScreenSource] with
///   a [ScreenSourcePicker], then [start] with it. The share is captured
///   with `getDisplayMedia` and `deviceId: {exact: source.id}`.
/// - **Linux in a Wayland session:** [start] without a source; the
///   system's ScreenCast dialog (the portal) is the picker, for screens and
///   windows alike, and the package never lists sources (its
///   `desktopCapturer` is `null`, so [ScreenSourcePicker.isSupported] is
///   `false`). Cancelling the dialog is like cancelling the browser's
///   picker. [systemPick] then remembers the pick: pass it to [start] as
///   `restore` to share the same screen or window again with no dialog
///   ("share it again"), or start without it to let the user choose
///   ("share something else"). Unmuting with [MutePolicy.releaseCapture]
///   restores the pick by itself. Another component's PipeWire stream (a
///   remote-control portal session) can be shared with no dialog:
///   [start] with a [PipeWireScreenStream].
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
/// [track] is the video track. With [ScreenShareOptions.captureAudio] on a
/// platform that supports it, [audioTrack] is the system or tab audio;
/// broadcasting applies to both. Android and iOS don't capture screen
/// audio: the option is ignored there and [audioTrack] stays `null`.
///
/// Defaults to [MutePolicy.releaseCapture]: [stopBroadcasting] ends the
/// share.
class ScreenShareSource extends LocalMediaSource {
  /// Creates a screen share source. It captures nothing until [start].
  ///
  /// On desktop, [sourceWatchInterval] is how often the source list is
  /// re-scanned while sharing, to notice the shared window closing (skipped
  /// while the operating system reports the source's [sourceGeometry]), and
  /// [geometryWatchInterval] how often [sourceGeometry] is read again, and
  /// [sourceRemovalGrace] how long a removal of the shared source waits to
  /// be confirmed before the share ends.
  ScreenShareSource({
    MediaBackend backend = const FlutterWebrtcMediaBackend(),
    ScreenShareOptions options = const ScreenShareOptions(),
    super.mutePolicy = MutePolicy.releaseCapture,
    this.sourceWatchInterval = const Duration(seconds: 3),
    this.geometryWatchInterval = const Duration(milliseconds: 500),
    this.sourceRemovalGrace = const Duration(milliseconds: 500),
  }) : _media = backend,
       _wantedOptions = options,
       super(kind: TrackKind.video, source: TrackSource.screen);

  /// All source types, re-scanned together so the plugin's source list
  /// always has every source `getDisplayMedia` might be asked for.
  static const _allTypes = {ScreenSourceType.screen, ScreenSourceType.window};

  final MediaBackend _media;

  /// How often the desktop source list is re-scanned while sharing.
  final Duration sourceWatchInterval;

  /// How often [sourceGeometry] is read again while sharing (desktop, where
  /// the platform reports geometry).
  final Duration geometryWatchInterval;

  /// How long a reported removal of the shared source waits before it is
  /// checked. A re-scan can report a source removed that still exists: a
  /// scan from scratch reports every source removed and then added again,
  /// and a scan can miss a window that is slow to answer. So a removal
  /// followed by an addition of the same source within this time is
  /// ignored. Otherwise the share ends with [ScreenShareEndReason.sourceClosed]
  /// unless the operating system still reports the source's geometry; then
  /// it is checked again every [sourceWatchInterval].
  final Duration sourceRemovalGrace;

  /// How long a release waits on iOS for the extension to report the end
  /// of the broadcast, so the next share doesn't find it still running.
  static const _broadcastEndTimeout = Duration(seconds: 3);

  ScreenShareOptions _wantedOptions;
  ScreenSource? _selected;
  // Linux: the system's dialog (Wayland) or another component's PipeWire
  // stream. Each start() is a new request: a running share is captured
  // again for it.
  SystemScreenPick? _wantedPick;
  PipeWireScreenStream? _wantedStream;
  int _systemRequest = 0;
  int? _capturedRequest;
  PipeWireScreenStream? _capturedStream;
  SystemScreenPick? _systemPick;
  String? _capturedSourceId;
  bool _systemBorderHidden = false;
  ScreenShareOptions? _capturedOptions;
  ScreenShareEndReason? _endReason;
  ScreenSourceEndCause? _pendingEndCause;
  ScreenSourceEndCause? _endCause;
  bool _serviceRunning = false;
  StreamSubscription<ScreenSource>? _removedSubscription;
  StreamSubscription<ScreenSource>? _addedSubscription;
  Timer? _removalTimer;
  int _removalGeneration = 0;
  StreamSubscription<String?>? _serviceStoppedSubscription;
  StreamSubscription<BroadcastExtensionEvent>? _broadcastSubscription;
  bool _broadcastFinished = false;
  Completer<void>? _wake;
  Timer? _watchTimer;
  Timer? _geometryTimer;
  int _geometryGeneration = 0;
  bool _readingGeometry = false;
  final StateStream<ScreenGeometry?> _sourceGeometry = StateStream(
    null,
    distinct: true,
  );
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

  /// Whether the browser (web), the system's consent dialog (Android), its
  /// broadcast picker (iOS) or its ScreenCast dialog (Linux in a Wayland
  /// session) picks what to share, rather than the app passing a
  /// [ScreenSource] (other desktops). When `true`, call [start] without a
  /// source.
  bool get usesSystemPicker =>
      _media.platform == MediaPlatform.web ||
      _service != null ||
      _broadcast != null ||
      _desktopSystemPicker;

  /// A desktop with no source list: Linux in a Wayland session, where the
  /// backend has no `desktopCapturer` and the ScreenCast portal picks.
  bool get _desktopSystemPicker =>
      _media.platform.isDesktop && _media.desktopCapturer == null;

  /// What the user picked in the system's ScreenCast dialog for the running
  /// share, or the last one (Linux in a Wayland session); `null` elsewhere,
  /// before the first such share, and when `flutter_webrtc` reported no
  /// restore ID. Pass it to [start] as `restore` to share it again with no
  /// dialog.
  SystemScreenPick? get systemPick => _systemPick;

  /// Replaces the geometry of the shared [PipeWireScreenStream] (say, once
  /// the remote-control session knows the monitor's scale): it becomes
  /// [sourceGeometry] while that stream is shared, and is kept for a
  /// capture again of the same stream. Does nothing for other shares.
  void updatePipeWireGeometry(ScreenGeometry? geometry) {
    final wanted = _wantedStream;
    if (wanted == null) return;
    _wantedStream = PipeWireScreenStream(
      fd: wanted.fd,
      nodeId: wanted.nodeId,
      geometry: geometry,
      type: wanted.type,
    );
    if (_capturedStream == wanted &&
        track != null &&
        !_sourceGeometry.isClosed) {
      _sourceGeometry.set(geometry);
    }
  }

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

  /// The system or tab audio track, or `null` if the share has none.
  CapturedTrack? get audioTrack => _audioTrack.value;

  /// [audioTrack], replaying the current value to each new listener, then
  /// each change.
  Stream<CapturedTrack?> get audioTrackChanges => _audioTrack.stream;

  /// [audioTrack] while broadcasting, else `null`.
  CapturedTrack? get broadcastAudioTrack => _broadcastAudioTrack.value;

  /// [broadcastAudioTrack], replaying the current value to each new
  /// listener, then each change.
  Stream<CapturedTrack?> get broadcastAudioTrackChanges =>
      _broadcastAudioTrack.stream;

  /// Emits once each time a running share ends, with the reason.
  Stream<ScreenShareEndReason> get ended => _ended.stream;

  /// Why the shared desktop source went away, for the last share that
  /// ended with [ScreenShareEndReason.sourceClosed]: its window was closed,
  /// hidden or minimized, or its display disconnected. `null` after any
  /// other end, before the first, and where the operating system can't
  /// tell. Set before [ended] reports the end.
  ScreenSourceEndCause? get endCause => _endCause;

  /// Where the shared display or window is on the desktop, and its scale,
  /// while a desktop share runs on macOS or Windows, or a
  /// [PipeWireScreenStream] with a geometry on Linux (in the compositor's
  /// logical coordinates, as its owner gave them); `null` otherwise
  /// (a share picked in Linux's ScreenCast dialog has none), and while the
  /// operating system can't say (on Windows, a minimized window).
  ///
  /// Read when the share starts, then every [geometryWatchInterval], so it
  /// follows a window that moves or is resized and a display whose
  /// resolution or arrangement changes. Use it to map a point in the shared
  /// picture to the sharer's desktop; [ScreenGeometry] describes the
  /// coordinates. [ScreenSource.geometry] is the same, as it was when the
  /// source was listed.
  ScreenGeometry? get sourceGeometry => _sourceGeometry.value;

  /// [sourceGeometry], replaying the current value to each new listener,
  /// then each change.
  Stream<ScreenGeometry?> get sourceGeometryChanges => _sourceGeometry.stream;

  /// Whether the operating system's own capture border is off for the
  /// running share: on Windows, when [ScreenShareOptions.hideSystemBorder]
  /// was asked for and Windows granted it (`MediaStreamTrack.getSettings()`
  /// `borderless`). `false` everywhere else, and while nothing is shared.
  /// Set before the share's track, so it is current when [trackChanges]
  /// reports the track. An app that draws its own frame around the shared
  /// window should draw it only when this is `true`.
  bool get systemBorderHidden => _systemBorderHidden;

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
    _wantedStream = null;
    if (options != null) _wantedOptions = options;
    return requestReconcile();
  }

  /// Sets what the next capture shares on Linux, without starting it:
  /// [restore], a pick from the system's ScreenCast dialog to share again
  /// with no dialog (in a Wayland session; ignored elsewhere), or
  /// [pipewireStream], a stream another component opened. With neither, in
  /// a Wayland session, the next capture opens the dialog. [start] calls
  /// it; call it yourself before [startBroadcasting] or `enable`.
  ///
  /// Throws an [ArgumentError] for both at once, and [UnsupportedError] for
  /// a [pipewireStream] off Linux.
  void prepareShare({
    SystemScreenPick? restore,
    PipeWireScreenStream? pipewireStream,
    ScreenShareOptions? options,
  }) {
    if (restore != null && pipewireStream != null) {
      throw ArgumentError('Pass restore or pipewireStream, not both.');
    }
    if (pipewireStream != null && _media.platform != MediaPlatform.linux) {
      throw UnsupportedError(
        'PipeWire streams are shared on Linux only, not on '
        '${_media.platform.name}.',
      );
    }
    if (options != null) _wantedOptions = options;
    if (pipewireStream != null) {
      _wantedStream = pipewireStream;
      _wantedPick = null;
      _systemRequest++;
    } else if (_desktopSystemPicker) {
      _wantedStream = null;
      _wantedPick = restore;
      _systemRequest++;
    }
  }

  /// Starts sharing [source] (desktop), or asks the browser to show its
  /// picker (web), the system its consent dialog (Android), its broadcast
  /// picker (iOS) or its ScreenCast dialog (Linux in a Wayland session);
  /// there [source] must be `null` ([usesSystemPicker]).
  ///
  /// On Linux in a Wayland session, [restore] shares a [systemPick] again
  /// with no dialog (an unknown or stale pick opens the dialog). On Linux,
  /// [pipewireStream] shares a stream another component opened through the
  /// portal, with no dialog ([PipeWireScreenStream] says who closes what).
  /// See [prepareShare].
  ///
  /// If a share is already running, switches it to [source] and [options]
  /// (in a Wayland session: to a new pick, [restore] or [pipewireStream]),
  /// in place: the track changes, and a publication of this source stays
  /// published.
  /// Returns whether the share is running afterwards (`false` too when the
  /// user cancels the picker or dialog, or on iOS doesn't start the
  /// broadcast within [ScreenShareOptions.broadcastStartTimeout]); failures
  /// go to [errors].
  /// Throws an [ArgumentError] on desktop if no source was given or
  /// selected before, and [UnsupportedError] where screen share isn't
  /// available ([isSupported]).
  Future<bool> start({
    ScreenSource? source,
    ScreenShareOptions? options,
    SystemScreenPick? restore,
    PipeWireScreenStream? pipewireStream,
  }) {
    _checkSupported();
    if (source != null && usesSystemPicker) {
      throw ArgumentError.value(
        source,
        'source',
        'The browser or the system picks what to share on '
            '${_media.platform.name}; pass none.',
      );
    }
    if (source != null && pipewireStream != null) {
      throw ArgumentError('Pass a source or a pipewireStream, not both.');
    }
    if (source != null) {
      _selected = source;
      _wantedStream = null;
    }
    prepareShare(
      restore: restore,
      pipewireStream: pipewireStream,
      options: options,
    );
    return enable();
  }

  /// Ends the share. Same as [disable].
  Future<void> stop() => disable();

  /// Starts the share with the selected source. See [start].
  @override
  Future<bool> enable() {
    _checkSupported();
    if (!usesSystemPicker &&
        _selected == null &&
        _wantedStream == null &&
        !isDisposed) {
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
    final pipewire = _wantedStream;
    final systemPicked = pipewire == null && _desktopSystemPicker;
    final wantedId = usesSystemPicker || pipewire != null
        ? null
        : _selected?.id;
    final request = pipewire != null || systemPicked ? _systemRequest : null;
    if (track != null &&
        _capturedSourceId == wantedId &&
        _capturedOptions == _wantedOptions &&
        _capturedRequest == request) {
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
        if (pipewire != null) {
          stream = await _media.getDisplayMedia(
            pipewireScreenConstraints(
              _wantedOptions,
              fd: pipewire.fd,
              nodeId: pipewire.nodeId,
            ),
          );
        } else if (systemPicked) {
          // The ScreenCast dialog, or the pick to restore.
          stream = await _media.getDisplayMedia(
            desktopScreenConstraints(_wantedOptions, sourceId: _wantedPick?.id),
          );
        } else {
          stream = wantedId == null
              ? await _media.getDisplayMedia(
                  webScreenConstraints(_wantedOptions),
                )
              : await _captureDesktop(wantedId);
        }
      }
    } on ScreenSourceNotFoundException catch (error) {
      fail(error);
      return;
    } catch (error) {
      _stopBroadcastEvents();
      await _stopService();
      if ((usesBrowserPicker || systemPicked) && isPermissionError(error)) {
        // The user closed the browser's picker or the system's dialog: not
        // an error.
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
    _capturedRequest = request;
    _capturedStream = pipewire;
    final settings = videoTracks.first.getSettings();
    _systemBorderHidden = settings['borderless'] == true;
    if (systemPicked) {
      // The restore ID: a capture again (unmuting, new options) shares the
      // same pick with no dialog.
      final id = settings['deviceId'];
      _systemPick = id is String && id.isNotEmpty ? SystemScreenPick(id) : null;
      _wantedPick = _systemPick;
    }
    if (pipewire != null && !_sourceGeometry.isClosed) {
      _sourceGeometry.set(pipewire.geometry);
    }
    _endReason = null;
    final audioTracks = stream.getAudioTracks();
    final video = CapturedTrack(track: videoTracks.first, stream: stream);
    _audioTrack.set(
      audioTracks.isEmpty
          ? null
          : CapturedTrack(track: audioTracks.first, stream: stream),
    );
    setTrack(video);
    _watchGeometry();
    await _watchForEnd(video, wantedId);
  }

  /// Follows the shared desktop source's geometry ([sourceGeometry]): reads
  /// it at once, then every [geometryWatchInterval], unless the platform
  /// has none for it.
  void _watchGeometry() {
    final capturer = _media.desktopCapturer;
    final source = _selected;
    if (usesSystemPicker ||
        _capturedStream != null ||
        capturer == null ||
        source == null) {
      return;
    }
    final generation = ++_geometryGeneration;

    Future<bool> read() async {
      if (_readingGeometry) return true;
      _readingGeometry = true;
      try {
        final geometry = await capturer.geometryOf(source);
        if (generation != _geometryGeneration || _sourceGeometry.isClosed) {
          return false;
        }
        _sourceGeometry.set(geometry);
        return geometry != null;
      } catch (error) {
        RealtimeLog.warning('reading the screen geometry failed', error: error);
        return false;
      } finally {
        _readingGeometry = false;
      }
    }

    unawaited(
      read().then((known) {
        if (generation != _geometryGeneration) return;
        // Nothing to follow where the platform has no geometry. A listed
        // source that has none now (a window minimized on Windows) may get
        // it back.
        if (!known && source.geometry == null) return;
        _geometryTimer?.cancel();
        _geometryTimer = Timer.periodic(geometryWatchInterval, (_) {
          unawaited(read());
        });
      }),
    );
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
      RealtimeLog.warning('abandoning the broadcast failed', error: error);
    }
    if (isEnabled && !isDisposed) {
      RealtimeLog.info(
        'the screen broadcast did not start (the '
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
      RealtimeLog.warning(
        'waiting for the broadcast to end failed',
        error: error,
      );
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
      RealtimeLog.warning('re-listing screen sources failed', error: error);
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
    // In a browser, and for Linux's portal shares, the end is the user's:
    // the browser's "Stop sharing", the system's sharing indicator, or the
    // remote-control session that owned the stream closing.
    video.track.onEnded = () => _endedExternally(
      video,
      usesBrowserPicker || _desktopSystemPicker || _capturedStream != null
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
        RealtimeLog.warning('watching the projection failed', error: error);
      }
      if (!watching) {
        RealtimeLog.info(
          'a share stopped from the system will only '
          'show as no frames (LocalTrackStalledEvent).',
        );
      }
      return;
    }
    final capturer = _media.desktopCapturer;
    if (sourceId == null || capturer == null) return;
    _removedSubscription = capturer.onRemoved
        .where((source) => source.id == sourceId)
        .listen((source) {
          _removalTimer?.cancel();
          final generation = ++_removalGeneration;
          _removalTimer = Timer(
            sourceRemovalGrace,
            () => _confirmRemoval(video, capturer, source, generation),
          );
        });
    // Listed again: the removal came from a scan from scratch.
    _addedSubscription = capturer.onAdded
        .where((source) => source.id == sourceId)
        .listen((_) {
          _removalGeneration++;
          _removalTimer?.cancel();
          _removalTimer = null;
        });
    // The capturer only reports removals while someone re-scans. A re-scan
    // is expensive: the plugin lists every window and screen and renders
    // their thumbnails on the platform thread (2–7 s each on a loaded Mac,
    // freezing the app). While the operating system still reports the
    // shared source's geometry, the source exists: skip the re-scan, and
    // re-scan only when it doesn't (gone, minimized on Windows, or no
    // geometry on this platform).
    _watchTimer = Timer.periodic(sourceWatchInterval, (_) async {
      if (_sourceGeometry.value != null) return;
      try {
        await capturer.updateSources(types: _allTypes);
      } catch (error) {
        RealtimeLog.warning('updateSources failed', error: error);
      }
    });
  }

  /// Ends the share for a removal that wasn't followed by an addition,
  /// unless the operating system still reports the source. A re-scan that
  /// missed a source has also dropped it from the plugin's list, so no
  /// second removal will come: while the source is still there, check it
  /// again every [sourceWatchInterval].
  Future<void> _confirmRemoval(
    CapturedTrack video,
    DesktopCapturerBackend capturer,
    ScreenSource source,
    int generation,
  ) async {
    bool current() =>
        generation == _removalGeneration &&
        identical(track?.track, video.track) &&
        !isDisposed;
    if (!current()) return;
    ScreenGeometry? geometry;
    try {
      geometry = await capturer.geometryOf(source);
    } catch (error) {
      RealtimeLog.warning('reading the screen geometry failed', error: error);
    }
    if (!current()) return;
    if (geometry == null) {
      ScreenSourceEndCause? cause;
      try {
        cause = await capturer.endCauseOf(source);
      } catch (error) {
        RealtimeLog.warning(
          'reading why the source ended failed',
          error: error,
        );
      }
      if (!current()) return;
      _endedExternally(video, ScreenShareEndReason.sourceClosed, cause: cause);
      return;
    }
    _removalTimer = Timer(
      sourceWatchInterval,
      () => _confirmRemoval(video, capturer, source, generation),
    );
  }

  void _endedExternally(
    CapturedTrack video,
    ScreenShareEndReason reason, {
    ScreenSourceEndCause? cause,
  }) {
    if (!identical(track?.track, video.track) || isDisposed) return;
    _endReason = reason;
    _pendingEndCause = cause;
    turnOff();
    requestReconcile();
  }

  Future<void> _release(ScreenShareEndReason? reason) async {
    _watchTimer?.cancel();
    _watchTimer = null;
    _geometryTimer?.cancel();
    _geometryTimer = null;
    _geometryGeneration++;
    if (!_sourceGeometry.isClosed) _sourceGeometry.set(null);
    // Not awaited: cancelling a broadcast subscription takes effect at once,
    // and its future (the root zone's null future) never completes under
    // fake_async, which would stall the release in tests.
    _removalTimer?.cancel();
    _removalTimer = null;
    unawaited(_removedSubscription?.cancel());
    _removedSubscription = null;
    unawaited(_addedSubscription?.cancel());
    _addedSubscription = null;
    unawaited(_serviceStoppedSubscription?.cancel());
    _serviceStoppedSubscription = null;
    _stopBroadcastEvents();
    final current = track;
    _endReason = null;
    final cause = _pendingEndCause;
    _pendingEndCause = null;
    if (current == null) {
      await _stopService();
      return;
    }
    _capturedSourceId = null;
    _capturedOptions = null;
    _capturedRequest = null;
    _capturedStream = null;
    _systemBorderHidden = false;
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
    if (reason != null && !_ended.isClosed) {
      _endCause = reason == ScreenShareEndReason.sourceClosed ? cause : null;
      _ended.add(reason);
    }
  }

  Future<void> _stopService() async {
    if (!_serviceRunning) return;
    _serviceRunning = false;
    try {
      await _service?.stopService();
    } catch (error) {
      RealtimeLog.warning(
        'stopping the screen share service failed',
        error: error,
      );
    }
  }

  @override
  Future<void> onDispose() async {
    await _audioTrack.close();
    await _broadcastAudioTrack.close();
    await _sourceGeometry.close();
    await _ended.close();
  }
}
