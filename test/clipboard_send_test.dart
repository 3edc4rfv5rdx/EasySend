import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:flutter_test/flutter_test.dart';

// The clipboard travels as a plain file. What has to hold: the name says what
// it is and carries the moment it was taken; the receiver recognises that name
// only at the top of a transfer; the file written out is the text that was
// copied; and a finished receive picks the one file the clipboard is filled
// from.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the name carries the moment the text was taken', () {
    expect(
      clipboardFileName(DateTime(2026, 8, 31, 14, 30, 7)),
      'x.20260831-143007.txt',
    );
  });

  test('a clipboard is known by its whole path and nothing less', () {
    expect(
      clipboardSendPath(clipboardFileName(DateTime(2026, 8, 31, 14, 30, 7))),
      'clipboard/x.20260831-143007.txt',
    );
    expect(isClipboardFile('clipboard/x.20260831-143007.txt'), isTrue);
    // The name without its folder is somebody's text file.
    expect(isClipboardFile('x.20260831-143007.txt'), isFalse);
    expect(isClipboardFile('clipboard/notes.txt'), isFalse);
    expect(isClipboardFile('clipboard/x.2026-08-31.txt'), isFalse);
    // Deeper inside a sent folder it belongs to that folder.
    expect(isClipboardFile('docs/clipboard/x.20260831-143007.txt'), isFalse);
  });

  test('the file holds exactly the text that was copied', () async {
    final Directory sandbox = await Directory.systemTemp.createTemp(
      'easysend-clip-',
    );
    addTearDown(() async => sandbox.delete(recursive: true));
    final String? path = await writeClipboardFile(
      'ссылка\nвторая строка',
      DateTime(2026, 8, 31, 14, 30, 7),
      rootOf: () async => '${sandbox.path}/clip',
    );
    expect(path, isNotNull);
    expect(path!.endsWith('/x.20260831-143007.txt'), isTrue);
    expect(await File(path).readAsString(), 'ссылка\nвторая строка');
  });

  test('nowhere to write it is said with null and not with a throw', () async {
    expect(
      await writeClipboardFile('text', DateTime(2026, 8, 31), rootOf: () async => null),
      isNull,
    );
  });

  test('the last clipboard file that arrived is the one copied', () {
    FileItem item(String name, {bool done = true, bool landed = true}) =>
        FileItem(
          id: name,
          relativePath: name,
          size: 1,
          destinationPath: landed ? '/receive/$name' : null,
        )..done = done;

    expect(clipboardArrival([item('notes.txt')]), isNull);
    // Sent but never received: nothing goes into the clipboard for it.
    expect(
      clipboardArrival([item('clipboard/x.20260831-143007.txt', done: false)]),
      isNull,
    );
    // Done, but nothing of it was written here: the name was already taken and
    // the answer was to keep what is here. Its planned destination is the
    // user's own file, and pasting that would be this transfer overwriting a
    // clipboard with something it never delivered.
    expect(
      clipboardArrival([
        item('clipboard/x.20260831-143007.txt', landed: false),
      ]),
      isNull,
    );
    // And in a batch, the last one that actually landed is the one that wins,
    // not the last one that merely finished.
    expect(
      clipboardArrival([
        item('clipboard/x.20260831-143007.txt'),
        item('clipboard/x.20260831-150000.txt', landed: false),
      ])!.relativePath,
      'clipboard/x.20260831-143007.txt',
    );
    final List<FileItem> batch = [
      item('clipboard/x.20260831-143007.txt'),
      item('photo.jpg'),
      item('clipboard/x.20260831-150000.txt'),
    ];
    expect(clipboardArrival(batch)!.relativePath, 'clipboard/x.20260831-150000.txt');
  });

  // Two taps fit inside one second, and the stamp counts in seconds. The second
  // one must not land on the file the selection is already pointing at.
  test('a second copy in the same second gets a name of its own', () async {
    final Directory sandbox = await Directory.systemTemp.createTemp(
      'easysend-clip-',
    );
    addTearDown(() async => sandbox.delete(recursive: true));
    Future<String?> write(String text) => writeClipboardFile(
      text,
      DateTime(2026, 8, 31, 14, 30, 7),
      rootOf: () async => '${sandbox.path}/clip',
    );

    final String? first = await write('first');
    final String? second = await write('second');

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(second, isNot(first));
    expect(first!.endsWith('x.20260831-143007.txt'), isTrue);
    expect(second!.endsWith('x.20260831-143008.txt'), isTrue);
    // And the first one still holds what it was written with.
    expect(await File(first).readAsString(), 'first');
    expect(await File(second).readAsString(), 'second');
  });

  group('what reaches the clipboard', () {
    late Directory sandbox;
    late List<String?> pasted;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-clip-');
      pasted = [];
      // The real plugin is not here, and a throw would let every one of these
      // pass for the wrong reason: without a handler the channel fails and the
      // refusals below would look exactly like a successful refusal.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall call,
          ) async {
            if (call.method == 'Clipboard.setData') {
              pasted.add(
                (call.arguments as Map)['text'] as String?,
              );
            }
            return null;
          });
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
      await sandbox.delete(recursive: true);
    });

    FileItem arrival(File file) =>
        FileItem(
            id: file.path,
            relativePath: 'clipboard/x.20260831-143007.txt',
            size: file.lengthSync(),
            destinationPath: file.path,
          )
          ..done = true;

    test('the text that arrived is what gets pasted', () async {
      final File arrived = File('${sandbox.path}/text.txt');
      await arrived.writeAsString('ссылка\nвторая строка');

      expect(await copyArrivedClipboard(arrival(arrived)), isTrue);

      expect(pasted, ['ссылка\nвторая строка']);
    });

    test('an empty file is refused instead of wiping the clipboard', () async {
      final File empty = File('${sandbox.path}/empty.txt');
      await empty.writeAsString('');

      expect(await copyArrivedClipboard(arrival(empty)), isFalse);

      expect(pasted, isEmpty);
      // Still where it landed: it is a file the user was sent.
      expect(await empty.exists(), isTrue);
    });

    test('an oversized file is never read into memory', () async {
      final File huge = File('${sandbox.path}/huge.txt');
      await huge.writeAsBytes(List<int>.filled(maxClipboardBytes + 1, 65));

      expect(await copyArrivedClipboard(arrival(huge)), isFalse);

      expect(pasted, isEmpty);
      expect(await huge.exists(), isTrue);
    });
  });

  test('an arrival with nowhere on disk is refused', () async {
    expect(
      await copyArrivedClipboard(
        FileItem(
          id: 'no-path',
          relativePath: 'clipboard/x.20260831-143007.txt',
          size: 1,
        )..done = true,
      ),
      isFalse,
    );
  });

  group('the same text twice', () {
    late Directory sandbox;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-clip-');
    });
    tearDown(() async => sandbox.delete(recursive: true));

    Future<FileItem> picked(String text, {String? name}) async {
      final File file = File(
        '${sandbox.path}/${name ?? 'x.20260831-143007.txt'}',
      );
      await file.writeAsString(text);
      return FileItem(
        id: file.path,
        relativePath: 'clipboard/${p.basename(file.path)}',
        size: await file.length(),
        sourcePath: file.path,
      );
    }

    test('a second press on the same clipboard adds nothing', () async {
      final FileItem first = await picked('ссылка');
      expect(await clipboardAlreadyPicked('ссылка', [first]), isTrue);
    });

    test('other text is a clipboard of its own', () async {
      final FileItem first = await picked('ссылка');
      expect(await clipboardAlreadyPicked('другая ссылка', [first]), isFalse);
      // Same length, different text: the size check must not settle it alone.
      expect(await clipboardAlreadyPicked('ссылкА', [first]), isFalse);
    });

    test('an ordinary file of the same text is not a clipboard', () async {
      final File plain = File('${sandbox.path}/notes.txt');
      await plain.writeAsString('ссылка');
      final FileItem item = FileItem(
        id: plain.path,
        relativePath: 'notes.txt',
        size: await plain.length(),
        sourcePath: plain.path,
      );
      expect(await clipboardAlreadyPicked('ссылка', [item]), isFalse);
    });

    test('a picked clipboard that is gone does not block the new one', () async {
      final FileItem first = await picked('ссылка');
      await File(first.sourcePath!).delete();
      expect(await clipboardAlreadyPicked('ссылка', [first]), isFalse);
    });
  });

  // Asked for text, Android coerces whatever is in the clipboard: a copied
  // picture comes back as its own URI rather than as nothing at all.
  test('a coerced content URI is not text', () {
    expect(isNonTextClipboard('content://media/external/images/media/91'), isTrue);
    // Trailing whitespace is the clipboard's, not the user's.
    expect(isNonTextClipboard('  content://media/external/images/media/91\n'), isTrue);
  });

  test('a link the user copied is text and is sent', () {
    expect(isNonTextClipboard('https://example.org/a?b=1'), isFalse);
    expect(isNonTextClipboard('file:///home/e/notes.txt'), isFalse);
    // A sentence that merely mentions one.
    expect(isNonTextClipboard('content://media/91 and a word'), isFalse);
    expect(isNonTextClipboard('content://media/91\nsecond line'), isFalse);
    expect(isNonTextClipboard('обычный текст'), isFalse);
  });
}
