import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('maps system locale to a supported initial language', () {
    langNames = {'en': 'English', 'ua': 'Українська', 'ru': 'Русский'};
    expect(initialLanguageForLocale('uk_UA'), 'ua');
    expect(initialLanguageForLocale('ru-RU'), 'ru');
    expect(initialLanguageForLocale('de_DE'), 'en');
  });

  test('window bounds round-trip and reject unusable sizes', () {
    final encoded = encodeWindowBounds(x: 10, y: 20, width: 420, height: 800);
    final bounds = parseWindowBounds(encoded)!;
    expect(
      (bounds.x, bounds.y, bounds.width, bounds.height),
      (10, 20, 420, 800),
    );
    expect(parseWindowBounds('0,0,10,10'), isNull);
    expect(parseWindowBounds('bad'), isNull);
  });

  test(
    'external fallback id is validated and never overwrites content',
    () async {
      final root = await Directory.systemTemp.createTemp('easysend-id-');
      final file = File(p.join(root.path, '.easysend-id'));
      const first = '123e4567-e89b-42d3-a456-426614174000';
      const second = '223e4567-e89b-42d3-a456-426614174000';
      expect(await writeExternalDeviceIdIfAbsent(file, first), isTrue);
      expect(await readExternalDeviceId(file), first);
      expect(await writeExternalDeviceIdIfAbsent(file, second), isFalse);
      expect(await readExternalDeviceId(file), first);
      await file.writeAsString('user content');
      expect(await writeExternalDeviceIdIfAbsent(file, first), isFalse);
      expect(await file.readAsString(), 'user content');
      await root.delete(recursive: true);
    },
  );
}
