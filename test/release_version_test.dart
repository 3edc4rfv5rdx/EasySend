import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<ProcessResult> compute(String version, String date) => Process.run(
    'bash',
    ['10-MakeRelease.sh', '--compute', version, date],
    workingDirectory: Directory.current.path,
  );

  test(
    'preserves the authoritative major/minor line and increments build',
    () async {
      final result = await compute('0.2.260810+64', '260811');
      expect(result.exitCode, 0);
      expect((result.stdout as String).trim(), '0.2.260811+65');
    },
  );

  test('supports an intentional major/minor change', () async {
    final result = await compute('3.7.260810+9', '260811');
    expect(result.exitCode, 0);
    expect((result.stdout as String).trim(), '3.7.260811+10');
  });

  // The line is the one part of a version decided by hand, and the changelog
  // decides it: a release carrying a feature moves the minor (README, Versions).
  test('an asked-for line change moves the minor and nothing else', () async {
    final result = await Process.run('bash', [
      '10-MakeRelease.sh',
      '--compute',
      '0.2.260810+64',
      '260811',
      'minor',
    ], workingDirectory: Directory.current.path);

    expect(result.exitCode, 0);
    expect((result.stdout as String).trim(), '0.3.260811+65');
  });

  group('the changelog says whether a feature is waiting', () {
    Future<int> hasFeature(String changelog) async {
      final Directory temp = await Directory.systemTemp.createTemp('easysend-cl-');
      addTearDown(() => temp.delete(recursive: true));
      final File file = File('${temp.path}/CHANGELOG.md');
      await file.writeAsString(changelog);
      final result = await Process.run('bash', [
        '10-MakeRelease.sh',
        '--has-feature',
        file.path,
      ], workingDirectory: Directory.current.path);
      return result.exitCode;
    }

    test('a feature under Unreleased is found', () async {
      expect(
        await hasFeature('## Unreleased\n- E: a fix\n- N: something new\n'),
        0,
      );
    });

    test('fixes and tweaks alone are not one', () async {
      expect(
        await hasFeature('## Unreleased\n- E: a fix\n- F: a tweak\n'),
        isNot(0),
      );
    });

    // What was released long ago must not keep demanding a line of its own.
    test('a feature in an older section does not count', () async {
      expect(
        await hasFeature(
          '## Unreleased\n- E: a fix\n\n## v0.2.260813+95\n- N: an old one\n',
        ),
        isNot(0),
      );
    });

    test('an empty Unreleased is quiet', () async {
      expect(
        await hasFeature('## Unreleased\n\n## v0.2.260813+95\n- N: an old one\n'),
        isNot(0),
      );
    });
  });

  test('rejects malformed input before mutation', () async {
    final result = await compute('not-a-version', '260811');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Malformed version'));
  });

  // End to end, on a fixture of its own: a project with one tag, one version
  // and a changelog the test writes. What the line does is the whole point of
  // the rule, and it is decided by those three together.
  group('the line follows the changelog by itself', () {
    Future<String> dryRun(
      String changelog, {
      List<String> flags = const [],
      String version = '0.2.260811+72',
    }) async {
      final Directory root = await Directory.systemTemp.createTemp(
        'easysend-line-',
      );
      addTearDown(() => root.delete(recursive: true));
      await File('10-MakeRelease.sh').copy('${root.path}/10-MakeRelease.sh');
      final String name = version.split('+').first;
      final String build = version.split('+').last;
      await File(
        '${root.path}/pubspec.yaml',
      ).writeAsString('name: test_app\nversion: $version\n');
      await Directory('${root.path}/lib').create();
      await File('${root.path}/lib/globals.dart').writeAsString(
        "const String progVersion = '$name';\nconst int buildNumber = $build;\n",
      );
      await File('${root.path}/CHANGELOG.md').writeAsString(changelog);
      // The last release this fixture knows about went out on 0.2.
      final Directory bin = await Directory('${root.path}/fake-bin').create();
      final File git = File('${bin.path}/git');
      await git.writeAsString(
        '#!/usr/bin/env bash\n'
        '[ "\$1" = "tag" ] && echo "v0.2.260811+72"\nexit 0\n',
      );
      await Process.run('chmod', ['+x', git.path]);

      final ProcessResult result = await Process.run(
        'bash',
        ['10-MakeRelease.sh', '--dry-run', ...flags],
        workingDirectory: root.path,
        environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return (result.stdout as String).trim();
    }

    test('a feature waiting takes the minor up', () async {
      expect(
        await dryRun('## Unreleased\n- E: a fix\n- N: something new\n'),
        startsWith('0.3.'),
      );
    });

    test('fixes alone leave it where it was', () async {
      expect(
        await dryRun('## Unreleased\n- E: a fix\n- F: a tweak\n'),
        startsWith('0.2.'),
      );
    });

    test('a feature already released does not move it again', () async {
      expect(
        await dryRun(
          '## Unreleased\n- E: a fix\n\n## v0.2.260811+72\n- N: an old one\n',
        ),
        startsWith('0.2.'),
      );
    });

    // Several at once are still one release, so one step: the minor counts
    // releases that carried something new, not the things they carried.
    test('several features are one step, not several', () async {
      expect(
        await dryRun('## Unreleased\n- N: one\n- E: a fix\n- N: two\n'),
        startsWith('0.3.'),
      );
    });

    // The load-bearing half: many builds go out between two tags, and only the
    // first of them moves the line. Without this the version would run away by
    // one step per build for as long as the feature sat unreleased.
    test('a line already moved is not moved again', () async {
      expect(
        await dryRun(
          '## Unreleased\n- N: something new\n',
          version: '0.3.260812+80',
        ),
        startsWith('0.3.'),
      );
    });

    test('either overrule wins over the changelog', () async {
      expect(
        await dryRun(
          '## Unreleased\n- N: something new\n',
          flags: ['--keep-line'],
        ),
        startsWith('0.2.'),
      );
      expect(
        await dryRun('## Unreleased\n- E: a fix\n', flags: ['--minor']),
        startsWith('0.3.'),
      );
    });
  });

  test('repository version sources agree in dry-run mode', () async {
    // Derived from the file rather than written down: a build number spelled
    // out here would make this test fail on the release after next.
    final RegExpMatch? current = RegExp(
      r'^version:\s*(\d+\.\d+)\.\d{6}\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(await File('pubspec.yaml').readAsString());
    expect(current, isNotNull, reason: 'pubspec.yaml carries no version line');
    final String line = current!.group(1)!;
    final int nextBuild = int.parse(current.group(2)!) + 1;

    // --keep-line so this stays a question about the two version sources: what
    // the line does depends on the changelog, and the group above owns that.
    final result = await Process.run('bash', [
      '10-MakeRelease.sh',
      '--dry-run',
      '--keep-line',
    ], workingDirectory: Directory.current.path);
    // A non-zero exit is the script refusing pubspec.yaml and globals.dart
    // after they drifted apart, which is the disagreement this test is for.
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      (result.stdout as String).trim(),
      matches(RegExp('^${RegExp.escape(line)}\\.\\d{6}\\+$nextBuild\$')),
    );
  });
}
