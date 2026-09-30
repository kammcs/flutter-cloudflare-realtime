import 'dart:async';
import 'dart:io';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';

/// Network changes from polling the device's interface addresses.
NetworkChangeSource? createNetworkChangeSource() =>
    InterfacePollingNetworkChanges();

/// Reports a network change whenever the set of interface addresses
/// changes, checked every [interval] while someone listens.
///
/// It sees an interface going down or up and a new address, which is what
/// breaks (or can repair) a peer connection's path. A change it reports
/// while the connection is fine only shortens the room's wait if the
/// connection drops soon after, so the occasional harmless change (an IPv6
/// privacy address rotating) costs nothing.
class InterfacePollingNetworkChanges implements NetworkChangeSource {
  InterfacePollingNetworkChanges({this.interval = const Duration(seconds: 2)});

  /// How often the interfaces are listed.
  final Duration interval;

  @override
  Stream<void> get changes => Stream.multi((controller) {
    String? last;
    var polling = false;
    Future<void> poll() async {
      if (polling) return;
      polling = true;
      try {
        final interfaces = await NetworkInterface.list();
        final addresses = [
          for (final i in interfaces)
            for (final a in i.addresses) '${i.name}/${a.address}',
        ]..sort();
        final signature = addresses.join(',');
        if (last != null && signature != last && !controller.isClosed) {
          controller.add(null);
        }
        last = signature;
      } catch (_) {
        // Listing can fail transiently; try again at the next tick.
      } finally {
        polling = false;
      }
    }

    unawaited(poll());
    final timer = Timer.periodic(interval, (_) => poll());
    controller.onCancel = timer.cancel;
  });
}
