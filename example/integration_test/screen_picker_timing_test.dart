// ignore_for_file: avoid_print
// Times the desktop source picker: how long `getDesktopSources` and each
// `updateDesktopSources` re-scan take, and how long the event loop stalls
// while a ScreenSourcePicker is open (docs/design.md §10, Picking a
// source). On macOS the plugin lists sources and makes their thumbnails
// on the main thread, which is the UI thread, so a stall there is a frozen
// app.
//
// Opens a picker [_opens] times, each for [_openFor] with its default
// 3 s re-scan, the way an app's share dialog does, and prints one
// `PICKER` line per call, per gap over 100 ms and per opening. Desktop
// only; needs no broker. Listing windows needs the Screen Recording
// permission on macOS.

import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/call_timing.dart';

final _desktop =
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS);

const _opens = 3;
const _openFor = Duration(seconds: 8);

void _log(String message) => print('PICKER $message');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the source picker keeps the event loop running', (tester) async {
    await tester.pumpWidget(const SizedBox.expand());
    final timing = CallTiming.start(
      options: const PlatformCallTimingOptions(
        gapThreshold: Duration(milliseconds: 100),
        log: false,
      ),
    );
    final perOpen = <String>[];
    for (var open = 1; open <= _opens; open++) {
      final from = timing.now;
      final picker = ScreenSourcePicker();
      final opened = Stopwatch()..start();
      await tester.runAsync(picker.start);
      final listedIn = opened.elapsed;
      await tester.runAsync(() => Future<void>.delayed(_openFor));
      await tester.runAsync(picker.dispose);
      final sources = picker.state.sources;
      final calls = [
        for (final call in timing.calls)
          if (call.sentAt >= from &&
              (call.method == 'getDesktopSources' ||
                  call.method == 'updateDesktopSources'))
            call,
      ];
      for (final call in calls) {
        _log(
          'open $open: ${call.method} ${call.duration!.inMilliseconds} ms '
          '(+${call.sentAt.inMilliseconds} ms)',
        );
      }
      for (final line in timing.describeGaps(from: from)) {
        _log('open $open: $line');
      }
      final updates = [
        for (final c in calls)
          if (c.method == 'updateDesktopSources') c.duration!.inMilliseconds,
      ];
      final line =
          'open $open: ${sources.length} sources '
          '(${sources.where((s) => s.thumbnail != null).length} with '
          'thumbnails), listed in ${listedIn.inMilliseconds} ms, '
          'updates $updates ms, longest gap '
          '${timing.longestGap(from: from).inMilliseconds} ms';
      perOpen.add(line);
      _log(line);
      expect(picker.state.error, isNull);
    }
    _log('SUMMARY');
    perOpen.forEach(_log);
  }, skip: !_desktop);
}
