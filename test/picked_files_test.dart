import 'package:easysend/globals.dart';
import 'package:easysend/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  FileItem item(String relativePath, {String? source, int size = 1}) => FileItem(
    id: relativePath,
    relativePath: relativePath,
    size: size,
    sourcePath: source ?? '/tmp/$relativePath',
  );

  test('a clean pick is taken whole', () {
    final picked = sortPickedFiles([
      item('a.txt'),
      item('folder/b.txt'),
    ], <FileItem>[]);
    expect(picked.fresh, hasLength(2));
    expect(picked.duplicates, 0);
    expect(picked.unusable, 0);
  });

  test('the same file on disk is counted once', () {
    final List<FileItem> selected = [item('a.txt', source: '/tmp/a.txt')];
    final picked = sortPickedFiles([
      item('a.txt', source: '/tmp/a.txt'),
    ], selected);
    expect(picked.fresh, isEmpty);
    expect(picked.duplicates, 1);
  });

  test('two files that would land on the same name are counted once', () {
    // The same picture added on its own and again inside its folder, and a
    // second one whose case only differs — the far end may fold it.
    final picked = sortPickedFiles([
      item('photo.jpg', source: '/tmp/one/photo.jpg'),
      item('photo.jpg', source: '/tmp/two/photo.jpg'),
      item('PHOTO.JPG', source: '/tmp/three/PHOTO.JPG'),
    ], <FileItem>[]);
    expect(picked.fresh, hasLength(1));
    expect(picked.duplicates, 2);
  });

  test('names the receiver would refuse never enter the selection', () {
    final picked = sortPickedFiles([
      item('../escape.txt'),
      item('/absolute.txt'),
      item('CON'),
      item('trailing.'),
      item('ok.txt'),
    ], <FileItem>[]);
    expect(picked.fresh.single.relativePath, 'ok.txt');
    expect(picked.unusable, 4);
    expect(picked.duplicates, 0);
  });

  test('a file larger than the protocol declares is refused', () {
    final picked = sortPickedFiles([
      item('huge.bin', size: maxDeclaredFileBytes + 1),
      item('big.bin', size: maxDeclaredFileBytes),
    ], <FileItem>[]);
    expect(picked.fresh.single.relativePath, 'big.bin');
    expect(picked.unusable, 1);
  });

  test('what survives the sort is what a manifest may carry', () {
    // Every fresh item must pass the receiver's own path check, since that is
    // the rule this sort exists to apply early.
    final picked = sortPickedFiles([
      for (int i = 0; i < 20; i++) item('deep/folder/file-$i.bin'),
    ], <FileItem>[]);
    expect(picked.fresh, hasLength(20));
    for (final FileItem file in picked.fresh) {
      expect(sanitizeRelPath(file.relativePath), isNotNull);
    }
  });
}
