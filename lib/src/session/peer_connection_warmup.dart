import 'dart:async';

import 'package:flutter/foundation.dart';

import '../diagnostics/log.dart';
import 'flutter_webrtc_peer_connection.dart';
import 'peer_connection.dart';

/// Creates one idle peer connection ahead of a join and keeps it until the
/// join has created its own, so that the slow part of creating the first
/// one runs before the join instead of inside it
/// (`CloudflareRealtime.prewarm`).
///
/// On macOS the first peer connection in a process initializes the
/// `flutter_webrtc` factory and WebRTC-SDK's audio device module, which
/// blocks the platform thread (the UI thread there) for 4–6 s, and closing
/// the last peer connection undoes part of it: a peer connection created
/// after that still blocked for 2.4–3.1 s (`docs/design.md` §4.2, macOS: a
/// slow first join). Hence the warm-up's peer connection stays open until
/// the session has its own; with it open, the join's took milliseconds.
/// It has no ICE servers, transceivers or descriptions: nothing is
/// gathered, recorded or sent, and Apple's voice processing still starts
/// with the first microphone publish.
///
/// [SfuSession.connect] waits for a warm-up that is running before it
/// requests the session, so the SFU's clock for an unconnected session
/// doesn't start while the warm-up holds the platform, and then [release]s
/// the warm-up's peer connection once its own exists.
///
/// Internal: not exported from the package barrel.
abstract final class PeerConnectionWarmup {
  static Future<void>? _warming;
  static PeerConnection? _held;
  static int _generation = 0;

  /// Warms up with [create] (by default `flutter_webrtc`) on macOS;
  /// elsewhere does nothing. [platform] replaces the platform this runs
  /// on, for tests.
  ///
  /// While a warm-up is running or its peer connection is held, returns
  /// that warm-up; after [release], warms up again. Completes when the
  /// peer connection has been created. A failure is logged, never thrown:
  /// the join creates its own peer connection and reports its own errors.
  static Future<void> warm({
    PeerConnectionFactory create = createFlutterWebrtcPeerConnection,
    TargetPlatform? platform,
  }) {
    final target = platform ?? defaultTargetPlatform;
    if (kIsWeb || target != TargetPlatform.macOS) return Future.value();
    return _warming ??= _warm(create, _generation);
  }

  static Future<void> _warm(
    PeerConnectionFactory create,
    int generation,
  ) async {
    final PeerConnection peerConnection;
    try {
      peerConnection = await create(const {
        'iceServers': <Map<String, dynamic>>[],
        'sdpSemantics': 'unified-plan',
      });
    } catch (error) {
      RealtimeLog.warning('prewarm failed', error: error);
      if (generation == _generation) _warming = null;
      return;
    }
    if (generation != _generation) {
      // Released while it was being created: nobody will release it later.
      await _closeQuietly(peerConnection);
      return;
    }
    _held = peerConnection;
  }

  /// Completes when a warm-up that has started has created its peer
  /// connection, or after [timeout] (null: no bound); at once when none
  /// has started.
  static Future<void> whenDone(Duration? timeout) {
    final warming = _warming;
    if (warming == null) return Future.value();
    return timeout == null
        ? warming
        : warming.timeout(timeout, onTimeout: () {});
  }

  /// Closes the warm-up's peer connection (one still being created is
  /// closed when it arrives), and lets the next [warm] warm up again.
  /// Called once a session has created its own.
  static Future<void> release() async {
    if (_warming == null) return;
    _generation++;
    _warming = null;
    final held = _held;
    _held = null;
    if (held != null) await _closeQuietly(held);
  }

  static Future<void> _closeQuietly(PeerConnection peerConnection) async {
    try {
      await peerConnection.close();
    } catch (_) {
      // Never used: nothing else to release.
    }
  }

  /// Forgets the warm-up without closing anything, for tests.
  @visibleForTesting
  static void reset() {
    _generation++;
    _warming = null;
    _held = null;
  }
}
