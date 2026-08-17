import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // The order matters and used to live inside a button handler, where no test
  // could reach it: an exit that stopped discovery before the receiver would
  // announce a listener that is still up, and one that let the foreground
  // service outlive the screen would leave a notification claiming a receiver
  // that had stopped.
  test('an exit stops things in order and says goodbye once', () async {
    final List<String> steps = [];
    bool? announced;
    xvDevices = [
      Device(id: 'phone', name: 'A36', departedAt: DateTime.now()),
      Device(id: 'laptop', name: 'MyLinuxSender', departedAt: DateTime.now()),
    ];
    xvTransfers = [
      TransferSession(
        id: 'done',
        incoming: true,
        peerName: 'A36',
        peerId: 'phone',
        files: const [],
      )..status = TransferStatus.done,
    ];

    await shutdownForExit(
      android: true,
      cancelSend: () async => steps.add('send'),
      stopReceiver: () async => steps.add('receiver'),
      stopAdvertisement: ({bool announceLeaving = false}) async {
        steps.add('discovery');
        announced = announceLeaving;
      },
      stopPolling: () => steps.add('poller'),
      stopBackgroundService: () async => steps.add('service'),
      clearSelection: () => steps.add('selection'),
    );

    // The send is cancelled first, while the network it has to say so over is
    // still up; the selection is released last, with the rest of the one-run
    // state, so the next launch does not open on files the cache sweep has
    // already deleted.
    expect(steps, [
      'send',
      'receiver',
      'discovery',
      'poller',
      'service',
      'selection',
    ]);
    // The exit is the one stop that is a real departure.
    expect(announced, isTrue);
    // Nothing of this run is carried into the next one: the badges saying who
    // left, and the finished transfers.
    expect(xvDevices.every((Device d) => d.departedAt == null), isTrue);
    expect(xvTransfers, isEmpty);
  });

  test('there is no foreground service to stop off Android', () async {
    final List<String> steps = [];
    xvDevices = [];
    xvTransfers = [];

    await shutdownForExit(
      android: false,
      cancelSend: () async => steps.add('send'),
      stopReceiver: () async => steps.add('receiver'),
      stopAdvertisement: ({bool announceLeaving = false}) async =>
          steps.add('discovery'),
      stopPolling: () => steps.add('poller'),
      stopBackgroundService: () async => steps.add('service'),
      clearSelection: () => steps.add('selection'),
    );

    expect(steps, ['send', 'receiver', 'discovery', 'poller', 'selection']);
  });

  // Telling the far end means dialling it, and a peer that has gone away takes
  // every deadline of that request in turn. The exit is an answer to a button:
  // it gives the cancel a moment and then leaves without it.
  test('a cancel that never answers does not hold the exit', () async {
    final List<String> steps = [];
    xvDevices = [];
    xvTransfers = [];

    await shutdownForExit(
      android: false,
      cancelSend: () => Future<void>.delayed(const Duration(minutes: 5)),
      stopReceiver: () async => steps.add('receiver'),
      stopAdvertisement: ({bool announceLeaving = false}) async =>
          steps.add('discovery'),
      stopPolling: () => steps.add('poller'),
      stopBackgroundService: () async => steps.add('service'),
      clearSelection: () => steps.add('selection'),
    );

    expect(steps, ['receiver', 'discovery', 'poller', 'selection']);
  }, timeout: const Timeout(Duration(seconds: 30)));

  // A cancel that throws is no reason to leave the sockets open: everything
  // after it still has to run.
  test('a cancel that throws does not stop the rest of the exit', () async {
    final List<String> steps = [];
    xvDevices = [];
    xvTransfers = [];

    await shutdownForExit(
      android: false,
      cancelSend: () async => throw const SocketException('no route'),
      stopReceiver: () async => steps.add('receiver'),
      stopAdvertisement: ({bool announceLeaving = false}) async =>
          steps.add('discovery'),
      stopPolling: () => steps.add('poller'),
      stopBackgroundService: () async => steps.add('service'),
      clearSelection: () => steps.add('selection'),
    );

    expect(steps, ['receiver', 'discovery', 'poller', 'selection']);
  });
}
