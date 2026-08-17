import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// The .apkx link is what gets sent over a messenger, so its name has to be the
// name of the file behind it. It used to be composed from pubspec.yaml while the
// file came from the directory listing, and the two could name different builds.
void main() {
  late Directory root;

  String apk(String name) =>
      p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk', name);

  Future<void> write(String path, String contents, DateTime when) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
    await file.setLastModified(when);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('easysend-apkx-');
    await File('99-CopyToAPKX.sh').copy(p.join(root.path, '99-CopyToAPKX.sh'));
    await write(
      apk('EasySend-0.4.260816-111-arm64-v8a.apk'),
      'older build',
      DateTime(2026, 8, 16, 10),
    );
    await write(
      apk('EasySend-0.4.260817-112-arm64-v8a.apk'),
      'newest build',
      DateTime(2026, 8, 17, 10),
    );
    // Not an arm64 split: never the one that gets linked.
    await write(
      apk('EasySend-0.4.260817-112-x86_64.apk'),
      'emulator build',
      DateTime(2026, 8, 17, 11),
    );
  });

  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> run() => Process.run('bash', [
    '99-CopyToAPKX.sh',
  ], workingDirectory: root.path);

  List<String> apkxNames() => Directory(root.path)
      .listSync()
      .map((FileSystemEntity e) => p.basename(e.path))
      .where((String name) => name.endsWith('.apkx'))
      .toList()
    ..sort();

  test('the link is named after the APK it points at', () async {
    final ProcessResult result = await run();
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');

    expect(apkxNames(), ['EasySend-0.4.260817-112-arm64-v8a.apkx']);
    expect(
      await File(
        p.join(root.path, 'EasySend-0.4.260817-112-arm64-v8a.apkx'),
      ).readAsString(),
      'newest build',
    );
  });

  test('a link left by an earlier build goes', () async {
    await Link(
      p.join(root.path, 'EasySend-111.apkx'),
    ).create(apk('EasySend-0.4.260816-111-arm64-v8a.apk'));

    await run();

    expect(apkxNames(), ['EasySend-0.4.260817-112-arm64-v8a.apkx']);
  });

  test('a plain .apkx somebody copied here is left alone', () async {
    await File(p.join(root.path, 'keep-me.apkx')).writeAsString('a real copy');

    await run();

    expect(apkxNames(), [
      'EasySend-0.4.260817-112-arm64-v8a.apkx',
      'keep-me.apkx',
    ]);
  });

  test('no arm64 APK is an error, not a dangling link', () async {
    await File(apk('EasySend-0.4.260816-111-arm64-v8a.apk')).delete();
    await File(apk('EasySend-0.4.260817-112-arm64-v8a.apk')).delete();

    final ProcessResult result = await run();
    expect(result.exitCode, isNot(0));
    expect(apkxNames(), isEmpty);
  });
}
