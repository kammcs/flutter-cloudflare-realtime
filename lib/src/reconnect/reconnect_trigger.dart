import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' show RTCPeerConnectionState;

/// Why a [ReconnectTrigger] decided to replace the session.
enum ReconnectReason {
  /// The peer connection reached `failed`.
  peerConnectionFailed,

  /// The peer connection stayed `disconnected` for longer than
  /// [ReconnectTriggerConfig.disconnectedTimeout].
  disconnectedTooLong,

  /// The peer connection didn't reach `connected` within
  /// [ReconnectTriggerConfig.connectTimeout].
  connectTimeout,

  /// The network changed and the connection is (or soon went) down.
  networkChanged,

  /// The app came back to the foreground after longer than
  /// [ReconnectTriggerConfig.backgroundThreshold] in the background.
  resumedFromBackground,

  /// The broker or SFU reported that the session is gone (HTTP 410,
  /// `session_error`).
  sessionGone,

  /// The app asked for it (`Room.reconnect`).
  manual,
}

/// Tuning for when the package replaces a broken SFU session
/// (design.md §8).
@immutable
class ReconnectTriggerConfig {
  /// Creates a trigger configuration.
  const ReconnectTriggerConfig({
    this.disconnectedTimeout = const Duration(seconds: 5),
    this.connectTimeout = const Duration(seconds: 15),
    this.networkChangeWindow = const Duration(seconds: 10),
    this.backgroundThreshold = const Duration(seconds: 30),
  });

  /// How long the peer connection may stay `disconnected` before the
  /// session is replaced. `disconnected` often recovers on its own (a short
  /// Wi-Fi blip), so it gets a grace period; `failed` never does. Default
  /// 5 s.
  final Duration disconnectedTimeout;

  /// How long a new peer connection may take to reach `connected`, or
  /// `null` for no limit. Default 15 s.
  final Duration? connectTimeout;

  /// After a network-change event, a `disconnected` state within this long
  /// replaces the session at once, without waiting for
  /// [disconnectedTimeout]: the old network path is most likely gone, and
  /// the SFU has no documented ICE restart. Default 10 s.
  final Duration networkChangeWindow;

  /// Coming back to the foreground after at least this long in the
  /// background replaces the session, because mobile OSes may have killed
  /// its sockets while the peer connection still reports `connected`.
  /// `null` disables this. Default 30 s.
  final Duration? backgroundThreshold;

  @override
  bool operator ==(Object other) =>
      other is ReconnectTriggerConfig &&
      other.disconnectedTimeout == disconnectedTimeout &&
      other.connectTimeout == connectTimeout &&
      other.networkChangeWindow == networkChangeWindow &&
      other.backgroundThreshold == backgroundThreshold;

  @override
  int get hashCode => Object.hash(
    disconnectedTimeout,
    connectTimeout,
    networkChangeWindow,
    backgroundThreshold,
  );
}

/// Decides when to replace the SFU session, from peer-connection states,
/// network changes, app lifecycle and session errors.
///
/// This is only the decision: it has no timers and does no I/O. The caller
/// (the Room's reconnection) feeds it events with a monotonic timestamp
/// (`now`), schedules a timer for [nextCheckAt] and calls [check] when it
/// fires. Every input returns the [ReconnectReason] when it decides to
/// reconnect, or `null`.
///
/// Once it has triggered, it stays triggered ([triggeredReason]) and
/// ignores further input until [reset], so one outage produces one
/// re-session. Call [reset] when a new session (a new peer connection)
/// replaces the old one.
///
/// Rules (see [ReconnectTriggerConfig] for the durations):
///
/// - `failed` triggers at once.
/// - `disconnected` triggers after `disconnectedTimeout`, or at once if a
///   network change happened within `networkChangeWindow` before it.
/// - A network change while `disconnected` triggers at once. While
///   `connected`, it only arms the window above: platforms report network
///   changes that don't break the connection (a second interface coming up).
/// - `new`/`connecting` for longer than `connectTimeout` triggers.
/// - Resuming after `backgroundThreshold` or more in the background
///   triggers.
/// - A session-gone error triggers at once.
/// - `closed` clears the timers: the package closed the connection itself.
///
/// Internal: not exported from the package barrel. Apps tune it through
/// [ReconnectTriggerConfig].
class ReconnectTrigger {
  /// Creates a trigger.
  ReconnectTrigger([this.config = const ReconnectTriggerConfig()]);

  /// The configuration.
  final ReconnectTriggerConfig config;

