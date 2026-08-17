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
}
