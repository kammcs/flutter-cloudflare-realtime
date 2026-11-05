/// @docImport '../room/room.dart';
/// @docImport 'screen_share_source.dart';
library;

import 'package:flutter/foundation.dart';

import 'media_types.dart';

/// What the user picked in the system's screen-share dialog on Linux in a
/// Wayland session (the ScreenCast portal), kept so a later share can share
/// it again without the dialog.
///
/// [ScreenShareSource.systemPick] is the pick of the running (or last)
/// share, and [LocalParticipant.lastSystemScreenPick] the last one in the
/// room. Pass it to [ScreenShareSource.start] or
/// [LocalParticipant.publishScreen] as `restore` to share the same screen
/// or window again with no dialog. A pick the system no longer knows (the
/// window closed, the token expired) opens the dialog again.
///
/// Picks live in memory until the app exits; nothing is stored. [id] is
/// opaque: `flutter_webrtc` reports it as the video track's
/// `settings.deviceId`, and takes it back as `deviceId: {exact: id}`.
@immutable
final class SystemScreenPick {
  /// Wraps an [id] that `flutter_webrtc` reported.
  const SystemScreenPick(this.id);

  /// The opaque restore ID.
  final String id;

  @override
  bool operator ==(Object other) => other is SystemScreenPick && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SystemScreenPick(…)';
}

/// A PipeWire stream that another component already opened through the
/// portal, shared without a dialog: on Linux, a remote-control session that
/// combines RemoteDesktop and ScreenCast in one portal session (one dialog
/// for both) hands its screen-cast stream to the call.
///
/// Pass it to [ScreenShareSource.start] or [LocalParticipant.publishScreen]
/// as `pipewireStream`. On a running share, [ScreenShareSource.start]
/// switches to it in place: the publication stays published and its sender
/// gets the new track, so the remote side sees no unpublish (only a short
/// gap in frames).
///
/// **Who owns what.** The component that opened the portal session owns it,
/// and [fd] with it: the share never closes them. When the session closes,
/// the stream ends and the share ends as [ScreenShareEndReason.userStopped].
/// The other way round, when the share ends for another reason while the
/// session is still open (the app stops it, a PipeWire error), the app must
/// close that session itself, or the system keeps showing that the screen
/// is shared.
@immutable
final class PipeWireScreenStream {
  /// Describes a stream.
  const PipeWireScreenStream({
    required this.fd,
    required this.nodeId,
    this.geometry,
    this.type,
  });

  /// The PipeWire remote's file descriptor (`OpenPipeWireRemote`).
  final int fd;

  /// The stream's PipeWire node ID (the portal's `streams` entry).
  final int nodeId;

  /// Where the stream's source is, as the portal reports it: its
  /// `position` and `size` in the compositor's **logical** coordinates
  /// (not scaled to pixels), which is also where libei regions map input.
  /// [ScreenGeometry.scaleFactor] is 1.0 unless the owner knows the scale.
  /// Becomes [ScreenShareSource.sourceGeometry] while shared; update it
  /// with [ScreenShareSource.updatePipeWireGeometry]. `null` when unknown.
  final ScreenGeometry? geometry;

  /// Whether the stream is a monitor or a window (the portal's
  /// `source_type`), or `null` when unknown.
  final ScreenSourceType? type;

  @override
  bool operator ==(Object other) =>
      other is PipeWireScreenStream && other.fd == fd && other.nodeId == nodeId;

  @override
  int get hashCode => Object.hash(fd, nodeId);

  @override
  String toString() => 'PipeWireScreenStream(node $nodeId)';
}
