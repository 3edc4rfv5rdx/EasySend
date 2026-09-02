import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// The rule the share dialog exists to keep: the routes answer while it is open
// and stop the moment it is not, and what they answer is whatever the choice
// inside it says.
//
// The window is fed a ready offer here, never asked to gather one: gathering is
// a stat of the package and a walk of the network interfaces, and a widget
// test's clock is a fake one under which no such future ever finishes. What
// gathering does is checked in web_share_test.dart, where the clock is real.
void main() {
  const String url = 'http://192.168.88.7:15353';
  final String apkName = 'EasySend-$progVersion+$buildNumber.apk';

  Future<void> pumpHost(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: navigatorKey, home: const SizedBox.shrink()),
  );

  WebShareOffer offer({
    int fileCount = 1,
    bool withProgram = false,
    bool addressed = true,
  }) => WebShareOffer(
    files: [
      for (int i = 0; i < fileCount; i++)
        (name: 'file$i.txt', path: '/nowhere/file$i.txt', size: 3),
    ],
    program: withProgram
        ? (name: apkName, path: '/nowhere/base.apk', size: 4)
        : null,
    targets: addressed
        ? <WebShareTarget>[(url: url, code: qrFor(url))]
        : const <WebShareTarget>[],
  );

  // pump() rather than pumpAndSettle(): the address is a SelectableText, whose
  // caret keeps a periodic timer alive, and settling waits for a frame that
  // never comes. The route is torn down in one frame anyway — this dialog has
  // no animation.
  Future<void> close(WidgetTester tester, Future<void> dialog) async {
    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump();
    await dialog;
  }

  setUp(() => xdef['Program language'] = 'en');
  tearDown(() => receiveServer.webOffer = null);

  testWidgets('the offer stands exactly as long as the dialog does', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    expect(receiveServer.webOffer, isNull);

    final Future<void> dialog = showWebShareOffer(offer(fileCount: 2));
    await tester.pump();

    expect(find.text('Share by link'), findsOneWidget);
    expect(find.text('Sharing:'), findsOneWidget);
    expect(find.text('Selected files: 2'), findsOneWidget);
    // The address is readable and the same address is on screen as a matrix.
    expect(find.text(url), findsOneWidget);
    expect(find.byType(QrView), findsOneWidget);
    expect(
      receiveServer.webOffer?.map((WebShareEntry e) => e.name),
      containsAll(<String>['file0.txt', 'file1.txt']),
    );

    await close(tester, dialog);
    expect(receiveServer.webOffer, isNull);
  });

  // The whole point of the second choice: the phone handing the program over is
  // not always the architecture that needs it, and a v7a build picked with File
  // goes out the same way.
  testWidgets('the choice decides what the routes answer with', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<void> dialog = showWebShareOffer(offer(withProgram: true));
    await tester.pump();

    // Files were picked, so files are what is offered until told otherwise.
    expect(find.text('Selected files: 1'), findsOneWidget);
    expect(find.text(apkName), findsOneWidget);
    expect(receiveServer.webOffer?.single.name, 'file0.txt');

    await tester.tap(find.text(apkName));
    await tester.pump();
    expect(receiveServer.webOffer?.single.name, apkName);

    await tester.tap(find.text('Selected files: 1'));
    await tester.pump();
    expect(receiveServer.webOffer?.single.name, 'file0.txt');

    await close(tester, dialog);
    expect(receiveServer.webOffer, isNull);
  });

  // With one thing to give there is nothing to choose, and a group of one radio
  // button only asks a question that cannot be answered differently.
  testWidgets('with nothing picked the program is offered without a choice', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<void> dialog = showWebShareOffer(
      offer(fileCount: 0, withProgram: true),
    );
    await tester.pump();

    expect(find.text(apkName), findsOneWidget);
    expect(find.byType(RadioListTile<WebShareKind>), findsNothing);
    expect(receiveServer.webOffer?.single.name, apkName);

    await close(tester, dialog);
    expect(receiveServer.webOffer, isNull);
  });

  testWidgets('the ZIP latch is answered only when it is on', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    Future<void> dialog = showWebShareOffer(offer());
    await tester.pump();
    expect(find.text('ZIP does not apply here'), findsNothing);
    await close(tester, dialog);

    dialog = showWebShareOffer(offer(), zipWanted: true);
    await tester.pump();
    expect(find.text('ZIP does not apply here'), findsOneWidget);
    await close(tester, dialog);
  });

  // The two ways there is no dialog to show. Both answers go on screen, which
  // is why they are checked here rather than beside the rest of prepare: they
  // take no listener and no platform call to reach.
  testWidgets('nothing to hand over opens no dialog and no route', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<WebShareOffer?> prepared = prepareWebShare(
      const <FileItem>[],
      apkPathOf: () async => null,
    );
    await tester.pump();

    expect(find.text('Nothing selected'), findsOneWidget);
    expect(find.text('Share by link'), findsNothing);
    expect(await prepared, isNull);
    expect(receiveServer.webOffer, isNull);

    await tester.tap(find.text('Ok'));
    await tester.pump();
  });

  // A listener that is not up has no address to give, and saying so beats a
  // dialog showing an address that answers nothing.
  testWidgets('a receiver that is not listening says so instead', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    expect(receiveServer.boundPort, isNull);
    final Future<WebShareOffer?> prepared = prepareWebShare([
      FileItem(
        id: 'one',
        relativePath: 'one.txt',
        sourcePath: '/nowhere/one.txt',
        size: 1,
      ),
    ], apkPathOf: () async => null);
    await tester.pump();

    expect(find.text('Setup did not finish, receiving may be off'), findsOne);
    expect(find.text('Share by link'), findsNothing);
    expect(await prepared, isNull);
    expect(receiveServer.webOffer, isNull);

    await tester.tap(find.text('Ok'));
    await tester.pump();
  });

  // A device on no network has nothing to show, and an empty space where the
  // address should be would read as a dialog that failed to draw.
  testWidgets('with no address of our own the dialog says so', (
    WidgetTester tester,
  ) async {
    await pumpHost(tester);
    final Future<void> dialog = showWebShareOffer(offer(addressed: false));
    await tester.pump();

    expect(find.text('No address on this network'), findsOneWidget);
    expect(find.byType(QrView), findsNothing);

    await close(tester, dialog);
  });
}
