import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('exiting lets go of everything that lasts one run', () async {
    // On Android nothing kills the process on the way out: the Activity ends,
    // the engine stays in Application, and the Dart state with it. Without this
    // the next launch opens on the finished transfers of the last one, and the
    // sweeps that run once a launch never run again for as long as Android
    // keeps the process — which on a phone is days.
    final TransferSession running = TransferSession(
      id: 'still-going',
      incoming: false,
      peerName: 'A36',
      peerId: 'phone',
      files: const [],
    )..status = TransferStatus.active;
    xvTransfers = [
      TransferSession(
        id: 'sent',
        incoming: false,
        peerName: 'A36',
        peerId: 'phone',
        files: const [],
      )..status = TransferStatus.done,
      running,
    ];
    final int notified = transfersTick.value;

    // Mark this launch as swept. Both flags are set before either call goes
    // near a directory, so a test host with no plugins behind it still leaves
    // them where a real run would.
    try {
      await sweepScratchOnce();
    } catch (_) {}
    try {
      await sweepOrphanSessionsOnce();
    } catch (_) {}
    expect(sweepsDone, isTrue);

    clearSessionState();

    // An exit does not cancel an outgoing send, and on Android the process
    // carries it on, so the one still running keeps its row. Dropping it would
    // leave a transfer writing progress into a session nothing lists.
    expect(xvTransfers, [running]);
    // The screen is repainted from the tick, so an empty list nobody was told
    // about would still be on screen.
    expect(transfersTick.value, greaterThan(notified));
    // And the next launch cleans the cache again instead of counting on a
    // process death that never comes.
    expect(sweepsDone, isFalse);
  });
}
