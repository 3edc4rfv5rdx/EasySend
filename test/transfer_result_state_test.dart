import 'package:easysend/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'receiver records the verified destination without exposing it on wire',
    () {
      final file = FileItem(
        id: 'id',
        relativePath: 'folder/file.txt',
        size: 1,
        destinationPath: '/receive/folder/file.txt',
      );
      expect(file.destinationPath, '/receive/folder/file.txt');
      expect(file.toJson(), isNot(contains('destinationPath')));
    },
  );

  test('outgoing retry set consists only of unfinished source files', () {
    final done = FileItem(
      id: 'done',
      relativePath: 'done.txt',
      size: 1,
      sourcePath: '/source/done.txt',
    )..done = true;
    final failed = FileItem(
      id: 'failed',
      relativePath: 'failed.txt',
      size: 1,
      sourcePath: '/source/failed.txt',
    )..failed = true;
    final candidates = [done, failed].where((file) => !file.done).toList();
    expect(candidates, [failed]);
  });
}
