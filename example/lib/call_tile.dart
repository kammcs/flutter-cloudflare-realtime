/// @docImport 'call_page.dart';
library;

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

/// What one tile shows.
class CallTileData {
  const CallTileData({
    required this.id,
    required this.label,
    this.participantId,
    this.video,
    this.micMuted = false,
    this.speaking,
    this.participant,
    this.publication,
    this.localPublication,
  });

  /// Stable across rebuilds (the publication ID for remote tracks).
  final String id;
  final String label;

  /// Whose tile this is, for the speaking highlight. `null` for screens.
  final String? participantId;
  final Widget? video;
  final bool micMuted;
  final Stream<bool>? speaking;

  /// Whose connection quality the tile shows.
  final Participant? participant;

  /// The remote video shown, for the layer overlay.
  final RemoteTrackPublication? publication;

  /// The local video shown, for the stats overlay.
  final LocalMediaPublication? localPublication;
}

/// One participant's (or screen's) video, with a name label, the
/// connection quality, a speaking highlight, and for remote video the
/// simulcast layer overlay (with the typed stats when [showStats]).
///
/// The video ([CallTileData.video], a [ParticipantVideoView]) keeps its
/// place in the widget tree whatever the tile shows around it, so its
/// renderer is bound once (see the comment in `build`).
class CallTile extends StatelessWidget {
  const CallTile({
    super.key,
    required this.data,
    this.showStats = false,
    this.dominant = false,
    this.pinned = false,
    this.compact = false,
  });

  final CallTileData data;

  /// Whether the overlay shows the typed stats.
  final bool showStats;

  /// The dominant speaker: a thicker highlight and a star.
  final bool dominant;
  final bool pinned;

