import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late File settings;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('easysend-settings-');
    xvConfigDir = root.path;
    xdef = defaultSettings();
    langNames = {'en': 'English', 'ua': 'Українська'};
    loadedThemes = {themeLight: {}, themeDark: {}};
    xvDevices = [];
    settings = File(p.join(root.path, settFile));
  });

  tearDown(() => root.delete(recursive: true));

  test('keeps valid fields and defaults wrong JSON types and ranges', () async {
    await settings.writeAsString(
      json.encode({
        'settings': {
          'Device name': 5,
          'Port': '99999',
          'Program language': 'ua',
          'Ask before exit': 'false',
        },
      }),
    );
    await loadSettings();
    expect(xdef['Device name'], '');
    expect(xdef['Port'], '$defaultPort');
    expect(xdef['Program language'], 'ua');
    expect(xdef['Ask before exit'], 'false');
  });

  test(
    'drops malformed and duplicate devices without losing valid one',
    () async {
      final valid = {
        'id': 'peer',
        'name': 'Peer',
        'platform': 'linux',
        'address': '192.168.1.2',
        'port': 15353,
        'trusted': true,
        'manual': false,
      };
      await settings.writeAsString(
        json.encode({
          'settings': {},
          'devices': [
            valid,
            valid,
            {'id': 3},
            'bad',
          ],
        }),
      );
      await loadSettings();
      expect(xvDevices, hasLength(1));
      expect(xvDevices.single.id, 'peer');
    },
  );

  test('concurrent saves leave one complete parseable document', () async {
    await Future.wait(List.generate(8, (_) => saveSettings()));
    final decoded = json.decode(await settings.readAsString());
    expect(decoded, isA<Map<String, dynamic>>());
    expect(
      root.listSync().where((entry) => entry.path.endsWith('.tmp')),
      isEmpty,
    );
  });

  test('damaged settings get collision-free backups', () async {
    await File('${settings.path}.existing.bad').writeAsString('older');
    await settings.writeAsString('{broken');
    await loadSettings();
    expect(await File('${settings.path}.existing.bad').readAsString(), 'older');
    expect(
      root.listSync().where((entry) => entry.path.endsWith('.bad')).length,
      2,
    );
  });
}
