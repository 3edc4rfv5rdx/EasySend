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

    final result = await Process.run('bash', [
      '10-MakeRelease.sh',
      '--dry-run',
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
