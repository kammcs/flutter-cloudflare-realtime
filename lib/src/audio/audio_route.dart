import 'package:flutter/foundation.dart';

/// What kind of output an [AudioRoute] is.
enum AudioRouteKind {
  /// The phone's loudspeaker.
  speaker,

  /// The phone's earpiece (iOS calls it the receiver).
  earpiece,

  /// A wired headset or headphones.
  wiredHeadset,

  /// A Bluetooth headset, earbuds or hearing aid.
  bluetooth,

  /// A USB headset or audio device.
  usb,

  /// Anything else, such as AirPlay or a car's audio.
  other;

  /// Whether this is something the user connected (a headset, a car), as
  /// opposed to the phone's own speaker or earpiece. Connected routes come
  /// first when the route is chosen automatically.
  bool get isExternal => this != speaker && this != earpiece;
}

/// Where a phone plays call audio: its speaker, its earpiece, or a
/// connected headset (`docs/design.md` §4.6).
///
/// Get them from `Room.audioRoutes` and pick one with
/// `Room.selectAudioRoute`. The [id] is the platform's and is only
/// meaningful while the route is listed.
@immutable
final class AudioRoute {
  /// Creates a route.
  const AudioRoute({required this.id, required this.kind, this.name = ''});

  /// The platform's identifier for this route.
  final String id;

  /// What kind of output it is.
  final AudioRouteKind kind;

  /// The device's name, such as "AirPods Pro", for connected devices;
  /// empty for the speaker and the earpiece, which apps label themselves.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is AudioRoute &&
      other.id == id &&
      other.kind == kind &&
      other.name == name;

  @override
  int get hashCode => Object.hash(id, kind, name);

  @override
  String toString() =>
      'AudioRoute(${kind.name}${name.isEmpty ? '' : ', "$name"'}, $id)';
}
