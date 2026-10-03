// Console diagnostics for the call screen: what the room did to stay
// connected, with UTC timestamps, so `flutter run` output shows how long a
// network drop took to recover and where the time went (docs/design.md §8.1).
//
// Only events, reasons, counts, durations and the package's error
// descriptions are printed. The package keeps SDP, tokens and header values
// out of its errors' descriptions, and nothing here adds any.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';

/// Prints [message] with a UTC timestamp and an `[area]` tag.
void logDiagnostic(String area, String message, {DateTime? now}) {
  final at = (now ?? DateTime.now()).toUtc().toIso8601String();
  debugPrint('[$area] $at $message');
}

/// Logs the reconnection-related room events: the session failing, each
/// reconnection attempt (reason, number, backoff delay and how long it
/// actually waited), its outcome, connection-state changes, and pulls that
/// failed. Returns whether [event] was one of them.
bool logReconnectEvent(RoomEvent event, {DateTime? now}) {
  final line = describeReconnectEvent(event);
  if (line == null) return false;
  logDiagnostic('reconnect', line, now: now);
  return true;
}

/// The log line for [event], or `null` when it isn't about reconnecting.
String? describeReconnectEvent(RoomEvent event) => switch (event) {
  RoomConnectionStateChangedEvent(:final state) => 'state: ${state.name}',
  RoomSessionFailedEvent(:final failure) => 'session failed: $failure',
  RoomReconnectingEvent(:final reason) => 'reconnecting (${reason.name})',
  RoomReconnectAttemptEvent(
    :final reason,
    :final attempt,
    :final delay,
    :final waited,
  ) =>
    'attempt $attempt (${reason.name}): backoff ${_seconds(delay)}, '
        'waited ${_seconds(waited)}'
        '${waited < delay ? ' (cut short)' : ''}',
  RoomErrorEvent(operation: 'reconnect', :final error) =>
    'attempt failed: $error',
  RoomErrorEvent(operation: 'signaling.update', :final error) =>
    'signaling update failed: $error',
  RoomReconnectedEvent(:final reason, :final duration, :final attempts) =>
    'reconnected (${reason.name}) in ${_seconds(duration)} '
        'after $attempts attempt${attempts == 1 ? '' : 's'}',
  RoomReconnectFailedEvent(:final reason, :final attempts, :final error) =>
    'gave up (${reason.name}) after $attempts attempt'
        '${attempts == 1 ? '' : 's'}${error == null ? '' : ': $error'}',
  TrackSubscriptionFailedEvent(
    :final publication,
    :final error,
    :final willRetry,
  ) =>
    'pull of ${publication.id} failed: $error'
        '${willRetry ? ' (will retry)' : ' (no retry)'}',
  _ => null,
};

String _seconds(Duration d) =>
    '${(d.inMilliseconds / 1000).toStringAsFixed(1)} s';
