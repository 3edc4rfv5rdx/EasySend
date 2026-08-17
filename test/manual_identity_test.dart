import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpServer server;
  late String response;
  late ManualPoller poller;
  late Device device;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    response = '{"id":"expected","name":"Peer","platform":"linux"}';
    server.listen((request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(response);
      await request.response.close();
    });
    device = Device(
      id: 'expected',
      name: 'Saved',
      address: '127.0.0.1',
      port: server.port,
      manual: true,
    );
    xvDevices = [device];
    xvDeviceId = 'self';
    poller = ManualPoller();
  });

  tearDown(() async {
    poller.stop();
    await server.close(force: true);
  });

  test('matching id marks the saved device online', () async {
    await poller.pollNow();
    expect(device.lastSeen, isNotNull);
    expect(device.name, 'Peer');
  });

  test('changed or empty id never rebinds the saved identity', () async {
    device.lastSeen = DateTime.now();
    response = '{"id":"somebody-else","name":"Other"}';
    await poller.pollNow();
    expect(device.id, 'expected');
    expect(device.name, 'Saved');
    expect(device.lastSeen, isNull);

    // An id that fails validation is not a readable identity, so it is not
    // evidence that this address belongs to somebody else either.
    response = '{"id":""}';
    expect(await poller.verifyIdentity(device), IdentityCheck.unreachable);
    expect(device.lastSeen, isNull);
  });

  test('malformed info remains offline', () async {
    response = 'not-json';
    expect(await poller.verifyIdentity(device), IdentityCheck.unreachable);
    expect(device.lastSeen, isNull);
  });

  // One boolean used to carry both, so a laptop that was merely closed told the
  // user their trust relationship had broken.
  group('the three answers are told apart', () {
    test('the device it says it is', () async {
      expect(await poller.verifyIdentity(device), IdentityCheck.confirmed);
      expect(device.lastSeen, isNotNull);
    });

    test('somebody else at the saved address', () async {
      response = '{"id":"somebody-else","name":"Other"}';
      expect(await poller.verifyIdentity(device), IdentityCheck.changed);
      expect(device.lastSeen, isNull);
    });

    test('nothing at all at the saved address', () async {
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int closed = probe.port;
      await probe.close();
      device.port = closed;

      expect(await poller.verifyIdentity(device), IdentityCheck.unreachable);
      expect(device.lastSeen, isNull);
    });
  });

  group('the send says which of the two happened', () {
    late Directory sandbox;
    late List<FileItem> batch;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-identity-');
      final File file = File('${sandbox.path}/one.bin');
      await file.writeAsBytes(const [1, 2, 3]);
      batch = [
        FileItem(
          id: 'f1',
          relativePath: 'one.bin',
          size: 3,
          sourcePath: file.path,
        ),
      ];
      xvDeviceName = 'Sender';
      xvTransfers = [];
    });

    tearDown(() => sandbox.delete(recursive: true));

    test('a different device is named as such', () async {
      response = '{"id":"somebody-else","name":"Other"}';

      expect(
        await sender.send(peer: device, files: batch),
        TransferStatus.failed,
      );
      expect(xvTransfers.single.error, 'Device identity changed');
    });

    // A trusted device found by discovery gets the same check: its address comes
    // from announces, which anybody on the subnet can forge, so who answers there
    // is confirmed before a byte goes out (ADD/tofix8.md finding 1).
    test('a trusted device found by discovery is checked too', () async {
      device.manual = false;
      device.trusted = true;
      response = '{"id":"somebody-else","name":"Other"}';

      expect(
        await sender.send(peer: device, files: batch),
        TransferStatus.failed,
      );
      expect(xvTransfers.single.error, 'Device identity changed');
    });

    // Nothing to abuse on a row that appeared moments ago and carries no trust,
    // so it is not held up by a round trip before every send.
    test('a transient discovered device is not held up by the check', () async {
      device.manual = false;
      device.trusted = false;
      response = '{"id":"somebody-else","name":"Other"}';

      // It fails later, on prepare, rather than on an identity check that never
      // ran: the fake server answers /info and nothing else.
      final TransferStatus status = await sender.send(
        peer: device,
        files: batch,
      );
      expect(status, TransferStatus.failed);
      expect(xvTransfers.single.error, isNot('Device identity changed'));
    });

    test('a device that is switched off is not called an impostor', () async {
      final ServerSocket probe = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final int closed = probe.port;
      await probe.close();
      device.port = closed;

      expect(
        await sender.send(peer: device, files: batch),
        TransferStatus.failed,
      );
      expect(xvTransfers.single.error, 'Device is offline');
    });
  });

  test('an answer outside the protocol limits leaves it offline', () async {
    device.lastSeen = DateTime.now();
    response = '{"id":"expected","name":"Peer","port":70000}';
    await poller.pollNow();
    expect(device.lastSeen, isNull);

    response = '{"id":"expected","name":"${'n' * (maxSenderNameBytes + 1)}"}';
    await poller.pollNow();
    expect(device.name, 'Saved');
    expect(device.lastSeen, isNull);
  });

  test('invalid explicit ports are rejected instead of replaced', () async {
    expect(await poller.addByAddress('127.0.0.1:not-a-port'), isFalse);
    expect(await poller.addByAddress('127.0.0.1:70000'), isFalse);
    expect(await poller.addByAddress('not-an-ip'), isFalse);
  });
}
