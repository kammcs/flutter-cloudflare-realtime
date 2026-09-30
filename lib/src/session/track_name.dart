import 'dart:math';

final Random _random = Random.secure();

/// Generates a unique track name: a random (version 4) UUID, as partytracks
/// does with `crypto.randomUUID()`.
///
/// Internal: not exported from the package barrel.
String generateTrackName([Random? random]) {
  final r = random ?? _random;
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // Version 4.
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // RFC 4122 variant.
  final hex = [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')];
  return '${hex.sublist(0, 4).join()}-${hex.sublist(4, 6).join()}-'
      '${hex.sublist(6, 8).join()}-${hex.sublist(8, 10).join()}-'
      '${hex.sublist(10).join()}';
}
