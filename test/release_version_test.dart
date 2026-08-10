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

  test('rejects malformed input before mutation', () async {
    final result = await compute('not-a-version', '260811');
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Malformed version'));
  });

  test('repository version sources agree in dry-run mode', () async {
    final result = await Process.run('bash', [
      '10-MakeRelease.sh',
      '--dry-run',
    ], workingDirectory: Directory.current.path);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, matches(RegExp(r'^0\.2\.\d{6}\+65\s*$')));
  });
}
