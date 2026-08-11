import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late String defaultDir;
  late String chosenDir;

  const String saved = '4f2a1c88-8d2b-4c3e-9a71-6b5d0e7f1234';

  File idFile(String dir) => File(p.join(dir, '.easysend-id'));

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-identity-');
    defaultDir = p.join(sandbox.path, 'Download', 'EasySend');
    chosenDir = p.join(sandbox.path, 'Elsewhere', 'Received');
    xvConfigDir = p.join(sandbox.path, 'config');
    // What initPaths() worked out before settings were read.
    xvRecvDir = defaultDir;
    xvDeviceId = '';
    xvDeviceName = '';
    xvDevices = [];
    xdef = defaultSettings();
    xdef['Device name'] = 'Tester';
  });

  tearDown(() async {
    xdef = defaultSettings();
    await sandbox.delete(recursive: true);
  });

  test('the fallback id is read from the configured folder', () async {
    xdef['Receive folder'] = chosenDir;
    await idFile(chosenDir).parent.create(recursive: true);
    await idFile(chosenDir).writeAsString('$saved\n');

    await initIdentity(android: true);

    expect(xvRecvDir, chosenDir);
    expect(xvDeviceId, saved);
  });

  test('an id left in the default folder is still adopted', () async {
    // What an older build wrote before the folder was moved.
    xdef['Receive folder'] = chosenDir;
    await idFile(defaultDir).parent.create(recursive: true);
    await idFile(defaultDir).writeAsString('$saved\n');

    await initIdentity(android: true);

    expect(xvDeviceId, saved, reason: 'the old location is still read');
  });

  test('a fresh id is written where the files actually land', () async {
    xdef['Receive folder'] = chosenDir;

    await initIdentity(android: true);

    expect(isValidDeviceId(xvDeviceId), isTrue);
    expect(await idFile(chosenDir).exists(), isTrue);
    expect((await idFile(chosenDir).readAsString()).trim(), xvDeviceId);
    expect(
      await idFile(defaultDir).exists(),
      isFalse,
      reason: 'nothing belongs in a folder the user moved away from',
    );
  });

  test('with no folder chosen the default one is used and recorded', () async {
    await initIdentity(android: true);

    expect(xvRecvDir, defaultDir);
    expect(xdef['Receive folder'], defaultDir);
    expect(await idFile(defaultDir).exists(), isTrue);
  });

  test('a stored id wins over anything on disk', () async {
    xdef['Receive folder'] = chosenDir;
    xdef['.Device id'] = saved;
    await idFile(chosenDir).parent.create(recursive: true);
    await idFile(chosenDir).writeAsString(
      '00000000-0000-4000-8000-000000000000\n',
    );

    await initIdentity(android: true);

    expect(xvDeviceId, saved);
  });
}
