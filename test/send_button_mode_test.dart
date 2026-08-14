import 'package:easysend/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
