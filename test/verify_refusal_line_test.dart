import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

// The log is the one place that answers what happened to a single file, and it
// is what gets copied into a bug report. Every refused verify used to read as
// "Checksum did not match", whatever the receiver had actually said, with the
// status code dropped (ADD/tofix6.md #6).
void main() {
  test('a checksum mismatch is still named as one', () {
    final line = verifyRefusalLine(HttpStatus.conflict, reasonChecksum);

    expect(line.message, 'Checksum did not match');
    // Nothing to add: the message is the whole of it.
    expect(line.detail, isNull);
  });

  test('any other refusal says so and keeps the code', () {
    for (final ({int status, String? reason}) refusal in [
      (status: HttpStatus.conflict, reason: 'out-of-order'),
      (status: HttpStatus.internalServerError, reason: null),
      (status: HttpStatus.badRequest, reason: 'unknown-file'),
    ]) {
      final line = verifyRefusalLine(refusal.status, refusal.reason);

      expect(line.message, isNot('Checksum did not match'));
      expect(line.detail, contains('${refusal.status}'));
      if (refusal.reason != null) {
        expect(line.detail, contains(refusal.reason!));
      }
    }
  });

  // A conflict is what a mismatch comes back as, so the reason is what tells
  // the two apart — not the status on its own.
  test('a conflict without the checksum reason is not a mismatch', () {
    final line = verifyRefusalLine(HttpStatus.conflict, null);

    expect(line.message, isNot('Checksum did not match'));
    expect(line.detail, 'HTTP 409');
  });
}
