/// @docImport '../media/constraints.dart';
/// @docImport 'room.dart';
library;

import '../session/publish_options.dart';

/// Ready-made encodings for [LocalParticipant.publishScreen]
/// (`docs/design.md` §6 and §12, question 2).
///
/// Screen content is mostly text and still images, so the presets favour
/// resolution over frame rate: the full captured resolution, few frames per
/// second, and enough bitrate per frame to keep text readable. Pair each
/// preset with a matching capture rate ([ScreenShareOptions.frameRate]).
///
/// **The default is [detail]: one layer.** A screen share is usually what
/// everyone watches, on the stage, at full size. A second, low layer only
/// helps subscribers who show the share as a thumbnail, and costs the
/// sharer upload and encoder time. [simulcast] adds that layer for apps
/// that show shares small.
///
/// `flutter_webrtc` 1.6 has no `MediaStreamTrack.contentHint`, so the
/// encoder can't be told "this is text" directly. On macOS the desktop
/// capturer marks its video source as a screencast, which libwebrtc treats
/// as screen content. The numbers are starting points; check them on
/// devices.
abstract final class ScreenSharePresets {
  /// Documents, slides and code: one layer at the captured resolution, up
  /// to 15 fps and 2.5 Mbps. The default for screen shares.
  static const detail = <SendEncoding>[
    SendEncoding(maxBitrate: 2500000, maxFramerate: 15),
  ];

  /// Video or animation: one layer, up to 30 fps and 4 Mbps. Capture with
  /// `ScreenShareOptions(frameRate: 30)`.
  static const motion = <SendEncoding>[
    SendEncoding(maxBitrate: 4000000, maxFramerate: 30),
  ];

  /// Two layers: `a` as [detail] (full resolution, 15 fps, 2.5 Mbps) and a
  /// thumbnail layer `b` at a quarter of the resolution, 5 fps and 250 kbps.
  /// Subscribers pick a layer by tile size, as for cameras.
  ///
  /// For screen content, libwebrtc may shape the low layer its own way
  /// (screenshare simulcast); measure it before relying on its size.
  static const simulcast = <SendEncoding>[
    SendEncoding(rid: 'a', maxBitrate: 2500000, maxFramerate: 15),
    SendEncoding(
      rid: 'b',
      maxBitrate: 250000,
      scaleResolutionDownBy: 4,
      maxFramerate: 5,
    ),
  ];
}
