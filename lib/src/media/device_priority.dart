import 'media_types.dart';

/// Orders [devices] by how much a source should want them, ported from
/// partytracks' `devicePriority$`.
///
/// From first to last:
///
/// 1. the [preferred] device, if present;
/// 2. other devices, in the platform's order;
/// 3. virtual devices (label contains "virtual") and the macOS Continuity
///    "iPhone Microphone", which partytracks also pushes down because they
///    tend to become the OS default without the user meaning it;
/// 4. devices in [deprioritized]: ones that recently failed to produce a
///    track.
///
/// The sort is stable. Matching uses [MediaDevice.sameDeviceAs].
List<MediaDevice> prioritizeDevices(
  List<MediaDevice> devices, {
  MediaDevice? preferred,
  List<MediaDevice> deprioritized = const [],
}) {
  int rank(MediaDevice device) {
    if (preferred != null && device.sameDeviceAs(preferred)) return 0;
    if (deprioritized.any(device.sameDeviceAs)) return 3;
    final label = device.label.toLowerCase();
    if (label.contains('virtual') || label.contains('iphone microphone')) {
      return 2;
    }
    return 1;
  }

  final ranked = [
    for (final (index, device) in devices.indexed)
      (rank(device), index, device),
  ]..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  return List.unmodifiable([for (final entry in ranked) entry.$3]);
}
