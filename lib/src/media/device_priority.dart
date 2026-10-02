import 'media_types.dart';

/// Label fragments (lowercase) of well-known virtual camera apps whose
/// cameras don't say "virtual", such as "Camera (NVIDIA Broadcast)". Left
/// first, one could open by default instead of the real webcam.
///
/// Cameras only: the same apps' microphones (NVIDIA Broadcast's noise
/// removal) are ones people choose on purpose, and keep their place. "obs"
/// isn't listed: OBS's camera is "OBS Virtual Camera" already, and "obs"
/// alone would also match OBSBOT, a brand of real webcams.
const _virtualCameraLabels = [
  'nvidia broadcast',
  'snap camera',
  'xsplit vcam',
  'manycam',
  'mmhmm',
];

/// Orders [devices] by how much a source should want them, ported from
/// partytracks' `devicePriority$`.
///
/// From first to last:
///
/// 1. the [preferred] device, if present;
/// 2. other devices, in the platform's order;
/// 3. virtual devices (label contains "virtual"), cameras of well-known
///    virtual camera apps whose labels don't say so (NVIDIA Broadcast, Snap
///    Camera, XSplit VCam, ManyCam, mmhmm), and the macOS Continuity
///    "iPhone Microphone", which partytracks also pushes down because they
///    tend to become the OS default without the user meaning it;
/// 4. devices in [deprioritized]: ones that recently failed to produce a
///    track.
///
/// Within each group, with a [facing], cameras facing that way come first,
/// then cameras that don't say ([MediaDevice.facing] `null`), then cameras
/// facing the other way. So a phone opens its front camera for
/// `CameraFacing.user` whatever order the platform lists it in, and
/// desktops, whose cameras don't say, keep the platform's order.
///
/// The sort is stable. Matching uses [MediaDevice.sameDeviceAs].
List<MediaDevice> prioritizeDevices(
  List<MediaDevice> devices, {
  MediaDevice? preferred,
  List<MediaDevice> deprioritized = const [],
  CameraFacing? facing,
}) {
  int rank(MediaDevice device) {
    if (preferred != null && device.sameDeviceAs(preferred)) return 0;
    if (deprioritized.any(device.sameDeviceAs)) return 3;
    final label = device.label.toLowerCase();
    if (label.contains('virtual') || label.contains('iphone microphone')) {
      return 2;
    }
    if (device.kind == MediaDeviceKind.videoInput &&
        _virtualCameraLabels.any(label.contains)) {
      return 2;
    }
    return 1;
  }

  int facingRank(MediaDevice device) {
    if (facing == null || device.facing == facing) return 0;
    return device.facing == null ? 1 : 2;
  }

  final ranked =
      [
        for (final (index, device) in devices.indexed)
          (rank(device), facingRank(device), index, device),
      ]..sort(
        (a, b) => a.$1 != b.$1
            ? a.$1 - b.$1
            : a.$2 != b.$2
            ? a.$2 - b.$2
            : a.$3 - b.$3,
      );
  return List.unmodifiable([for (final entry in ranked) entry.$4]);
}

/// The camera to switch to from [current], the same way on every platform.
///
/// - When [current] faces a known way and a camera among [cameras] faces
///   the other way, that camera (a phone's front/back flip). If several do,
///   the first by [prioritizeDevices], so a virtual camera comes last.
/// - Otherwise the camera after [current], wrapping around (desktops and
///   web cams, which don't say which way they face). The cycle follows
///   [prioritizeDevices], so virtual cameras and ones that recently failed
///   come last, and the order stays the same from switch to switch.
///
/// Returns `null` when there is no other camera. Devices without an ID
/// (the web before permission) can't be chosen and are skipped.
MediaDevice? nextCamera(
  List<MediaDevice> cameras, {
  MediaDevice? current,
  List<MediaDevice> deprioritized = const [],
}) {
  final usable = prioritizeDevices([
    for (final camera in cameras)
      if (camera.deviceId.isNotEmpty) camera,
  ], deprioritized: deprioritized);
  final others = [
    for (final camera in usable)
      if (current == null || !camera.sameDeviceAs(current)) camera,
  ];
  if (others.isEmpty) return null;
  final currentFacing = current?.facing;
  if (currentFacing != null) {
    final flipped = currentFacing == CameraFacing.user
        ? CameraFacing.environment
        : CameraFacing.user;
    final facingAway = [
      for (final camera in others)
        if (camera.facing == flipped) camera,
    ];
    if (facingAway.isNotEmpty) {
      return prioritizeDevices(facingAway, deprioritized: deprioritized).first;
    }
  }
  final index = current == null ? -1 : usable.indexWhere(current.sameDeviceAs);
  if (index < 0) return others.first;
  for (var step = 1; step < usable.length; step++) {
    final candidate = usable[(index + step) % usable.length];
    if (!candidate.sameDeviceAs(current!)) return candidate;
  }
  return null;
}
