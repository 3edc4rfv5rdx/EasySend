import 'package:easysend/globals.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
  );

  FileItem item(String relativePath) =>
      FileItem(id: relativePath, relativePath: relativePath, size: 1);

  setUp(() => xdef['Program language'] = 'en');

  testWidgets('every refused name is shown whole, with its reason', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final String long = 'holiday/${'a' * (maxPathComponentChars + 1)}.jpg';
    final Future<bool> answer = showRefusedNamesDialog([
      (file: item(r'report\draft.pdf'), problem: PickProblem.backslash),
      (file: item('CON'), problem: PickProblem.reserved),
      (file: item(long), problem: PickProblem.tooLong),
    ]);
    await tester.pump();

    expect(find.text('Invalid names'), findsOneWidget);
    expect(find.text('These files cannot be sent:'), findsOneWidget);
    // Whole, not shortened: the end is where two files in a folder differ.
    expect(find.text(r'report\draft.pdf'), findsOneWidget);
    expect(find.text(long), findsOneWidget);
    expect(find.text('a backslash in the name'), findsOneWidget);
    expect(find.text('a name Windows reserves'), findsOneWidget);
    expect(find.text('the name is too long'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('Fix is offered only when something can be repaired', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<bool> answer = showRefusedNamesDialog([
      (file: item('CON'), problem: PickProblem.reserved),
    ]);
    await tester.pump();

    expect(find.text('Fix'), findsNothing);
    expect(find.text('replace the backslash with a dash'), findsNothing);
    // Nothing to decide, so the one button only closes it.
    expect(find.text('Ok'), findsOneWidget);

    await tester.tap(find.text('Ok'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('the tick decides what Fix does', (WidgetTester tester) async {
    await pumpHost(tester);
    final Future<bool> answer = showRefusedNamesDialog([
      (file: item(r'a\b.txt'), problem: PickProblem.backslash),
    ]);
    await tester.pump();
    expect(find.text('Fix'), findsOneWidget);

    // On by default; turning it off makes Fix change nothing.
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fix'));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);
  });

  testWidgets('Fix with the tick on asks for the repair', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<bool> answer = showRefusedNamesDialog([
      (file: item(r'a\b.txt'), problem: PickProblem.backslash),
    ]);
    await tester.pump();

    await tester.tap(find.text('Fix'));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });
}
