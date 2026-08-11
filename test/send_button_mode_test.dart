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
}
