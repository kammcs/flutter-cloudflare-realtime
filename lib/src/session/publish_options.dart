import 'package:flutter/foundation.dart';

/// One encoding (simulcast layer) of a published video track.
///
/// Maps to a WebRTC `RTCRtpEncodingParameters` entry in the transceiver's
/// `sendEncodings`. Subscribers pick a layer by its [rid] (see
/// `docs/design.md` §6).
@immutable
class SendEncoding {
  /// Creates an encoding.
  const SendEncoding({
    this.rid,
    this.maxBitrate,
    this.scaleResolutionDownBy,
    this.maxFramerate,
    this.active = true,
  });

  /// The RTP stream ID naming this layer, such as `a`, `b` or `c`. Required
  /// for simulcast; omit it for a single encoding.
  final String? rid;

  /// The layer's maximum bitrate, in bits per second.
  final int? maxBitrate;

  /// How much to scale the width and height down, for example `2` for half
  /// resolution. Null means full resolution.
  final double? scaleResolutionDownBy;

  /// The layer's maximum frame rate.
  final int? maxFramerate;

  /// Whether the layer is sent.
  final bool active;

  /// Returns a copy with the given fields replaced.
  SendEncoding copyWith({
    String? rid,
    int? maxBitrate,
    double? scaleResolutionDownBy,
    int? maxFramerate,
    bool? active,
  }) => SendEncoding(
    rid: rid ?? this.rid,
    maxBitrate: maxBitrate ?? this.maxBitrate,
    scaleResolutionDownBy: scaleResolutionDownBy ?? this.scaleResolutionDownBy,
    maxFramerate: maxFramerate ?? this.maxFramerate,
    active: active ?? this.active,
  );

  @override
  bool operator ==(Object other) =>
      other is SendEncoding &&
      other.rid == rid &&
      other.maxBitrate == maxBitrate &&
      other.scaleResolutionDownBy == scaleResolutionDownBy &&
      other.maxFramerate == maxFramerate &&
      other.active == active;

  @override
  int get hashCode =>
      Object.hash(rid, maxBitrate, scaleResolutionDownBy, maxFramerate, active);

  @override
  String toString() =>
      'SendEncoding(rid: $rid, maxBitrate: $maxBitrate, '
      'scaleResolutionDownBy: $scaleResolutionDownBy, '
      'maxFramerate: $maxFramerate, active: $active)';
}

/// Ready-made simulcast encodings for video (`docs/design.md` §6).
///
/// Every preset has three layers named so that `a` is the highest: `a` at
/// full resolution, `b` at half (`scaleResolutionDownBy: 2`) and `c` at a
/// quarter (`4`). Subscribers can then use the SFU's `asciibetical`
/// ordering. The bitrates are starting points; roadmap M4 tunes them.
abstract final class SimulcastPresets {
  /// For a 720p camera: about 1.2 Mbps, 400 kbps and 150 kbps.
  static const h720 = <SendEncoding>[
    SendEncoding(rid: 'a', maxBitrate: 1200000),
    SendEncoding(rid: 'b', maxBitrate: 400000, scaleResolutionDownBy: 2),
    SendEncoding(rid: 'c', maxBitrate: 150000, scaleResolutionDownBy: 4),
  ];

  /// For a 1080p source: about 2.5 Mbps, 800 kbps and 250 kbps.
  static const h1080 = <SendEncoding>[
    SendEncoding(rid: 'a', maxBitrate: 2500000),
    SendEncoding(rid: 'b', maxBitrate: 800000, scaleResolutionDownBy: 2),
    SendEncoding(rid: 'c', maxBitrate: 250000, scaleResolutionDownBy: 4),
  ];

  /// For a 360p source: about 500 kbps, 180 kbps and 80 kbps.
  static const h360 = <SendEncoding>[
    SendEncoding(rid: 'a', maxBitrate: 500000),
    SendEncoding(rid: 'b', maxBitrate: 180000, scaleResolutionDownBy: 2),
    SendEncoding(rid: 'c', maxBitrate: 80000, scaleResolutionDownBy: 4),
  ];
}

