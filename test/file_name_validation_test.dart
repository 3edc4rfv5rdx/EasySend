import 'dart:convert';
import 'dart:io';

import 'package:easysend/file_helpers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  group('sanitizeRelPath', () {
    test('accepts portable nested and unicode names', () {
      expect(sanitizeRelPath('folder/підпис.txt'), 'folder/підпис.txt');
    });

    test('rejects traversal and absolute paths', () {
      for (final String value in ['../x', '/tmp/x', r'C:\tmp\x']) {
        expect(sanitizeRelPath(value), isNull, reason: value);
      }
    });

    test('rejects every Windows-forbidden character and controls', () {
      for (final String char in ['<', '>', '"', ':', '|', '?', '*', '\u0001']) {
        expect(sanitizeRelPath('bad${char}name.txt'), isNull, reason: char);
      }
    });

    test('rejects reserved names regardless of case or extension', () {
      for (final String value in ['CON', 'con.txt', 'LpT9.log', 'AUX.data']) {
        expect(sanitizeRelPath(value), isNull, reason: value);
      }
    });

    test('rejects trailing dot or space and excessive lengths', () {
      expect(sanitizeRelPath('name.'), isNull);
      expect(sanitizeRelPath('name '), isNull);
      expect(sanitizeRelPath('${'a' * 256}.txt'), isNull);
      expect(sanitizeRelPath('${List.filled(65, 'd').join('/')}/x'), isNull);
    });

    test('counts a name the way both filesystems do', () {
      // NTFS counts 255 UTF-16 code units, ext4 counts 255 bytes of UTF-8, and
      // a name that fails either one is a name one of the two ends cannot
      // create. A Cyrillic letter costs two bytes, so its limit comes first.
      final String ascii = 'a' * maxPathComponentChars;
      expect(sanitizeRelPath(ascii), ascii);
      expect(sanitizeRelPath('a' * (maxPathComponentChars + 1)), isNull);

      final String cyrillic = 'я' * (maxPathComponentBytes ~/ 2);
      expect(cyrillic.length, lessThan(maxPathComponentChars));
      expect(sanitizeRelPath(cyrillic), cyrillic);
      expect(sanitizeRelPath('я' * (maxPathComponentBytes ~/ 2 + 1)), isNull);

      // Three bytes each, and four for a surrogate pair.
      final String cjk = '漢' * (maxPathComponentBytes ~/ 3);
      expect(sanitizeRelPath(cjk), cjk);
      expect(sanitizeRelPath('漢' * (maxPathComponentBytes ~/ 3 + 1)), isNull);

      final String emoji = '😀' * (maxPathComponentBytes ~/ 4);
      expect(emoji.length, greaterThan(maxPathComponentBytes ~/ 4));
      expect(sanitizeRelPath(emoji), emoji);
      expect(sanitizeRelPath('😀' * (maxPathComponentBytes ~/ 4 + 1)), isNull);

      // A base letter plus a combining mark: two UTF-16 units, three bytes.
      const String acute = 'é';
      expect(utf8.encode(acute).length, 3, reason: 'e + combining acute');
      expect(sanitizeRelPath(acute * 85), acute * 85); // 255 bytes
      expect(sanitizeRelPath(acute * 86), isNull); // 258

      // A long name in a deep folder is still one name per component.
      expect(
        sanitizeRelPath('folder/$cyrillic/файл.txt'),
        'folder/$cyrillic/файл.txt',
      );
    });

    test('the whole path limit still holds above the component limit', () {
      final String segment = 'a' * maxPathComponentChars;
      final String deep = List.filled(17, segment).join('/');
      expect(utf8.encode(deep).length, greaterThan(maxPathUtf8Bytes));
      expect(sanitizeRelPath(deep), isNull);
      expect(isPathTooLong(deep), isTrue);
    });
  });

  group('names accepted here are creatable here', () {
    late Directory root;
    setUp(
      () async =>
          root = await Directory.systemTemp.createTemp('easysend-names-'),
    );
    tearDown(() => root.delete(recursive: true));

    test('every boundary name the sanitizer accepts can be written', () async {
      for (final String name in [
        'a' * maxPathComponentChars,
        'я' * (maxPathComponentBytes ~/ 2),
        '漢' * (maxPathComponentBytes ~/ 3),
        '😀' * (maxPathComponentBytes ~/ 4),
        'é' * 85,
      ]) {
        expect(sanitizeRelPath(name), name, reason: '${name.length} units');
        final File f = File(p.join(root.path, name));
        await f.writeAsString('ok');
        expect(await f.readAsString(), 'ok');
      }
    });

    test('a collision suffix does not outgrow the limit', () async {
      final String name = '${'я' * 125}.txt'; // 254 bytes, ' (1)' would burst
      expect(sanitizeRelPath(name), name);
      final String taken = p.join(root.path, name);
      await File(taken).writeAsString('first');

      final String? next = await uniquePath(taken);
      expect(next, isNotNull);
      expect(isComponentTooLong(p.basename(next!)), isFalse);
      expect(p.basename(next), endsWith(' (1).txt'));
      // Trimmed by whole characters, never through the middle of one.
      expect(p.basename(next).contains('�'), isFalse);
      await File(next).writeAsString('second');
      expect(await File(next).readAsString(), 'second');
    });
  });
}
