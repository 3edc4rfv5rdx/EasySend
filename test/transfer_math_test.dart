import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'multi-gigabyte totals and progress use integers without allocation',
    () {
      final transfer = TransferSession(
        id: 'id',
        incoming: false,
        peerName: 'Peer',
        files: [
          FileItem(
            id: 'large',
            relativePath: 'large.bin',
            size: 5 * 1024 * 1024 * 1024,
          ),
          FileItem(id: 'zero', relativePath: 'empty.bin', size: 0),
        ],
      );
      expect(transfer.bytesTotal, 5368709120);
      transfer.noteProgress(2684354560);
      expect(transfer.progress, 0.5);
    },
  );

  test('progress remains bounded and ETA completes at the total', () async {
    final transfer = TransferSession(
      id: 'id',
      incoming: false,
      peerName: 'Peer',
      files: [FileItem(id: 'file', relativePath: 'file', size: 100)],
    );
    transfer.noteProgress(0);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    transfer.noteProgress(100);
    expect(transfer.speed, greaterThan(0));
    expect(transfer.etaSeconds, 0);
    transfer.noteProgress(1000);
    expect(transfer.progress, 1);
  });

  test(
    'retry samples cannot move progress backwards or make speed negative',
    () async {
      final TransferSession transfer = TransferSession(
        id: 'retry',
        incoming: false,
        peerName: 'Peer',
        files: [FileItem(id: 'one', relativePath: 'one', size: 100)],
      );

      transfer.noteProgress(80);
      await Future<void>.delayed(const Duration(milliseconds: 2));
      transfer.noteProgress(20);
      expect(transfer.bytesDone, 80);
      expect(transfer.progress, 0.8);
      expect(transfer.speed, greaterThanOrEqualTo(0));

      transfer.noteProgress(1000);
      expect(transfer.bytesDone, 100);
      expect(transfer.progress, 1);
      expect(transfer.etaSeconds, 0);
    },
  );

  // The number over the bar is read as the answer to "is it there yet", so it
  // may only say 100% when everything actually arrived.
  test('the percent over the bar rounds down and stays in range', () {
    expect(formatPercent(0), '0%');
    expect(formatPercent(0.456), '45%');
    // One byte short of five gigabytes.
    expect(formatPercent(5368709119 / 5368709120), '99%');
    expect(formatPercent(1), '100%');
    expect(formatPercent(1.4), '100%');
    expect(formatPercent(-0.2), '0%');
    expect(formatPercent(double.nan), '0%');
  });

  test('a terminal zero-byte transfer has complete progress', () {
    final TransferSession transfer = TransferSession(
      id: 'empty',
      incoming: true,
      peerName: 'Peer',
      files: [FileItem(id: 'empty', relativePath: 'empty', size: 0)],
    );
    expect(transfer.progress, 0);
    transfer.status = TransferStatus.partial;
    expect(transfer.progress, 1);
  });
}
