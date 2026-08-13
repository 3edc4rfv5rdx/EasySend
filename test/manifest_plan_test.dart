import 'dart:io';

import 'package:easysend/file_helpers.dart';
import 'package:easysend/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

FileItem item(String id, String path, {int size = 1}) =>
    FileItem(id: id, relativePath: path, size: size);

void main() {
  late Directory root;
  setUp(
    () async => root = await Directory.systemTemp.createTemp('easysend-plan-'),
  );
  tearDown(() => root.delete(recursive: true));

  test('rejects empty and duplicate ids', () async {
    await expectLater(
      buildDestinationPlan(root.path, [item('', 'a')]),
      throwsA(isA<DestinationPlanException>()),
    );
    await expectLater(
      buildDestinationPlan(root.path, [item('x', 'a'), item('x', 'b')]),
      throwsA(isA<DestinationPlanException>()),
    );
  });

  test('reserves identical paths in memory', () async {
    final plan = await buildDestinationPlan(root.path, [
      item('1', 'same.txt'),
      item('2', 'same.txt', size: 99),
    ]);
    expect(plan['1'], p.join(root.path, 'same.txt'));
    expect(plan['2'], p.join(root.path, 'same (1).txt'));
  });

  test('reserves case-only collisions for Windows', () async {
    final plan = await buildDestinationPlan(root.path, [
      item('1', 'File.txt'),
      item('2', 'file.txt'),
    ], windows: true);
    expect(
      pathEqualityKey(plan['1']!, windows: true),
      isNot(pathEqualityKey(plan['2']!, windows: true)),
    );
  });

  test('accounts for existing files and directories', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('old');
    await Directory(p.join(root.path, 'b.txt')).create();
    final plan = await buildDestinationPlan(root.path, [
      item('1', 'a.txt'),
      item('2', 'b.txt'),
    ]);
    expect(p.basename(plan['1']!), 'a (1).txt');
    expect(p.basename(plan['2']!), 'b (1).txt');
  });

  test('rejects file and directory prefix conflicts', () async {
    await expectLater(
      buildDestinationPlan(root.path, [item('1', 'a'), item('2', 'a/b.txt')]),
      throwsA(isA<DestinationPlanException>()),
    );
  });

  // The check compares manifest paths, which always carry '/', instead of host
  // paths: on Windows those would be normalized to '\' and never match.
  test('rejects prefix conflicts that only Windows folds together', () async {
    await expectLater(
      buildDestinationPlan(root.path, [
        item('1', 'Photos'),
        item('2', 'photos/a.txt'),
      ], windows: true),
      throwsA(isA<DestinationPlanException>()),
    );
    final plan = await buildDestinationPlan(root.path, [
      item('1', 'Photos'),
      item('2', 'photos/a.txt'),
    ], windows: false);
    expect(plan.length, 2);
  });

  // The conflicting entry need not be the immediate parent: any ancestor of a
  // path being a file of its own is the same collision one level further up.
  test('rejects prefix conflicts at any depth', () async {
    await expectLater(
      buildDestinationPlan(root.path, [
        item('1', 'x/y'),
        item('2', 'x/y/z.txt'),
      ]),
      throwsA(isA<DestinationPlanException>()),
    );
    await expectLater(
      buildDestinationPlan(root.path, [
        item('1', 'a/b/c/deep.txt'),
        item('2', 'a'),
      ]),
      throwsA(isA<DestinationPlanException>()),
    );
  });

  // Sharing a folder is not a conflict, however many entries do it.
  test('accepts entries that only share a directory', () async {
    final plan = await buildDestinationPlan(root.path, [
      item('1', 'a/b/one.txt'),
      item('2', 'a/b/two.txt'),
      item('3', 'a/other.txt'),
    ]);
    expect(plan.length, 3);
  });

  // The conflict check used to compare every entry with every other one, which
  // at the 3000-file limit is nine million comparisons run synchronously inside
  // the prepare handler — before the consent question appears. Timed as a ratio
  // rather than against a wall-clock bound: the machine cancels out and what is
  // left is the growth curve. Eight times the entries is eight times the work
  // when the scan is a prefix lookup and sixty-four when it is pairwise; the
  // per-file filesystem checks are linear and pull both figures down. Measured
  // here: 21.4 with the pairwise scan, 5.6 with the prefix lookup, so the line
  // sits between them with room on both sides rather than beside either.
  test('planning cost grows with the manifest, not with its square', () async {
    Future<int> micros(int count) async {
      final List<FileItem> files = [
        for (int i = 0; i < count; i++)
          item('$i', 'Camera/2026/08/IMG_${i.toString().padLeft(6, '0')}.jpg'),
      ];
      final Stopwatch watch = Stopwatch()..start();
      await buildDestinationPlan(root.path, files, windows: true);
      return watch.elapsedMicroseconds;
    }

    // Warm the filesystem and the JIT, so the first measurement is not the one
    // that pays for both.
    await micros(375);
    final int small = await micros(375);
    final int large = await micros(3000);
    final double growth = large / small;

    expect(
      growth,
      lessThan(12),
      reason: 'eight times the files cost $growth times the work',
    );
  });

  Future<File> part(String name, String content) async {
    final File f = File(p.join(root.path, name));
    await f.writeAsString(content);
    return f;
  }

  test('a file created in the claim window keeps its place', () async {
    final File incoming = await part('0.part', 'incoming');
    final String planned = p.join(root.path, 'photo.jpg');
    final File late = File(planned);

    // accept() runs immediately before the name is claimed, which is exactly
    // the window a plain check-then-rename cannot see into.
    final String? published = await publishVerifiedFile(
      incoming,
      planned,
      accept: (String candidate) async {
        if (candidate == planned && !await late.exists()) {
          await late.writeAsString('created after the check');
        }
        return true;
      },
    );

    expect(published, p.join(root.path, 'photo (1).jpg'));
    expect(await late.readAsString(), 'created after the check');
    expect(await File(published!).readAsString(), 'incoming');
    expect(await incoming.exists(), isFalse);
  });

  test('a link at the destination is never replaced', () async {
    final File incoming = await part('0.part', 'incoming');
    final File target = await part('elsewhere.txt', 'user data');
    final String planned = p.join(root.path, 'linked.txt');
    await Link(planned).create(target.path);

    final String? published = await publishVerifiedFile(
      incoming,
      planned,
      accept: (_) async => true,
    );

    expect(published, p.join(root.path, 'linked (1).txt'));
    expect(await Link(planned).target(), target.path);
    expect(await target.readAsString(), 'user data');
  });

  test('two contenders for one name both land intact', () async {
    final File first = await part('0.part', 'first');
    final File second = await part('1.part', 'second');
    final String planned = p.join(root.path, 'shared.bin');
    Future<bool> accept(_) async => true;

    final List<String?> names = await Future.wait([
      publishVerifiedFile(first, planned, accept: accept),
      publishVerifiedFile(second, planned, accept: accept),
    ]);

    expect(names.whereType<String>().toSet().length, 2);
    expect(await File(names[0]!).readAsString(), 'first');
    expect(await File(names[1]!).readAsString(), 'second');
  });

  test('a refused publication leaves no empty placeholder', () async {
    final File incoming = await part('0.part', 'incoming');
    final String planned = p.join(root.path, 'refused.bin');

    expect(
      await publishVerifiedFile(incoming, planned, accept: (_) async => false),
      isNull,
    );
    expect(await File(planned).exists(), isFalse);
    expect(await incoming.readAsString(), 'incoming');
  });

  test('the name past the numbered range is checked and reserved', () async {
    final String planned = p.join(root.path, 'full.txt');
    final Set<String> reserved = {
      pathEqualityKey(planned),
      for (int i = 1; i < 10000; i++)
        pathEqualityKey(p.join(root.path, 'full ($i).txt')),
    };

    final String? first = await uniquePath(planned, reserved: reserved);
    final String? second = await uniquePath(planned, reserved: reserved);

    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(first, isNot(second));
    expect(reserved, contains(pathEqualityKey(first!)));
    expect(reserved, contains(pathEqualityKey(second!)));
    // Whatever the fallback is called, it is a name in the receive folder that
    // nothing occupies — the old one was returned without ever looking.
    expect(p.dirname(first), root.path);
    expect(await File(first).exists(), isFalse);
  });
}
