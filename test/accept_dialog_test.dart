import 'dart:async';

import 'package:easysend/globals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
  );

  setUp(() => xdef['Program language'] = 'en');

  testWidgets('the question is withdrawn when the receiver aborts it', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Completer<void> abort = Completer<void>();
    final Future<(bool, bool)> answer = showAcceptDialog(
      senderName: 'Peer',
      fileCount: 2,
      totalBytes: 2048,
      cancelled: abort.future,
    );
    await tester.pump();
    expect(find.text('Incoming files'), findsOneWidget);

    abort.complete();
    await tester.pumpAndSettle();

    expect(find.text('Incoming files'), findsNothing);
    expect(await answer, (false, false));
  });

  testWidgets('rebuilding the app does not leave a deadline behind', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<(bool, bool)> answer = showAcceptDialog(
      senderName: 'Peer',
      fileCount: 1,
      totalBytes: 1,
    );
    await tester.pump();
    expect(find.text('Incoming files'), findsOneWidget);

    // What a language or theme change does: the whole app is rebuilt under the
    // open dialog, and its route is rebuilt with it.
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        theme: ThemeData(brightness: Brightness.dark),
        home: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(find.text('Incoming files'), findsOneWidget);

    await tester.tap(find.text('Decline'));
    await tester.pumpAndSettle();
    expect(await answer, (false, false));
    // The test itself fails on any timer still pending here, which is the
    // whole point: a deadline started inside the builder outlived its dialog.
  });

  testWidgets('an answer given before the abort still counts', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Completer<void> abort = Completer<void>();
    final Future<(bool, bool)> answer = showAcceptDialog(
      senderName: 'Peer',
      fileCount: 1,
      totalBytes: 1,
      cancelled: abort.future,
    );
    await tester.pump();

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    // Whatever the receiver does afterwards must not rewrite the answer.
    abort.complete();
    await tester.pumpAndSettle();

    expect(await answer, (true, false));
  });
}
