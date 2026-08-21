import 'package:easysend/globals.dart';
import 'package:easysend/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The other half of "one transfer at a time, in either direction": the receiver
  // refuses a second peer, and this is what refuses the user. The receive slot is
  // its own reason and comes first — while a consent question stands on screen
  // there is no row in the transfer list to explain why Send does nothing.
  group('what stops Send from starting', () {
    test('the receive slot outranks the missing pieces', () {
      expect(
        sendBlockedBy(receiveSlotHeld: true, hasFiles: true, hasTarget: true),
        SendBlock.receiving,
      );
      expect(
        sendBlockedBy(receiveSlotHeld: true, hasFiles: false, hasTarget: false),
        SendBlock.receiving,
      );
    });

    test('then the files, then the device', () {
      expect(
        sendBlockedBy(receiveSlotHeld: false, hasFiles: false, hasTarget: true),
        SendBlock.noFiles,
      );
      expect(
        sendBlockedBy(receiveSlotHeld: false, hasFiles: true, hasTarget: false),
        SendBlock.noTarget,
      );
    });

    test('nothing in the way', () {
      expect(
        sendBlockedBy(receiveSlotHeld: false, hasFiles: true, hasTarget: true),
        isNull,
      );
    });
  });

  test('a running transfer is the one thing that offers Stop', () {
    expect(
      sendButtonMode(transferRunning: true, senderBusy: true),
      SendButtonMode.stop,
    );
    // An incoming transfer runs while this device sends nothing.
    expect(
      sendButtonMode(transferRunning: true, senderBusy: false),
      SendButtonMode.stop,
    );
  });

  test('the gap after Stop says so instead of offering Send', () {
    // Cancel has already marked the transfer, the send has not let go yet.
    expect(
      sendButtonMode(transferRunning: false, senderBusy: true),
      SendButtonMode.stopping,
    );
  });

  // Nothing is on the wire yet and the minutes are going into the archive. The
  // button still stops the transfer — that is the only way out of a pack — but
  // Stop is not what it has to say.
  test('packing outranks the running transfer it is part of', () {
    expect(
      sendButtonMode(transferRunning: true, senderBusy: true, packing: true),
      SendButtonMode.packing,
    );
    expect(
      sendButtonMode(transferRunning: true, senderBusy: true),
      SendButtonMode.stop,
    );
  });

  // The move's own tail: the transfer is over, the sender still holds the batch
  // while it removes the originals. Stopping in red said the user had asked for
  // something to end, and offered a press that would not have ended it.
  test('deleting the originals is its own state, not a stop', () {
    expect(
      sendButtonMode(
        transferRunning: false,
        senderBusy: true,
        deletingSources: true,
      ),
      SendButtonMode.deleting,
    );
    // An incoming transfer still owns the button: that one can be stopped.
    expect(
      sendButtonMode(
        transferRunning: true,
        senderBusy: true,
        deletingSources: true,
      ),
      SendButtonMode.stop,
    );
  });

  test('with nothing in flight the button sends', () {
    expect(
      sendButtonMode(transferRunning: false, senderBusy: false),
      SendButtonMode.send,
    );
  });

  // One transfer at a time, in either direction. Retry starts one of its own,
  // and it was the only control left that could have made two of them run at
  // once: an incoming transfer leaves the sender idle, so nothing stopped it.
  test('Retry waits for whatever is running, incoming included', () {
    expect(
      retryEnabled(senderBusy: false, anyTransferRunning: false),
      isTrue,
    );
    expect(
      retryEnabled(senderBusy: false, anyTransferRunning: true),
      isFalse,
    );
    expect(
      retryEnabled(senderBusy: true, anyTransferRunning: false),
      isFalse,
    );
  });

  // What a Retry would have to re-send. A ZIP send has nothing: the archive it
  // names was deleted with the transfer, and the files it held went back to the
  // picked list, where Send is the button that sends them again.
  group('what a transfer can offer a Retry', () {
    TransferSession failedWith(List<FileItem> files) => TransferSession(
      id: 'session',
      incoming: false,
      peerName: 'Peer',
      peerId: 'peer',
      files: files,
    )..status = TransferStatus.failed;

    FileItem source(String name) =>
        FileItem(id: name, relativePath: name, size: 1, sourcePath: '/tmp/$name');

    test('a plain send offers what did not get there', () {
      expect(retryableTransfer(failedWith([source('a.txt')])), isTrue);
    });

    test('an archive offers nothing, whatever the row says', () {
      final TransferSession transfer = failedWith([source('Trip.zip')])
        ..archived = true;
      expect(retryableTransfer(transfer), isFalse);
    });
  });
}
