import 'dart:io';

import 'package:easysend/file_helpers.dart';
import 'package:easysend/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('restores current metadata without flattening relative paths', () async {
    final root = await Directory.systemTemp.createTemp('easysend-restore-');
    final first = File(p.join(root.path, 'one', 'same.txt'));
    final second = File(p.join(root.path, 'two', 'same.txt'));
    await first.create(recursive: true);
    await second.create(recursive: true);
    await first.writeAsString('one');
    await second.writeAsString('two');

    final original = [
      FileItem(
        id: '1',
        relativePath: 'folder/one/same.txt',
        size: 3,
        sourcePath: first.path,
      ),
      FileItem(
        id: '2',
        relativePath: 'folder/two/same.txt',
        size: 3,
        sourcePath: second.path,
      ),
    ];
    final snapshot = snapshotFiles(original);
    await first.writeAsString('changed');
    await second.delete();

    final restored = await restoreFileSnapshot(snapshot);
    expect(restored.missing, 1);
    expect(restored.files, hasLength(1));
    expect(restored.files.single.relativePath, 'folder/one/same.txt');
    expect(restored.files.single.size, 7);
    expect(restored.files.single.done, isFalse);
    expect(restored.files.single.failed, isFalse);

    await root.delete(recursive: true);
  });
}
