import 'dart:io';

import 'package:easysend/file_helpers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late Directory receive;
  late Directory outside;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-containment-');
    receive = await Directory(p.join(sandbox.path, 'receive')).create();
    outside = await Directory(p.join(sandbox.path, 'outside')).create();
  });

  tearDown(() => sandbox.delete(recursive: true));

  test(
    'accepts an ordinary nested destination and creates its parents',
    () async {
      final String path = p.join(receive.path, 'one', 'two', 'file.bin');
      expect(
        await ensureSafeDestination(receive.path, path, createParents: true),
        isTrue,
      );
      expect(await Directory(p.dirname(path)).exists(), isTrue);
    },
  );

  test('rejects lexical traversal and absolute destinations', () async {
    expect(
      await ensureSafeDestination(
        receive.path,
        p.join(receive.path, '..', 'x'),
      ),
      isFalse,
    );
    expect(await ensureSafeDestination(receive.path, outside.path), isFalse);
  });

  test('rejects a symlinked intermediate directory', () async {
    final Link link = Link(p.join(receive.path, 'link'));
    await link.create(outside.path);
    final String destination = p.join(link.path, 'stolen.bin');
    expect(
      await ensureSafeDestination(
        receive.path,
        destination,
        createParents: true,
      ),
      isFalse,
    );
    expect(await File(p.join(outside.path, 'stolen.bin')).exists(), isFalse);
  });

  test('rejects a symlinked final file inside a nested directory', () async {
    final File victim = File(p.join(outside.path, 'victim.bin'));
    await victim.writeAsString('unchanged');
    final Directory nested = await Directory(
      p.join(receive.path, 'one', 'two'),
    ).create(recursive: true);
    final String destination = p.join(nested.path, 'file.bin');
    await Link(destination).create(victim.path);
    expect(
      await ensureSafeDestination(
        receive.path,
        destination,
        createParents: true,
      ),
      isFalse,
    );
    expect(await victim.readAsString(), 'unchanged');
  });

  test('rejects a symlinked final file', () async {
    final File victim = File(p.join(outside.path, 'victim.bin'));
    await victim.writeAsString('unchanged');
    final String destination = p.join(receive.path, 'file.bin');
    await Link(destination).create(victim.path);
    expect(
      await ensureSafeDestination(
        receive.path,
        destination,
        createParents: true,
      ),
      isFalse,
    );
    expect(await victim.readAsString(), 'unchanged');
  });
}
