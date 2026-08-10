import 'package:easysend/file_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

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
  });
}
