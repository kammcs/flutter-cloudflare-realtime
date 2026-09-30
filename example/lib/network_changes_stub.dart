import 'package:cloudflare_realtime/cloudflare_realtime.dart';

/// No network-change events on this platform (the web).
NetworkChangeSource? createNetworkChangeSource() => null;
