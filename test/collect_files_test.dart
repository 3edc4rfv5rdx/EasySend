import 'dart:io';

import 'package:easysend/file_helpers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-collect-');
  });
  tearDown(() => sandbox.delete(recursive: true));

  // Nested on purpose: the walk has to stop inside a subtree, not only between
  // the top-level entries.
  Future<Directory> tree(int files, {int bytes = 1}) async {
    final Directory root = await Directory(
      p.join(sandbox.path, 'tree'),
    ).create();
    for (int i = 0; i < files; i++) {
      final Directory dir = await Directory(
        p.join(root.path, 'sub${i ~/ 4}'),
      ).create(recursive: true);
      await File(p.join(dir.path, 'file$i.bin')).writeAsBytes(
        List<int>.filled(bytes, 7),
      );
    }
    return root;
  }

  test('a folder within the budget is collected whole', () async {
    final Directory root = await tree(5);
    final CollectedFiles collected = await collectFiles([
      root.path,
    ], maxFiles: 5);

    expect(collected.overflowed, isFalse);
    expect(collected.items.length, 5);
    expect(
      collected.items.every((f) => f.relativePath.startsWith('tree/')),
      isTrue,
    );
  });

  test('the file budget stops the walk instead of the caller', () async {
    final Directory root = await tree(400);
    final CollectedFiles collected = await collectFiles([
      root.path,
    ], maxFiles: 5);

    expect(collected.tooManyFiles, isTrue);
    expect(collected.tooLarge, isFalse);
    // One past the limit is the whole overrun: the other 394 are never stat'ed
    // and never held.
    expect(collected.items.length, 6);
  });

  test('the byte budget stops the walk too', () async {
    final Directory root = await tree(400, bytes: 10);
    final CollectedFiles collected = await collectFiles([
      root.path,
    ], maxBytes: 25);

    expect(collected.tooLarge, isTrue);
    expect(collected.items.length, 3);
  });

  test('a second picked path is not walked once the budget is gone', () async {
    final Directory root = await tree(400);
    final File single = File(p.join(sandbox.path, 'alone.bin'));
    await single.writeAsString('x');

    final CollectedFiles collected = await collectFiles([
      root.path,
      single.path,
    ], maxFiles: 5);

    expect(collected.tooManyFiles, isTrue);
    expect(collected.items.length, 6);
    expect(collected.items.any((f) => f.sourcePath == single.path), isFalse);
  });

  test('a folder that cannot be listed loses only itself', () async {
    final Directory locked = await Directory(
      p.join(sandbox.path, 'locked'),
    ).create();
    await File(p.join(locked.path, 'hidden.bin')).writeAsString('x');
    final File readable = File(p.join(sandbox.path, 'readable.bin'));
    await readable.writeAsString('x');
    await Process.run('chmod', ['000', locked.path]);
    addTearDown(() => Process.run('chmod', ['700', locked.path]));

    final CollectedFiles collected = await collectFiles([
      locked.path,
      readable.path,
    ]);

    expect(collected.overflowed, isFalse);
    expect(collected.items.map((f) => f.sourcePath), [readable.path]);
  });

  test('a path that is neither file nor folder is skipped', () async {
    final CollectedFiles collected = await collectFiles([
      p.join(sandbox.path, 'never-existed'),
    ]);

    expect(collected.items, isEmpty);
    expect(collected.overflowed, isFalse);
  });
}
