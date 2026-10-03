import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/system_call_demo.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(SystemCalls.debugReset);

  Future<(SystemCall, Future<bool>)> ring(WidgetTester tester) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) {
            context = c;
            return const Scaffold();
          },
        ),
      ),
    );
    // On the test host the calls are kept in Dart only (no CallKit or
    // Telecom), with the same flow. Set up in the test's (fake async)
    // zone, so the calls' events arrive with each pump.
    await SystemCalls.instance.configure();
    final call = await SystemCalls.instance.reportIncomingCall(
      handle: const CallHandle('demo-caller'),
      displayName: 'Demo caller',
    );
    final answered = showIncomingCall(context, call);
    await tester.pumpAndSettle();
    expect(find.text('Demo caller'), findsOneWidget);
    return (call, answered);
  }

  // As from a locked phone's lock screen: the outcome comes from the call,
  // not from the dialog (which isn't built while the app is in the
  // background), and the dialog goes.
  testWidgets('answered in the system UI: true, and the dialog goes', (
    tester,
  ) async {
    final (call, answered) = await ring(tester);
    await call.answer();
    expect(await answered, isTrue);
    await tester.pumpAndSettle();
    expect(find.text('Demo caller'), findsNothing);
  });

  testWidgets('declined in the system UI: false, as declined', (tester) async {
    final (call, answered) = await ring(tester);
    await call.end();
    expect(await answered, isFalse);
    expect(call.endReason, SystemCallEndReason.declined);
    await tester.pumpAndSettle();
    expect(find.text('Demo caller'), findsNothing);
  });

  testWidgets('answered in the dialog: true', (tester) async {
    final (call, answered) = await ring(tester);
    await tester.tap(find.text('Answer'));
    await tester.pumpAndSettle();
    expect(await answered, isTrue);
    expect(call.state, SystemCallState.active);
    expect(find.text('Demo caller'), findsNothing);
  });

  testWidgets('beginBackgroundTask does nothing off iOS', (tester) async {
    final end = await beginBackgroundTask('test');
    await end();
    await end();
  });
}
