import 'dart:async';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('work runs one at a time, in the order it was queued', () async {
    final SerialQueue queue = SerialQueue('order');
    final List<String> log = [];
    final Completer<void> holdFirst = Completer<void>();

    final Future<void> first = queue.add(() async {
      log.add('first in');
      await holdFirst.future;
      log.add('first out');
    });
    final Future<void> second = queue.add(() async => log.add('second'));

    // Queued work starts on the next microtask, never inside add().
    expect(log, isEmpty);
    await Future<void>.delayed(Duration.zero);
    expect(log, ['first in'], reason: 'the second must wait its turn');
    holdFirst.complete();
    await Future.wait([first, second]);
    expect(log, ['first in', 'first out', 'second']);
  });

  test('a failure does not stop the queue for good', () async {
    final SerialQueue queue = SerialQueue('failure');
    final List<String> done = [];

    await queue.add(() async => throw StateError('nope'));
    await queue.add(() async => done.add('after the throw'));
    await queue.add(() async => throw Exception('again'));
    await queue.add(() async => done.add('after the second throw'));

    expect(done, ['after the throw', 'after the second throw']);
  });

  test('the future handed back never carries the failure', () async {
    final SerialQueue queue = SerialQueue('quiet');
    // Awaited by callers that only want to know the work is over.
    await expectLater(queue.add(() async => throw StateError('nope')), completes);
  });

  test('settings keep saving after a save that could not write', () async {
    final Directory sandbox = await Directory.systemTemp.createTemp(
      'easysend-queue-',
    );
    // A file where the config directory should be: nothing can be created here.
    final File blocker = File(p.join(sandbox.path, 'config'));
    await blocker.writeAsString('x');
    xvConfigDir = blocker.path;
    xvDevices = [];
    await saveSettings();

    xvConfigDir = p.join(sandbox.path, 'good');
    await saveSettings();
    expect(await File(p.join(xvConfigDir, settFile)).exists(), isTrue);

    await sandbox.delete(recursive: true);
  });
}
