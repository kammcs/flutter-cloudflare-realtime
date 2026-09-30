import 'package:cloudflare_realtime/cloudflare_realtime.dart';
import 'package:cloudflare_realtime_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('joins a room and lists the other participants', (tester) async {
    final hub = InMemorySignalingHub();
    await tester.pumpWidget(ExampleApp(hub: hub));

    expect(find.text('Join a room'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Your name'), 'ada');
    await tester.tap(find.text('Join'));
    await tester.pumpAndSettle();

    expect(find.text('Room: demo'), findsOneWidget);
    expect(find.text('Video tiles will appear here.'), findsOneWidget);
    expect(find.text('No one else is here yet.'), findsOneWidget);
    expect(hub.participantsIn('demo').single.participantId, 'ada');

    // Someone else joins through the same hub.
    final bob = InMemorySignaling(hub);
    await bob.join('demo', ParticipantState(participantId: 'bob'));
    await tester.pumpAndSettle();
    expect(find.text('bob'), findsOneWidget);

    // A simulated participant, added from the UI.
    await tester.tap(find.text('Add simulated participant'));
    await tester.pumpAndSettle();
    expect(find.text('guest-1'), findsOneWidget);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('guest-1'), findsNothing);

    await bob.leave();
    await tester.pumpAndSettle();
    expect(find.text('No one else is here yet.'), findsOneWidget);

    await tester.tap(find.byTooltip('Leave'));
    await tester.pumpAndSettle();
    expect(find.text('Join a room'), findsOneWidget);
    expect(hub.roomIds, isEmpty);

    await bob.dispose();
  });
}
