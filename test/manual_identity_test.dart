import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
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

    response = '{"id":""}';
    expect(await poller.verifyIdentity(device), isFalse);
    expect(device.lastSeen, isNull);
  });

  test('malformed info remains offline', () async {
    response = 'not-json';
    expect(await poller.verifyIdentity(device), isFalse);
    expect(device.lastSeen, isNull);
  });

  test('invalid explicit ports are rejected instead of replaced', () async {
    expect(await poller.addByAddress('127.0.0.1:not-a-port'), isFalse);
    expect(await poller.addByAddress('127.0.0.1:70000'), isFalse);
    expect(await poller.addByAddress('not-an-ip'), isFalse);
  });
}
