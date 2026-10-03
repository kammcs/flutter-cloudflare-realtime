/// @docImport 'device_media_source.dart';
/// @docImport 'screen_share_source.dart';
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../signaling/participant_state.dart';
import '../util/coalescing_runner.dart';
import '../util/state_stream.dart';
import 'media_errors.dart';
import 'media_types.dart';

/// What [LocalMediaSource.stopBroadcasting] does to the capture.
///
/// This is partytracks' `retainIdleTrack` option, made explicit.
enum MutePolicy {
  /// Muting stops sending but keeps capturing, so unmuting is instant and
  /// the app can still read the local track (for example to warn "you are
  /// talking while muted"). The OS capture indicator stays on.
  ///
  /// The default for microphones.
  keepCapture,

  /// Muting also releases the capture ([LocalMediaSource.disable]), so the
  /// camera light goes off. Unmuting captures again, which takes a moment.
  ///
  /// The default for cameras and screen shares: users are sensitive to the
  /// camera light staying on while they believe they are hidden.
  releaseCapture,
}

/// A local camera, microphone or screen capture, with partytracks' mute
/// model.
///
/// Two independent switches, ported from partytracks' `makeBroadcastTrack`:
///
/// - **Enabled** ([isEnabled]): whether the source captures at all. When
///   enabled, [trackChanges] carries the live captured track; when disabled it is
///   `null` and the device is released.
/// - **Broadcasting** ([isBroadcasting]): whether the capture should be sent
///   to other participants. [broadcastTrackChanges] carries the track while the
///   source is enabled *and* broadcasting, and `null` otherwise. Publishing
///   (roadmap M2) sends [broadcastTrackChanges], so "muted" means it is `null`.
///
/// The switches are linked the same way as in partytracks:
/// [startBroadcasting] enables the source, and [disable] stops broadcasting.
/// What [stopBroadcasting] does to the capture is the [mutePolicy].
///
/// Repairs happen inside the source: when a device is unplugged or a
/// setting changes, the source captures again and [trackChanges] emits the new
/// track. Listeners never need to re-subscribe.
///
/// Failures are reported on [errors] and turn the source off; the methods
/// don't throw for them. They do throw [StateError] after [dispose], and
/// screen shares throw [UnsupportedError] where capture isn't implemented.
abstract class LocalMediaSource {
  /// Initializes the shared state. For subclasses.
  LocalMediaSource({
    required this.kind,
    required this.source,
    required this.mutePolicy,
  });

  /// Audio or video.
  final TrackKind kind;

  /// What this source captures.
  final TrackSource source;

  /// What [stopBroadcasting] does to the capture.
  final MutePolicy mutePolicy;

  final StateStream<bool> _enabled = StateStream(false, distinct: true);
  final StateStream<bool> _broadcasting = StateStream(false, distinct: true);
  final StateStream<CapturedTrack?> _track = StateStream(null, distinct: true);
  final StateStream<CapturedTrack?> _broadcastTrack = StateStream(
    null,
    distinct: true,
  );
  final StreamController<MediaException> _errors = StreamController.broadcast();
  late final CoalescingRunner _runner = CoalescingRunner(_reconcileSafely);
  bool _disposed = false;

  /// Whether the source should be capturing. Replays the current value.
  Stream<bool> get enabledChanges => _enabled.stream;

  /// Whether the source should be capturing.
  ///
  /// Changes as soon as [enable] or [disable] is called; [track]
  /// follows once capture has started or stopped. Turns `false` by itself
  /// when capture fails or a screen share ends.
  bool get isEnabled => _enabled.value;

  /// Whether the capture should be sent to others. Replays the current
  /// value.
  Stream<bool> get broadcastingChanges => _broadcasting.stream;

  /// Whether the capture should be sent to others.
  bool get isBroadcasting => _broadcasting.value;

  /// The live captured track, or `null` while disabled or not yet captured.
  /// Replays the current value.
  ///
  /// Emits a new track when the source repairs or changes its capture, for
  /// example after a device is unplugged.
  Stream<CapturedTrack?> get trackChanges => _track.stream;

  /// The live captured track, or `null`.
  CapturedTrack? get track => _track.value;

  /// The track to send: [track] while broadcasting, else `null`.
  /// Replays the current value.
  Stream<CapturedTrack?> get broadcastTrackChanges => _broadcastTrack.stream;

  /// The track to send: [track] while broadcasting, else `null`.
  CapturedTrack? get broadcastTrack => _broadcastTrack.value;