  RTCPeerConnectionState? _state;
  Duration? _disconnectedSince;
  Duration? _connectingSince;
  Duration? _lastNetworkChange;
  Duration? _pausedAt;
  ReconnectReason? _triggered;

  /// The last peer-connection state reported.
  RTCPeerConnectionState? get state => _state;

  /// Why it triggered, or `null` if it hasn't since the last [reset].
  ReconnectReason? get triggeredReason => _triggered;

  /// Whether it has triggered since the last [reset].
  bool get isTriggered => _triggered != null;

  /// Whether the app is in the background, as far as it has been told.
  bool get isPaused => _pausedAt != null;

  /// When the caller should next call [check], or `null` if no timer is
  /// pending (or it has already triggered).
  Duration? get nextCheckAt {
    if (_triggered != null) return null;
    Duration? earliest;
    void consider(Duration? at) {
      if (at != null && (earliest == null || at < earliest!)) earliest = at;
    }

    final disconnectedSince = _disconnectedSince;
    if (disconnectedSince != null) {
      consider(disconnectedSince + config.disconnectedTimeout);
    }
    final connectingSince = _connectingSince;
    final connectTimeout = config.connectTimeout;
    if (connectingSince != null && connectTimeout != null) {
      consider(connectingSince + connectTimeout);
    }
    return earliest;
  }

  /// Reports a peer-connection state change at [now].
  ReconnectReason? peerConnectionStateChanged(
    RTCPeerConnectionState state,
    Duration now,
  ) {
    if (_triggered != null) return null;
    _state = state;
    switch (state) {
      case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
        return _trigger(ReconnectReason.peerConnectionFailed);
      case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
        _connectingSince = null;
        _disconnectedSince ??= now;
        if (_withinNetworkChangeWindow(now)) {
          return _trigger(ReconnectReason.networkChanged);
        }
      case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
        _disconnectedSince = null;
        _connectingSince = null;
      case RTCPeerConnectionState.RTCPeerConnectionStateNew:
      case RTCPeerConnectionState.RTCPeerConnectionStateConnecting:
        _disconnectedSince = null;
        _connectingSince ??= now;
      case RTCPeerConnectionState.RTCPeerConnectionStateClosed:
        _disconnectedSince = null;
        _connectingSince = null;
    }
    return check(now);
  }

  /// Reports a network-change event (interface up/down, Wi-Fi to cellular)
  /// at [now].
  ReconnectReason? networkChanged(Duration now) {
    if (_triggered != null) return null;
    _lastNetworkChange = now;
    if (_state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
      return _trigger(ReconnectReason.networkChanged);
    }
    return check(now);
  }

  /// Reports that the app went to the background at [now].
  void appPaused(Duration now) {
    _pausedAt ??= now;
  }

  /// Reports that the app came back to the foreground at [now].
  ReconnectReason? appResumed(Duration now) {
    final pausedAt = _pausedAt;
    _pausedAt = null;
    if (_triggered != null) return null;
    final threshold = config.backgroundThreshold;
    if (pausedAt != null && threshold != null && now - pausedAt >= threshold) {
      return _trigger(ReconnectReason.resumedFromBackground);
    }
    // Timers may not have run while suspended: catch up.
    return check(now);
  }

  /// Reports that an SFU call failed because the session is gone.
  ReconnectReason? sessionGone(Duration now) {
    if (_triggered != null) return null;
    return _trigger(ReconnectReason.sessionGone);
  }

  /// Evaluates the pending timers at [now].
  ReconnectReason? check(Duration now) {
    if (_triggered != null) return null;
    final disconnectedSince = _disconnectedSince;
    if (disconnectedSince != null &&
        now - disconnectedSince >= config.disconnectedTimeout) {
      return _trigger(ReconnectReason.disconnectedTooLong);
    }
    final connectingSince = _connectingSince;
    final connectTimeout = config.connectTimeout;
    if (connectingSince != null &&
        connectTimeout != null &&
        now - connectingSince >= connectTimeout) {
      return _trigger(ReconnectReason.connectTimeout);
    }
    return null;
  }

  /// Starts over for a new session: clears the trigger, the timers, the
  /// last state and the network-change window. The background state is
  /// kept, since the app is still wherever it was.
  void reset() {
    _triggered = null;
    _state = null;
    _disconnectedSince = null;
    _connectingSince = null;
    _lastNetworkChange = null;
  }

  bool _withinNetworkChangeWindow(Duration now) {
    final last = _lastNetworkChange;
    return last != null && now - last <= config.networkChangeWindow;
  }

  ReconnectReason _trigger(ReconnectReason reason) {
    _disconnectedSince = null;
    _connectingSince = null;
    return _triggered = reason;
  }
}
