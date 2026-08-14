import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

// The picker's native half and the Dart side share one directory and one rule
// about what lives in it. Neither can be run from here, so what is checked is
// the contract itself: the name they agree on, and the shape of what the native
// side writes there.
void main() {
  Future<String> activity() => File(
    'android/app/src/main/kotlin/a/a/easysend/MainActivity.kt',
  ).readAsString();

  test('both sides name the copies directory the same', () async {
    // isAppOwnedCopy and the startup sweep are pointed at this name from Dart;
    // the Activity writes into it. A rename on one side alone would leave a
    // move deleting the app's own scratch copies as though they were the
    // user's files.
    expect(await activity(), contains('COPIES_DIR = "$pickedCopiesDirName"'));
  });

  test('every copy is given a directory of its own', () async {
    final RegExp copy = RegExp(
      r'private fun copyToCache[\s\S]*?\n    \}\n',
    );
    final String body = copy.firstMatch(await activity())!.group(0)!;

    // Two documents can carry one display name. Sharing a cache path leaves the
    // second's bytes under the first's path, where the Dart side folds them
    // into a single pick — it tells picked files apart by source path — and
    // sends a file whose name and content came from different documents.
    expect(body, contains('copySlot.getAndIncrement()'));
    expect(body, contains('slot.mkdirs()'));
    // And the copy keeps the name its owner gave it: the uniqueness is in the
    // directory, never in the name that travels.
    expect(body, contains('File(slot, name)'));
  });

  // The Dart side's half of the same contract: a copy one level deeper is still
  // recognised as the app's own, so a move leaves it alone.
  test('a copy nested in its own directory is still app-owned', () {
    expect(isAppOwnedCopy('/cache/picked/1-0/report.pdf', '/cache/picked'), isTrue);
    expect(isAppOwnedCopy('/cache/picked/1-1/report.pdf', '/cache/picked'), isTrue);
    expect(isAppOwnedCopy('/home/e/report.pdf', '/cache/picked'), isFalse);
  });
}
