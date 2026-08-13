import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Every user-visible string reaches the screen through lw(), and a key missing
// from the locale file is shown as '(( English text ))'. That marker is the
// honest answer for a key composed at runtime; this test is what keeps it from
// standing in for a key somebody simply forgot to add along with the feature.
void main() {
  late Map<String, dynamic> locales;
  late List<String> languages;

  setUpAll(() {
    locales =
        (json.decode(File('assets/locales.json').readAsStringSync()) as Map)
            .cast<String, dynamic>();
    languages = (locales['_language_name'] as Map).keys
        .cast<String>()
        .where((String code) => code != 'en')
        .toList();
  });

  test('the locale file declares the languages the app ships with', () {
    expect(languages, containsAll(<String>['ru', 'ua']));
  });

  test('every key carries every declared language', () {
    final List<String> gaps = [];
    for (final MapEntry<String, dynamic> entry in locales.entries) {
      if (entry.key == '_language_name') continue;
      final Map<String, dynamic> translations = (entry.value as Map)
          .cast<String, dynamic>();
      for (final String language in languages) {
        final Object? text = translations[language];
        if (text is! String || text.trim().isEmpty) {
          gaps.add('${entry.key} [$language]');
        }
      }
    }
    expect(gaps, isEmpty);
  });

  test('every static key used in code is in the locale file', () {
    // lw('...') on screen, and TransferSession.log('...'), whose message goes
    // through lw() when the log is rendered or copied.
    final RegExp call = RegExp(r"(?:\blw|\.log)\(\s*'((?:[^'\\\n]|\\.)*)'");
    final List<String> missing = [];
    for (final FileSystemEntity entity in Directory(
      'lib',
    ).listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final String source = entity.readAsStringSync();
      for (final RegExpMatch match in call.allMatches(source)) {
        final String key = match.group(1)!;
        // Composed at runtime, so there is no static key to look for.
        if (key.isEmpty || key.contains(r'$')) continue;
        if (!locales.containsKey(key)) missing.add('${entity.path}: $key');
      }
    }
    expect(missing, isEmpty);
  });
}