/// The default video codec preference for the current platform, as MIME
/// types in order of preference.
///
/// `['video/VP8']` on every platform.
///
/// The SFU forwards each publisher's codec unchanged, so one publisher's
/// codec choice is every subscriber's decoder. H.264 has crashed
/// `flutter_webrtc` on Windows (flutter-webrtc #982), so a Windows participant
/// must not receive it from a Mac or phone that prefers it. VP8 decodes
/// everywhere. Set [SfuSessionDefaults.videoCodecPreferences] (or
/// [PublishOptions.codecPreferences]) to `const []` for the platform's own
/// order, for example to use hardware H.264 in a room without Windows peers.
List<String> defaultVideoCodecPreferences() => const ['video/VP8'];

/// A video codec to publish with (`docs/design.md` §6, Codec).
///
/// The SFU accepts H.264, H.265, VP8, VP9 and AV1, and forwards each
/// publisher's codec unchanged: every subscriber must decode what a
/// publisher sends. Which encoders and decoders exist depends on the
/// platform's WebRTC build.
enum VideoCodec {
  /// VP8: the default. Software, decodes on every platform, and its
  /// simulcast is the best trodden.
  vp8('video/VP8'),

  /// H.264: hardware encoding on most phones and Macs, which saves battery.
  ///
  /// **Not sent from Windows**: H.264 has crashed `flutter_webrtc` there
  /// (flutter-webrtc #982), so a Windows publisher sends VP8 instead, and a
  /// room with Windows subscribers should stay on VP8. Simulcast runs one
  /// hardware encoder per layer, which some devices limit.
  h264('video/H264'),

  /// VP9: experimental here. Where the platform can't encode it, VP8 is
  /// sent.
  vp9('video/VP9'),

  /// AV1: experimental here. Where the platform can't encode it, VP8 is
  /// sent.
  av1('video/AV1');

  const VideoCodec(this.mimeType);

  /// The codec's MIME type, as in `RTCRtpCodecCapability.mimeType`.
  final String mimeType;

  /// The codec preferences to publish with: this codec, then VP8 as the
  /// fallback for a platform without this codec's encoder.
  List<String> get codecPreferences =>
      this == vp8 ? const ['video/VP8'] : [mimeType, 'video/VP8'];
}

/// Options for one published track.
///
/// Null fields fall back to the session's [SfuSessionDefaults].
@immutable
class PublishOptions {
  /// Creates publish options.
  const PublishOptions({
    this.trackName,
    this.sendEncodings,
    this.codecPreferences,
  });

  /// The name the track is published under. Other participants pull it by
  /// this name and the publisher's session ID. If null, a unique name is
  /// generated. Must be unique within the session.
  final String? trackName;

  /// The encodings to send. Null uses [SfuSessionDefaults.videoEncodings]
  /// for video and no encodings for audio. An empty list sends one encoding
  /// with the platform's defaults (no simulcast).
  final List<SendEncoding>? sendEncodings;

  /// Codec MIME types in order of preference, such as `['video/VP8']`. Null
  /// uses the session default for the track's kind. An empty list leaves
  /// the platform's order.
  ///
  /// When set, the transceiver offers only these codecs (plus
  /// retransmission and FEC), so the SFU can't pick another one.
  final List<String>? codecPreferences;
}

/// Session-wide defaults for [PublishOptions].
@immutable
class SfuSessionDefaults {
  /// Creates defaults.
  const SfuSessionDefaults({
    this.videoEncodings = SimulcastPresets.h720,
    this.videoCodecPreferences,
    this.audioCodecPreferences = const [],
  });

  /// The encodings for published video tracks. Simulcast is on by default
  /// ([SimulcastPresets.h720]); `docs/design.md` §6 explains why.
  final List<SendEncoding> videoEncodings;

  /// Video codec preferences. Null means [defaultVideoCodecPreferences],
  /// evaluated when a track is published.
  final List<String>? videoCodecPreferences;

  /// Audio codec preferences. Empty leaves the platform's order (Opus).
  final List<String> audioCodecPreferences;
}