  /// A thumbnail: smaller labels, no layer menu.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<bool>(
      stream: data.speaking,
      initialData: false,
      builder: (context, snapshot) {
        final speaking = snapshot.data ?? false;
        final Color? borderColor = speaking
            ? Colors.greenAccent
            : dominant
            ? Colors.amber
            : null;
        // The highlight is always there, transparent while off, so the
        // tree keeps its shape. A Container with a foregroundDecoration only
        // while speaking adds and removes a DecoratedBox above the video,
        // which re-creates the video view and its renderer (the self-view
        // blanked for a moment each time someone started or stopped
        // speaking, seen on Android; remote tiles too).
        return DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: borderColor ?? Colors.transparent,
              width: dominant ? 4 : 2,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              fit: StackFit.expand,
              children: [
                // The tile paints its own background, also behind the
                // bars of a `contain` video (a screen share). Without it the
                // tile's bounds didn't show: a portrait share read as a
                // strip beside its label, and the label and overlay looked
                // detached from the picture.
                ColoredBox(
                  color: tileBackground,
                  child: data.video ?? _Avatar(label: data.label),
                ),
                // The label and the overlay are positioned on both sides,
                // so they are never wider than the tile: they ellipsize or
                // wrap instead of drawing past its edge.
                Positioned(
                  left: 6,
                  bottom: 6,
                  right: 6,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: _Label(
                      label: data.label,
                      micMuted: data.micMuted,
                      speaking: speaking,
                      dominant: dominant,
                      pinned: pinned,
                      compact: compact,
                      participant: data.participant,
                    ),
                  ),
                ),
                if (data.publication case final publication?
                    when data.video != null)
                  Positioned(
                    top: 6,
                    left: 6,
                    right: 6,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: _LayerOverlay(
                        publication: publication,
                        compact: compact,
                        showStats: showStats,
                      ),
                    ),
                  )
                else if (data.localPublication case final publication?
                    when showStats && !compact)
                  Positioned(
                    top: 6,
                    left: 6,
                    right: 6,
                    child: Align(
                      alignment: Alignment.topRight,
                      child: _LocalStatsOverlay(publication: publication),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The tile's background, also behind a letterboxed video.
const tileBackground = Color(0xFF202124);

class _Avatar extends StatelessWidget {
  const _Avatar({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Center(
    child: CircleAvatar(
      radius: 28,
      child: Text(label.isEmpty ? '?' : label.characters.first.toUpperCase()),
    ),
  );
}

class _Label extends StatelessWidget {
  const _Label({
    required this.label,
    required this.micMuted,
    required this.speaking,
    required this.dominant,
    required this.pinned,
    required this.compact,
    this.participant,
  });

  final String label;
  final bool micMuted;
  final bool speaking;
  final bool dominant;
  final bool pinned;
  final bool compact;
  final Participant? participant;

  @override
  Widget build(BuildContext context) {
    final size = compact ? 12.0 : 16.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: [
            if (micMuted)
              Icon(Icons.mic_off, size: size, color: Colors.white)
            else if (speaking)
              Icon(Icons.graphic_eq, size: size, color: Colors.greenAccent),
            if (dominant) Icon(Icons.star, size: size, color: Colors.amber),
            if (pinned) Icon(Icons.push_pin, size: size, color: Colors.white),
            if (participant case final p?) _QualityBars(p, size: size),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white, fontSize: size - 2),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A participant's connection quality as signal bars (Participant.connectionQuality).
class _QualityBars extends StatelessWidget {
  const _QualityBars(this.participant, {required this.size});

  final Participant participant;
  final double size;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ConnectionQuality>(
      stream: participant.connectionQualityChanges,
      initialData: participant.connectionQuality,
      builder: (context, snapshot) {
        final quality = snapshot.data ?? ConnectionQuality.unknown;
        final (icon, color) = switch (quality) {
          ConnectionQuality.excellent => (
            Icons.signal_cellular_alt,
            Colors.greenAccent,
          ),
          ConnectionQuality.good => (
            Icons.signal_cellular_alt_2_bar,
            Colors.lightGreenAccent,
          ),
          ConnectionQuality.poor => (
            Icons.signal_cellular_alt_1_bar,
            Colors.orangeAccent,
          ),
          ConnectionQuality.lost => (
            Icons.signal_cellular_connected_no_internet_0_bar,
            Colors.redAccent,
          ),
          ConnectionQuality.unknown => (
            Icons.signal_cellular_null,
            Colors.white54,
          ),
        };
        return Tooltip(
          message: 'Connection: ${quality.name}',
          child: Icon(icon, size: size, color: color),
        );
      },
    );
  }
}

String _kbps(int? bitrate) => bitrate == null ? '?' : '${bitrate ~/ 1000} kbps';

String _size(int? width, int? height, double? fps) =>
    width == null || height == null
    ? '?'
    : '$width×$height${fps == null ? '' : ' ${fps.round()}fps'}';

/// The small dark chip the overlays draw their text on.
class _OverlayChip extends StatelessWidget {
  const _OverlayChip(this.lines, {this.compact = false});

  final List<String> lines;
  final bool compact;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Colors.black54,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: Text(
        lines.join('\n'),
        textAlign: TextAlign.right,
        style: TextStyle(
          color: Colors.white,
          fontSize: compact ? 10 : 12,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ),
  );
}

/// Debug overlay for a remote video: the simulcast layer asked for, the
/// resolution actually received (from the typed stats, Room.stats), and a
/// menu to override the automatic layer. With [showStats], also the codec,
/// bitrate, loss, jitter and freezes.
class _LayerOverlay extends StatelessWidget {
  const _LayerOverlay({
    required this.publication,
    this.compact = false,
    this.showStats = false,
  });

  final RemoteTrackPublication publication;
  final bool compact;
  final bool showStats;

  Future<void> _choose(BuildContext context, SimulcastLayer? layer) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await publication.setPreferredLayer(layer);
    } on Exception catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Layer change failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<RemoteTrackStats?>(
      // Listening makes the room poll its stats (every 2 s).
      stream: publication.statsChanges,
      initialData: publication.stats,
      builder: (context, stats) => StreamBuilder<RemoteTrackLayerState>(
        stream: publication.layerStateChanges,
        initialData: publication.layerState,
        builder: (context, snapshot) {
          final state = snapshot.data!;
          final s = stats.data;
          final manual = state.preferredLayer;
          final rid = state.currentRid ?? '-';
          final mode = manual == null ? 'auto' : manual.name;
          final lines = [
            [
              'rid $rid ($mode)',
              if (state.hidden) 'hidden',
              if (s?.height != null)
                _size(s!.width, s.height, s.framesPerSecond),
            ].join(' · '),
            if (showStats && s != null && !compact) ...[
              '${s.codec ?? '?'} · ${_kbps(s.bitrate)}',
              'loss ${s.packetLoss == null ? '?' : '${(s.packetLoss! * 100).toStringAsFixed(1)} %'}'
                  ' · jitter ${s.jitter?.inMilliseconds ?? '?'} ms',
              'freezes ${s.freezeCount ?? '?'} · dropped ${s.framesDropped ?? '?'}'
                  ' · pli ${s.pliCount ?? '?'}',
            ],
          ];
          final chip = _OverlayChip(lines, compact: compact);
          if (compact || publication.simulcast == null) return chip;
          // A null value would read as "cancelled", so "auto" is a string.
          return PopupMenuButton<String>(
            tooltip: 'Simulcast layer',
            onSelected: (choice) => _choose(
              context,
              choice == 'auto' ? null : SimulcastLayer.values.byName(choice),
            ),
            itemBuilder: (context) => [
              CheckedPopupMenuItem(
                value: 'auto',
                checked: manual == null,
                child: const Text('Auto (from tile size)'),
              ),
              for (final layer in SimulcastLayer.values)
                CheckedPopupMenuItem(
                  value: layer.name,
                  checked: manual == layer,
                  child: Text(
                    '${layer.name[0].toUpperCase()}${layer.name.substring(1)}'
                    ' (${layer.ridIn(publication.simulcast!.rids)})',
                  ),
                ),
            ],
            child: chip,
          );
        },
      ),
    );
  }
}

/// Stats overlay for a local video: each layer sent (size, frame rate,
/// bitrate, what limits it), and the connection's RTT and candidate types.
class _LocalStatsOverlay extends StatelessWidget {
  const _LocalStatsOverlay({required this.publication});

  final LocalMediaPublication publication;

  @override
  Widget build(BuildContext context) {
    final room = publication.participant.room;
    return StreamBuilder<RoomStats>(
      stream: room.statsChanges,
      initialData: room.stats,
      builder: (context, snapshot) {
        final stats = snapshot.data;
        final track = stats?.local[publication.trackName];
        final connection = stats?.connection;
        final lines = [
          if (track != null) ...[
            track.codec ?? '?',
            for (final layer in track.layers)
              '${layer.rid ?? '-'}: '
                  '${_size(layer.width, layer.height, layer.framesPerSecond)} '
                  '${_kbps(layer.bitrate)}'
                  '${switch (layer.qualityLimitationReason) {
                    null || QualityLimitationReason.none => '',
                    final reason => ' (${reason.name})',
                  }}',
          ],
          if (connection != null)
            'rtt ${connection.roundTripTime?.inMilliseconds ?? '?'} ms · '
                '${connection.localCandidate?.type?.name ?? '?'}'
                '${connection.isRelayed ? ' (relayed)' : ''} · '
                'out ${_kbps(connection.availableOutgoingBitrate)}',
        ];
        if (lines.isEmpty) return const SizedBox.shrink();
        return _OverlayChip(lines);
      },
    );
  }
}
