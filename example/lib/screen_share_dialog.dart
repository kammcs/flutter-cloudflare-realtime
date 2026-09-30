import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/material.dart';

/// What the screen share is for, which sets the capture rate and encoding
/// (`docs/design.md` §12, question 2).
enum ScreenContent {
  /// Documents, slides, code: 15 fps, one sharp layer. The default.
  text('Text', ScreenSharePresets.detail, 15),

  /// Video or animation: 30 fps, one layer.
  motion('Motion', ScreenSharePresets.motion, 30),

  /// Text, plus a small layer for viewers who show the share as a
  /// thumbnail (simulcast).
  textWithThumbnail('Text + thumbnail layer', ScreenSharePresets.simulcast, 15);

  const ScreenContent(this.label, this.encodings, this.frameRate);

  final String label;
  final List<SendEncoding> encodings;
  final int frameRate;
}

/// What [ScreenShareDialog] returns: the source (none on the web, where the
/// browser picks) and how to capture and send it.
class ShareChoice {
  const ShareChoice({
    this.source,
    this.content = ScreenContent.text,
    this.audio = false,
  });

  final ScreenSource? source;
  final ScreenContent content;
  final bool audio;

  ScreenShareOptions get options =>
      ScreenShareOptions(frameRate: content.frameRate, captureAudio: audio);

  List<SendEncoding> get encodings => content.encodings;
}

/// The "share your screen" dialog: the desktop sources with thumbnails (from
/// [picker]; `null` on the web, where the browser shows its own picker
/// next), what the share is for, and whether to share audio.
///
/// On macOS it shows how to grant the Screen Recording permission when the
/// picker suspects it is missing
/// ([ScreenPickerState.permissionProblem]).
class ScreenShareDialog extends StatefulWidget {
  const ScreenShareDialog({
    super.key,
    required this.picker,
    this.canShareAudio = false,
  });

  final ScreenSourcePicker? picker;

  /// Whether the platform captures audio with a share (Windows loopback,
  /// Chromium tab audio).
  final bool canShareAudio;

  @override
  State<ScreenShareDialog> createState() => _ScreenShareDialogState();
}

class _ScreenShareDialogState extends State<ScreenShareDialog> {
  ScreenContent _content = ScreenContent.text;
  bool _audio = false;

  @override
  void initState() {
    super.initState();
    widget.picker?.start();
  }

  void _pick(ScreenSource? source) =>
      Navigator.of(context)
          .pop(ShareChoice(source: source, content: _content, audio: _audio));

  @override
  Widget build(BuildContext context) {
    final picker = widget.picker;
    return AlertDialog(
      title: const Text('Share your screen'),
      scrollable: true,
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            SegmentedButton<ScreenContent>(
              segments: [
                for (final content in ScreenContent.values)
                  ButtonSegment(value: content, label: Text(content.label)),
              ],
              selected: {_content},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() => _content = s.single),
            ),
            if (widget.canShareAudio)
              CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: _audio,
                onChanged: (v) => setState(() => _audio = v ?? false),
                title: const Text('Share audio too'),
              ),
            if (picker == null)
              const Text('Your browser asks what to share next.')
            else
              _SourceGrid(picker: picker, onPick: _pick),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        if (picker == null)
          FilledButton(
            onPressed: () => _pick(null),
            child: const Text('Choose…'),
          ),
      ],
    );
  }
}

class _SourceGrid extends StatelessWidget {
  const _SourceGrid({required this.picker, required this.onPick});

  final ScreenSourcePicker picker;
  final ValueChanged<ScreenSource> onPick;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ScreenPickerState>(
      stream: picker.state,
      initialData: picker.currentState,
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final colors = Theme.of(context).colorScheme;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: [
            if (state.permissionProblem case final problem?)
              Material(
                color: colors.errorContainer,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    'This app may not have permission to record the '
                    'screen. ${problem.guidance}',
                    style: TextStyle(color: colors.onErrorContainer),
                  ),
                ),
              ),
            if (state.error != null && state.sources.isEmpty)
              Row(
                children: [
                  const Expanded(child: Text('Listing screens failed.')),
                  TextButton(
                    onPressed: picker.refresh,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            SizedBox(
              height: 280,
              child: state.sources.isEmpty
                  ? Center(
                      child: state.isLoading
                          ? const CircularProgressIndicator()
                          : const Text('Nothing to share.'),
                    )
                  : GridView.extent(
                      maxCrossAxisExtent: 180,
                      childAspectRatio: 4 / 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      children: [
                        for (final source in state.sources)
                          InkWell(
                            onTap: () => onPick(source),
                            child: Column(
                              children: [
                                Expanded(child: _Thumbnail(source: source)),
                                Text(
                                  source.name.isEmpty
                                      ? '(untitled)'
                                      : source.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// A source's thumbnail, or an icon while there is none or it can't be
/// decoded (macOS sends TIFF, which Flutter's codecs may not read).
class _Thumbnail extends StatelessWidget {
  const _Thumbnail({required this.source});

  final ScreenSource source;

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      source.type == ScreenSourceType.screen
          ? Icons.desktop_windows
          : Icons.web_asset,
      size: 40,
    );
    final thumbnail = source.thumbnail;
    if (thumbnail == null) return icon;
    return Image.memory(
      thumbnail,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => icon,
    );
  }
}
