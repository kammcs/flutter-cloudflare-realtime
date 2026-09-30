// The network-change source the example passes to CloudflareRealtime, so a
// room replaces a broken session as soon as the network changes instead of
// waiting out the disconnected timeout (docs/design.md §8).
//
// Why not connectivity_plus? The example has to build for the week-6
// checkpoint on Windows, macOS and Android, and every extra native plugin is
// one more thing that can break those builds. Watching the interface
// addresses with dart:io needs no plugin and sees the changes that matter
// (Wi-Fi to cellular, a cable pulled, a new address). Apps that already use
// connectivity_plus can wrap it instead in a few lines; see
// NetworkChangeSource's documentation. On the web there is no dart:io, so
// the example passes no source there.
export 'network_changes_stub.dart'
    if (dart.library.io) 'network_changes_io.dart';
