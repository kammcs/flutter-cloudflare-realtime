import 'dart:async';
import 'dart:io';

import 'package:cloudflare_realtime/cloudflare_realtime.dart';

import 'call_diagnostics.dart';

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
///
/// Listeners share one poll (the room and the example's signaling both
/// listen), so each change is listed and logged once.
class InterfacePollingNetworkChanges implements NetworkChangeSource {
  InterfacePollingNetworkChanges({this.interval = const Duration(seconds: 2)});

  /// How often the interfaces are listed.
  final Duration interval;

  late final StreamController<void> _changes = StreamController.broadcast(
    onListen: _start,
    onCancel: _stop,
  );
  Timer? _timer;
  String? _last;
  var _polling = false;

  @override
  Stream<void> get changes => _changes.stream;

  void _start() {
    _last = null;
    unawaited(_poll());
    _timer = Timer.periodic(interval, (_) => _poll());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final interfaces = await NetworkInterface.list();
      final addresses = [
        for (final i in interfaces)
          for (final a in i.addresses) '${i.name}/${a.address}',
      ]..sort();
      final signature = addresses.join(',');
      if (_timer == null) return; // Nobody listens any more.
      if (_last != null && signature != _last) {
        // Interface names and a count, never the addresses themselves.
        final names = {
          for (final i in interfaces)
            if (i.addresses.isNotEmpty) i.name,
        };
        logDiagnostic(
          'network',
          'interfaces changed: ${addresses.length} addresses on '
              '${names.isEmpty ? 'no interface' : names.join(', ')}',
        );
        _changes.add(null);
      }
      _last = signature;
    } catch (_) {
      // Listing can fail transiently; try again at the next tick.
    } finally {
      _polling = false;
    }
  }
}
