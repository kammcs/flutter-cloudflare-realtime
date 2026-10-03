/// @docImport '../room/cloudflare_realtime.dart';
/// @docImport 'reconnect_trigger.dart';
library;

/// Tells a room when the device's network changes, so it can replace a
/// broken SFU session sooner (`docs/design.md` §8).
///
/// The core package has no connectivity plugin, so by default rooms get no
/// network events and rely on the peer connection's state alone. Pass an
/// implementation to [CloudflareRealtime] to add them, for example one
/// built on `connectivity_plus`:
///
/// ```dart
/// class ConnectivityPlusChanges implements NetworkChangeSource {
///   @override
///   Stream<void> get changes => Connectivity().onConnectivityChanged;
/// }
/// ```
///
/// What a change does depends on the connection (see
/// [ReconnectTriggerOptions.networkChangeWindow]): while the peer connection
/// is `disconnected`, the session is replaced at once; while it is
/// connected, a change only shortens the wait if the connection drops soon
/// after, because platforms report changes that don't break anything (a
/// second interface coming up). While a reconnection is waiting to retry,
/// a change makes it retry at once.
abstract interface class NetworkChangeSource {
  /// Emits whenever the network changes: an interface comes up or goes
  /// down, Wi-Fi to cellular, a new address. The values are ignored.
  ///
  /// Every room listens while it is joined, so this must allow several
  /// listeners over time (a broadcast stream, or a new stream per call).
  Stream<void> get changes;
}
