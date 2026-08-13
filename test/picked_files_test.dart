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

  List<PickProblem> problemsOf(List<RefusedPick> refused) =>
      refused.map((RefusedPick r) => r.problem).toList();

  test('a clean pick is taken whole', () {
    final picked = sortPickedFiles([
      item('a.txt'),
      item('folder/b.txt'),
    ], <FileItem>[]);
    expect(picked.fresh, hasLength(2));
    expect(picked.duplicates, 0);
    expect(picked.refused, isEmpty);
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

  test('every refusal is named with its own reason', () {
    final picked = sortPickedFiles([
      item('../escape.txt'),
      item('CON'),
      item(r'report\draft.pdf'),
      item('${'a' * (maxPathComponentChars + 1)}.txt'),
      item('huge.bin', size: maxDeclaredFileBytes + 1),
      item('ok.txt'),
    ], <FileItem>[]);

    expect(picked.fresh.single.relativePath, 'ok.txt');
    expect(problemsOf(picked.refused), [
      PickProblem.notPortable,
      PickProblem.reserved,
      PickProblem.backslash,
      PickProblem.tooLong,
      PickProblem.tooLarge,
    ]);
    // The name travels with the reason: the dialog shows it as it was picked.
    expect(picked.refused[2].file.relativePath, r'report\draft.pdf');
  });

  test('a backslash is refused rather than turned into a folder', () {
    // It is an ordinary character in a POSIX name and a separator elsewhere,
    // so the same name cannot mean one thing at both ends.
    expect(sanitizeRelPath(r'report\draft.pdf'), isNull);
    expect(classifyRefusal(r'report\draft.pdf'), PickProblem.backslash);
    // Repaired, it is an ordinary name again.
    expect(repairBackslashes(r'report\draft.pdf'), 'report-draft.pdf');
    expect(sanitizeRelPath('report-draft.pdf'), 'report-draft.pdf');
  });

  test('length beats a backslash, since no dash can shorten a name', () {
    final String long = '${'a' * maxPathComponentChars}\\x.txt';
    expect(classifyRefusal(long), PickProblem.tooLong);
  });

  test('a repaired name still has to pass everything else', () {
    // Two files differing only by the backslash collapse onto one name once it
    // is replaced, and the second is then an ordinary duplicate.
    final List<FileItem> repaired = [
      item(r'a\b.txt', source: '/tmp/one').renamed('a-b.txt'),
      item('a-b.txt', source: '/tmp/two'),
    ];
    final picked = sortPickedFiles(repaired, <FileItem>[]);
    expect(picked.fresh, hasLength(1));
    expect(picked.duplicates, 1);
  });

  test('renaming keeps everything else about the file', () {
    final FileItem original = item(r'x\y.bin', source: '/tmp/x', size: 42);
    final FileItem renamed = original.renamed('x-y.bin');
    expect(renamed.relativePath, 'x-y.bin');
    expect(renamed.id, original.id);
    expect(renamed.sourcePath, original.sourcePath);
    expect(renamed.size, 42);
  });

  group('selection limits', () {
    test('an addition that fits is admitted', () {
      expect(
        selectionLimitBroken([item('a.txt')], [item('b.txt')]),
        isNull,
      );
    });

    test('exactly at either limit still fits', () {
      final List<FileItem> selected = [
        for (int i = 0; i < maxManifestFiles - 1; i++) item('f$i.txt'),
      ];
      expect(selectionLimitBroken(selected, [item('last.txt')]), isNull);
      expect(
        selectionLimitBroken(
          [item('big.bin', size: maxDeclaredTransferBytes - 10)],
          [item('tail.bin', size: 10)],
        ),
        isNull,
      );
    });

    test('one file too many is refused by count', () {
      final List<FileItem> selected = [
        for (int i = 0; i < maxManifestFiles; i++) item('f$i.txt'),
      ];
      expect(
        selectionLimitBroken(selected, [item('one-more.txt')]),
        SelectionLimit.files,
      );
    });

    // The repair path checked the count and nothing else, so a repaired file
    // could take the selection past a size the receiver refuses outright.
    test('a file that only crosses the total size is refused', () {
      expect(
        selectionLimitBroken(
          [item('big.bin', size: maxDeclaredTransferBytes - 10)],
          [item('repaired.bin', size: 11)],
        ),
        SelectionLimit.bytes,
      );
    });

    test('an empty addition never breaks a limit', () {
      expect(
        selectionLimitBroken(
          [item('big.bin', size: maxDeclaredTransferBytes)],
          <FileItem>[],
        ),
        isNull,
      );
    });
  });

  // A Retry rebuilds its files from disk to re-read what is there now, so what
  // it marks delivered are new objects with new ids. The picked list cannot
  // recognise them by identity, and a file that had arrived used to stay in the
  // list with the next Send ready to send it a second time.
  group('a retried batch clears what it delivered', () {
    // The same files as far as the disk is concerned, rebuilt: new ids, same
    // source paths, which is exactly what restoreFileSnapshot produces.
    FileItem rebuilt(String relativePath, {required bool done}) =>
        FileItem(
          id: 'rebuilt-$relativePath',
          relativePath: relativePath,
          size: 1,
          sourcePath: '/tmp/$relativePath',
        )..done = done;

    test('delivered paths are read off the batch', () {
      expect(
        deliveredSourcePaths([
          rebuilt('a.txt', done: true),
          rebuilt('b.txt', done: false),
        ]),
        {'/tmp/a.txt'},
      );
    });

    test('a file with no source of its own is never matched', () {
      final FileItem shared = FileItem(
        id: 'incoming',
        relativePath: 'c.txt',
        size: 1,
      )..done = true;
      expect(deliveredSourcePaths([shared]), isEmpty);
    });

    test('the selection loses exactly what arrived', () {
      final List<FileItem> selection = [item('a.txt'), item('b.txt')];

      final List<FileItem> left = withoutDelivered(selection, [
        rebuilt('a.txt', done: true),
        rebuilt('b.txt', done: false),
      ]);

      expect(left.map((FileItem f) => f.relativePath), ['b.txt']);
    });

    test('a batch that delivered nothing leaves the selection alone', () {
      final List<FileItem> selection = [item('a.txt')];
      expect(
        withoutDelivered(selection, [rebuilt('a.txt', done: false)]),
        same(selection),
      );
      expect(withoutDelivered(selection, <FileItem>[]), same(selection));
    });

    // Scoped to the one batch on purpose: picking a file again after it has
    // been sent puts it back in the list, and nothing may quietly take it out.
    test('a file picked again is not taken for an old delivery', () {
      final List<FileItem> selection = [item('a.txt')];
      expect(withoutDelivered(selection, <FileItem>[]).length, 1);
    });
  });
}
