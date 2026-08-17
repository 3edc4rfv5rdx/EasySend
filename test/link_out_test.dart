import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// OUT/ is advertised as the one place to copy a build from, so what it must never
// do is lose an artifact that is still the newest of its kind. The sweep used to
// run whether or not this run had a full set to replace it with, and the
// artifact that takes longest to produce — the AppImage — was the one that went.
void main() {
  late Directory root;

  String out(String name) => p.join(root.path, 'OUT', name);
  String apk(String name) =>
      p.join(root.path, 'build', 'app', 'outputs', 'flutter-apk', name);
  String appImage(String name) => p.join(root.path, 'build', 'linux', name);

  Future<void> write(String path, String contents) async {
    final File file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('easysend-link-out-');
    await File('19-LinkOut.sh').copy(p.join(root.path, '19-LinkOut.sh'));
    // Last build, already in OUT: two APKs and the image.
    await write(out('EasySend-0.4.260816-111-arm64-v8a.apk'), 'old arm64');
    await write(out('EasySend-0.4.260816-111-armeabi-v7a.apk'), 'old v7a');
    await write(out('EasySend-0.4.260816-111-x86_64.AppImage'), 'old image');
    // This build, in the build tree.
    await write(apk('EasySend-0.4.260817-112-arm64-v8a.apk'), 'new arm64');
    await write(apk('EasySend-0.4.260817-112-armeabi-v7a.apk'), 'new v7a');
  });

  tearDown(() => root.delete(recursive: true));

  Future<ProcessResult> run() => Process.run('bash', [
    '19-LinkOut.sh',
  ], workingDirectory: root.path);

  List<String> listOut() =>
      Directory(p.join(root.path, 'OUT')).listSync().map((FileSystemEntity e) => p.basename(e.path)).toList()
        ..sort();

  test('a full set replaces what was there', () async {
    await write(appImage('EasySend-0.4.260817-112-x86_64.AppImage'), 'new image');

    final ProcessResult result = await run();
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(listOut(), [
      'EasySend-0.4.260817-112-arm64-v8a.apk',
      'EasySend-0.4.260817-112-armeabi-v7a.apk',
      'EasySend-0.4.260817-112-x86_64.AppImage',
    ]);
    // Hard links, so the entry in OUT is the build itself.
    expect(
      await File(out('EasySend-0.4.260817-112-x86_64.AppImage')).readAsString(),
      'new image',
    );
  });

  test('an incomplete set leaves OUT exactly as it was', () async {
    // No Linux build for this number: 14-MakeAppImage.sh has not run yet.
    final List<String> before = listOut();

    final ProcessResult result = await run();
    expect(result.exitCode, isNot(0));
    // The previous release is still whole, image included.
    expect(listOut(), containsAll(before));
    expect(
      await File(out('EasySend-0.4.260816-111-x86_64.AppImage')).readAsString(),
      'old image',
    );
  });
}