  /// Capture failures: permission denied, every device failing, a screen
  /// source that can't be found. The source is disabled when one arrives.
  Stream<MediaException> get errors => _errors.stream;

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;

  /// Turns the source on and waits until capture has started or failed.
  ///
  /// Returns whether the source is capturing afterwards. On failure the
  /// error goes to [errors] and the source stays disabled.
  Future<bool> enable() async {
    _checkNotDisposed();
    _enabled.set(true);
    _syncBroadcastTrack();
    await _runner.run();
    return isEnabled && track != null;
  }

  /// Turns the source off, stops broadcasting, and waits until the capture
  /// is released.
  Future<void> disable() async {
    _checkNotDisposed();
    _broadcasting.set(false);
    _enabled.set(false);
    _syncBroadcastTrack();
    await _runner.run();
  }

  /// Calls [enable] or [disable]. Returns whether the source is capturing
  /// afterwards.
  Future<bool> setEnabled(bool enabled) async {
    if (enabled) return enable();
    await disable();
    return false;
  }

  /// Starts sending the capture, enabling the source first if needed.
  ///
  /// Returns whether the source is capturing afterwards.
  Future<bool> startBroadcasting() async {
    _checkNotDisposed();
    _broadcasting.set(true);
    return enable();
  }

  /// Stops sending the capture. With [MutePolicy.releaseCapture] this also
  /// disables the source.
  Future<void> stopBroadcasting() async {
    _checkNotDisposed();
    if (mutePolicy == MutePolicy.releaseCapture) return disable();
    _broadcasting.set(false);
    _syncBroadcastTrack();
  }

  /// Calls [startBroadcasting] or [stopBroadcasting]. Returns whether the
  /// source is broadcasting afterwards.
  Future<bool> setBroadcasting(bool broadcasting) async {
    if (broadcasting) return await startBroadcasting() && isBroadcasting;
    await stopBroadcasting();
    return false;
  }

  /// Releases the capture and completes every stream. Safe to call twice.
  ///
  /// The source stops and disposes its tracks, so don't keep using them.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _broadcasting.set(false);
    _enabled.set(false);
    _syncBroadcastTrack();
    await _runner.run();
    await onDispose();
    await Future.wait([
      _enabled.close(),
      _broadcasting.close(),
      _track.close(),
      _broadcastTrack.close(),
      _errors.close(),
    ]);
  }

  void _checkNotDisposed() {
    if (_disposed) throw StateError('This $runtimeType has been disposed.');
  }

  Future<void> _reconcileSafely() async {
    try {
      await reconcile();
    } catch (error, stackTrace) {
      // A bug, not a capture failure: capture failures are reported by the
      // subclass. Turn off rather than leave a half-state behind.
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stackTrace,
          library: 'cloudflare_realtime',
          context: ErrorDescription('while updating a $runtimeType'),
        ),
      );
    }
  }

  void _syncBroadcastTrack() {
    if (_broadcastTrack.isClosed) return;
    _broadcastTrack.set(isEnabled && isBroadcasting ? track : null);
    didChangeState();
  }

  /// Makes the capture match the desired state: capture while [isEnabled],
  /// release otherwise.
  ///
  /// Never runs concurrently with itself. Requests made while it runs cause
  /// one more run afterwards, so an implementation can re-read the desired
  /// state at each `await` and leave the rest to the next run.
  @protected
  Future<void> reconcile();

  /// Asks for a [reconcile] run, for example after a device list change.
  ///
  /// Does nothing after [dispose] has started.
  @protected
  Future<void> requestReconcile() => _disposed ? Future.value() : _runner.run();

  /// Publishes [track] as [track], and updates [broadcastTrackChanges].
  @protected
  void setTrack(CapturedTrack? track) {
    if (_track.isClosed) return;
    _track.set(track);
    _syncBroadcastTrack();
  }

  /// Turns the source off (and stops broadcasting) without an error, for
  /// example when a screen share ends or the user cancels the browser's
  /// picker.
  @protected
  void turnOff() {
    if (_enabled.isClosed) return;
    _broadcasting.set(false);
    _enabled.set(false);
    _syncBroadcastTrack();
  }

  /// Turns the source off and reports [error] on [errors].
  @protected
  void fail(MediaException error) {
    turnOff();
    if (!_errors.isClosed) _errors.add(error);
  }

  /// Called after every change to [isEnabled], [isBroadcasting] or
  /// [track]. Subclasses with extra tracks sync them here.
  @protected
  void didChangeState() {}

  /// Releases subclass resources. Called by [dispose] after the capture has
  /// been released.
  @protected
  Future<void> onDispose() async {}
}
