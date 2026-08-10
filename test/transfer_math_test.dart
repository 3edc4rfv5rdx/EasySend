import 'package:easysend/models.dart';
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
}
