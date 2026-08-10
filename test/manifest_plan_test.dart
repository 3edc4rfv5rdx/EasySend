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

  test('accounts for existing files and part files', () async {
    await File(p.join(root.path, 'a.txt')).writeAsString('old');
    await File(
      p.join(root.path, 'b.txt.easysend-part'),
    ).writeAsString('partial');
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
}
