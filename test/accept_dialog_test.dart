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
    final Future<(bool, bool, ConflictMode)> answer = showAcceptDialog(
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
    expect(await answer, (false, false, ConflictMode.copies));
  });

  testWidgets('rebuilding the app does not leave a deadline behind', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<(bool, bool, ConflictMode)> answer = showAcceptDialog(
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
    expect(await answer, (false, false, ConflictMode.copies));
    // The test itself fails on any timer still pending here, which is the
    // whole point: a deadline started inside the builder outlived its dialog.
  });

  testWidgets('an answer given before the abort still counts', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Completer<void> abort = Completer<void>();
    final Future<(bool, bool, ConflictMode)> answer = showAcceptDialog(
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

    expect(await answer, (true, false, ConflictMode.copies));
  });

  testWidgets('names that are already taken are asked about', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<(bool, bool, ConflictMode)> answer = showAcceptDialog(
      senderName: 'Peer',
      fileCount: 5,
      totalBytes: 5,
      occupied: 3,
    );
    await tester.pump();

    expect(find.text('Such files are already here: 3'), findsOneWidget);
    // The default is what the app has always done.
    expect(find.text('Add copies'), findsOneWidget);
    await tester.tap(find.text('Keep what is here'));
    await tester.pump();
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(await answer, (true, false, ConflictMode.keep));
  });

  testWidgets('nothing is asked about names when none are taken', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<(bool, bool, ConflictMode)> answer = showAcceptDialog(
      senderName: 'Peer',
      fileCount: 1,
      totalBytes: 1,
    );
    await tester.pump();

    expect(find.text('Add copies'), findsNothing);
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(await answer, (true, false, ConflictMode.copies));
  });

  // A device that is trusted already is asked about the names alone.
  testWidgets('a trusted sender is not asked about trust again', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<(bool, bool, ConflictMode)> answer = showAcceptDialog(
      senderName: 'Peer',
      fileCount: 2,
      totalBytes: 2,
      occupied: 1,
      askTrust: false,
    );
    await tester.pump();

    expect(find.text('Always trust this device'), findsNothing);
    expect(find.text('Such files are already here: 1'), findsOneWidget);
    await tester.tap(find.text('Replace'));
    await tester.pump();
    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();

    expect(await answer, (true, false, ConflictMode.replace));
  });
}
