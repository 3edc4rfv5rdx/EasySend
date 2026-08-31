import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

// The clipboard travels as a plain file. What has to hold: the name says what
// it is and carries the moment it was taken; the receiver recognises that name
// only at the top of a transfer; the file written out is the text that was
// copied; and a finished receive picks the one file the clipboard is filled
// from.
void main() {
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
    FileItem item(String name, {bool done = true}) => FileItem(
      id: name,
      relativePath: name,
      size: 1,
    )..done = done;

    expect(clipboardArrival([item('notes.txt')]), isNull);
    // Sent but never received: nothing goes into the clipboard for it.
    expect(
      clipboardArrival([item('clipboard/x.20260831-143007.txt', done: false)]),
      isNull,
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
}
