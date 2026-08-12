import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  const String pubspec = 'name: test_app\nversion: 0.2.260811+72\n';
  const String globals =
      "const String progVersion = '0.2.260811';\n"
      'const int buildNumber = 72;\n';

  Future<Directory> fixture() async {
    final Directory root = await Directory.systemTemp.createTemp(
      'easysend-release-transaction-',
    );
    await File(
      '10-MakeRelease.sh',
    ).copy(p.join(root.path, '10-MakeRelease.sh'));
    await File(p.join(root.path, 'pubspec.yaml')).writeAsString(pubspec);
    await Directory(p.join(root.path, 'lib')).create();
    await File(p.join(root.path, 'lib', 'globals.dart')).writeAsString(globals);
    await Directory(
      p.join(root.path, 'android', 'app', 'src', 'main'),
    ).create(recursive: true);
    await File(
      p.join(root.path, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'),
    ).writeAsString('<application android:label="TestApp"/>\n');

    final Directory bin = await Directory(
      p.join(root.path, 'fake-bin'),
    ).create();
    final Map<String, String> tools = {
      'flutter': r'''#!/usr/bin/env bash
set -e
if [ "$1" = "build" ]; then
  out="build/app/outputs/flutter-apk"
  mkdir -p "$out"
  for name in app-release.apk app-arm64-v8a-release.apk app-x86_64-release.apk; do
    if [ "$RELEASE_FAKE_MISSING" != "$name" ]; then
      if [ "$RELEASE_FAKE_EMPTY" = "$name" ]; then
        : > "$out/$name"
      else
        printf 'apk:%s\n' "$name" > "$out/$name"
      fi
    fi
  done
fi
''',
      'dart': '#!/usr/bin/env bash\nexit 0\n',
      'git': r'''#!/usr/bin/env bash
case "$1" in
  rev-parse) [ -n "$RELEASE_FAKE_GIT_MODE" ] ;;
  status)
    printf ' M lib/globals.dart\n M pubspec.yaml\n'
    [ "$RELEASE_FAKE_GIT_MODE" != "dirty" ] || printf ' M user-note.txt\n'
    ;;
  branch)
    [ "$RELEASE_FAKE_GIT_MODE" != "pushed" ] || printf 'origin/main\n'
    ;;
  add|commit) printf '%s\n' "$1" >> "$RELEASE_FAKE_GIT_LOG" ;;
  log) printf 'abc release' ;;
esac
''',
      'sleep': '#!/usr/bin/env bash\nexit 0\n',
      'mv': r'''#!/usr/bin/env bash
if [ "$RELEASE_FAKE_RENAME_FAIL" = "true" ]; then
  case "$2" in
    build/app/outputs/flutter-apk/TestApp-*-x86_64.apk) exit 9 ;;
  esac
fi
/bin/mv "$@"
''',
      'ls': r'''#!/usr/bin/env bash
if [ "$RELEASE_FAKE_LIST_FAIL" = "true" ] && [ "$1" = "-1" ]; then
  exit 8
fi
/bin/ls "$@"
''',
    };
    for (final MapEntry<String, String> tool in tools.entries) {
      final File file = File(p.join(bin.path, tool.key));
      await file.writeAsString(tool.value);
      final ProcessResult chmod = await Process.run('chmod', ['+x', file.path]);
      expect(chmod.exitCode, 0);
    }
    await Directory(
      p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk'),
    ).create(recursive: true);
    await File(
      p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk', 'old.apk'),
    ).writeAsString('keep me');
    return root;
  }

  Future<ProcessResult> run(
    Directory root, {
    String? missing,
    String? empty,
    bool renameFails = false,
    bool listingFails = false,
    String? gitMode,
  }) => Process.run(
    'bash',
    ['10-MakeRelease.sh'],
    workingDirectory: root.path,
    environment: {
      ...Platform.environment,
      'PATH':
          '${p.join(root.path, 'fake-bin')}:${Platform.environment['PATH']}',
      'RELEASE_FAKE_MISSING': ?missing,
      'RELEASE_FAKE_EMPTY': ?empty,
      if (renameFails) 'RELEASE_FAKE_RENAME_FAIL': 'true',
      if (listingFails) 'RELEASE_FAKE_LIST_FAIL': 'true',
      'RELEASE_FAKE_GIT_MODE': ?gitMode,
      'RELEASE_FAKE_GIT_LOG': p.join(root.path, 'git.log'),
    },
  );

  Future<void> expectRollback(Directory root) async {
    expect(
      await File(p.join(root.path, 'pubspec.yaml')).readAsString(),
      pubspec,
    );
    expect(
      await File(p.join(root.path, 'lib', 'globals.dart')).readAsString(),
      globals,
    );
    expect(
      await File(
        p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk', 'old.apk'),
      ).readAsString(),
      'keep me',
    );
    final List<String> finals =
        Directory(
          p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk'),
        ).listSync().map((entry) => p.basename(entry.path)).where((name) {
          return name.startsWith('TestApp') && name.endsWith('.apk');
        }).toList();
    expect(finals, isEmpty);
  }

  for (final String missing in [
    'app-release.apk',
    'app-arm64-v8a-release.apk',
    'app-x86_64-release.apk',
  ]) {
    test('missing $missing rolls the release transaction back', () async {
      final Directory root = await fixture();
      addTearDown(() => root.delete(recursive: true));
      final ProcessResult result = await run(root, missing: missing);
      expect(result.exitCode, isNot(0));
      await expectRollback(root);
    });
  }

  test(
    'a rename failure restores versions, sources and old artifacts',
    () async {
      final Directory root = await fixture();
      addTearDown(() => root.delete(recursive: true));
      final ProcessResult result = await run(root, renameFails: true);
      expect(result.exitCode, isNot(0));
      await expectRollback(root);
      for (final String source in [
        'app-release.apk',
        'app-arm64-v8a-release.apk',
        'app-x86_64-release.apk',
      ]) {
        expect(
          await File(
            p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk', source),
          ).exists(),
          isTrue,
        );
      }
    },
  );

  test('a listing failure is still before the commit point', () async {
    final Directory root = await fixture();
    addTearDown(() => root.delete(recursive: true));
    final ProcessResult result = await run(root, listingFails: true);
    expect(result.exitCode, isNot(0));
    await expectRollback(root);
  });

  test('an empty output fails artifact verification and rolls back', () async {
    final Directory root = await fixture();
    addTearDown(() => root.delete(recursive: true));
    final ProcessResult result = await run(root, empty: 'app-release.apk');
    expect(result.exitCode, isNot(0));
    await expectRollback(root);
  });

  test('an existing destination is never overwritten', () async {
    final Directory root = await fixture();
    addTearDown(() => root.delete(recursive: true));
    final DateTime now = DateTime.now();
    final String date =
        '${(now.year % 100).toString().padLeft(2, '0')}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    final File existing = File(
      p.join(
        root.path,
        'build',
        'app',
        'outputs',
        'flutter-apk',
        'TestApp-0.2.$date-73-universal.apk',
      ),
    );
    await existing.writeAsString('old exact artifact');

    final ProcessResult result = await run(root);
    expect(result.exitCode, isNot(0));
    expect(await existing.readAsString(), 'old exact artifact');
    expect(
      await File(p.join(root.path, 'pubspec.yaml')).readAsString(),
      pubspec,
    );
  });

  for (final String mode in ['dirty', 'pushed']) {
    test('$mode git state leaves a completed version bump unamended', () async {
      final Directory root = await fixture();
      addTearDown(() => root.delete(recursive: true));
      if (mode == 'dirty') {
        await File(p.join(root.path, 'user-note.txt')).writeAsString('mine');
      }

      final ProcessResult result = await run(root, gitMode: mode);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        await File(p.join(root.path, 'pubspec.yaml')).readAsString(),
        isNot(pubspec),
      );
      expect(await File(p.join(root.path, 'git.log')).exists(), isFalse);
      if (mode == 'dirty') {
        expect(
          await File(p.join(root.path, 'user-note.txt')).readAsString(),
          'mine',
        );
      }
    });
  }

  test('a complete artifact set commits synchronized versions', () async {
    final Directory root = await fixture();
    addTearDown(() => root.delete(recursive: true));
    final ProcessResult result = await run(root);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    final String updatedPub = await File(
      p.join(root.path, 'pubspec.yaml'),
    ).readAsString();
    final RegExpMatch version = RegExp(
      r'version: (0\.2\.\d{6})\+73',
    ).firstMatch(updatedPub)!;
    final String updatedGlobals = await File(
      p.join(root.path, 'lib', 'globals.dart'),
    ).readAsString();
    expect(updatedGlobals, contains("progVersion = '${version.group(1)}'"));
    expect(updatedGlobals, contains('buildNumber = 73'));

    final List<FileSystemEntity> finals =
        Directory(
          p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk'),
        ).listSync().where((entry) {
          final String name = p.basename(entry.path);
          return name.startsWith('TestApp') && name.endsWith('.apk');
        }).toList();
    expect(finals, hasLength(3));
    expect(
      await File(
        p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk', 'old.apk'),
      ).readAsString(),
      'keep me',
    );
  });
}
