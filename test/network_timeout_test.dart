import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:easysend/net_sender.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('sender times out a prepare that never returns headers', () async {
    final blocker = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      await request.drain<void>();
      await blocker.future;
    });
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    final service = SendService(
      connectTimeout: const Duration(milliseconds: 100),
      headerTimeout: const Duration(milliseconds: 100),
      idleTimeout: const Duration(milliseconds: 100),
      prepareTimeout: const Duration(milliseconds: 120),
    );
    final status = await service.send(
      peer: Device(
        id: 'peer',
        name: 'Peer',
        address: '127.0.0.1',
        port: server.port,
      ),
      files: [FileItem(id: 'file', relativePath: 'file.txt', size: 0)],
    );
    expect(status, TransferStatus.failed);
    expect(xvTransfers.single.error, contains('timed out'));
    blocker.complete();
    await server.close(force: true);
  });

  test('manual info body timeout and overlap guard bound polling', () async {
    int requests = 0;
    final release = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"id":"peer"}');
      await request.response.flush();
      await release.future;
      await request.response.close();
    });
    final device = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: server.port,
      manual: true,
    );
    xvDevices = [device];
    final poller = ManualPoller(timeout: const Duration(milliseconds: 100));
    final first = poller.pollNow();
    final second = poller.pollNow();
    await second;
    await first;
    expect(requests, 1);
    expect(device.lastSeen, isNull);
    release.complete();
    await server.close(force: true);
  });

  test('an error body that never ends does not wedge the poller', () async {
    final Completer<void> release = Completer<void>();
    final HttpServer stuck = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    stuck.listen((HttpRequest request) async {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('sorry');
      await request.response.flush();
      // Never closed until the test lets go.
      await release.future;
      await request.response.close();
    });

    final HttpServer healthy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    healthy.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"id":"good","name":"Good"}');
      await request.response.close();
    });

    final Device dead = Device(
      id: 'stuck',
      name: 'Stuck',
      address: '127.0.0.1',
      port: stuck.port,
      manual: true,
    );
    final Device alive = Device(
      id: 'good',
      name: 'Good',
      address: '127.0.0.1',
      port: healthy.port,
      manual: true,
    );
    xvDevices = [dead, alive];

    final ManualPoller poller = ManualPoller(
      timeout: const Duration(milliseconds: 100),
    );
    await poller.pollNow().timeout(const Duration(seconds: 5));
    expect(poller.polling, isFalse);
    // The device behind the stuck one is still reached in the same pass.
    expect(alive.lastSeen, isNotNull);
    expect(dead.lastSeen, isNull);

    // And the poller keeps working afterwards.
    alive.lastSeen = null;
    await poller.pollNow().timeout(const Duration(seconds: 5));
    expect(alive.lastSeen, isNotNull);

    release.complete();
    await stuck.close(force: true);
    await healthy.close(force: true);
  });

  test('receiver aborts a stalled upload and removes its part file', () async {
    final root = await Directory.systemTemp.createTemp('easysend-idle-');
    xvConfigDir = p.join(root.path, 'config');
    xvRecvDir = p.join(root.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [Device(id: 'sender', name: 'Sender', trusted: true)];
    xdef['Port'] = '0';
    final server = ReceiveServer(
      uploadIdleTimeout: const Duration(milliseconds: 80),
    );
    await server.start();
    final client = HttpClient();
    final prepare = await client.postUrl(
      Uri.http('127.0.0.1:${server.boundPort}', '$apiPrefix/prepare'),
    );
    prepare.headers.contentType = ContentType.json;
    prepare.write(
      json.encode({
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': 'file', 'path': 'file.bin', 'size': 2},
        ],
      }),
    );
    final prepared = await prepare.close();
    final body = json.decode(await utf8.decoder.bind(prepared).join());
    final session = body['sessionId'] as String;

    final socket = await Socket.connect('127.0.0.1', server.boundPort!);
    socket.write(
      'POST $apiPrefix/upload?session=$session&file=file HTTP/1.1\r\n'
      'Host: 127.0.0.1\r\nContent-Length: 2\r\nConnection: close\r\n\r\nA',
    );
    await socket.flush();
    // HttpServer may close a connection whose declared request body never
    // arrived before the 408 bytes can be delivered; either outcome must end.
    await utf8.decoder.bind(socket).join();
    for (int i = 0; i < 10; i++) {
      if (!await File(p.join(xvRecvDir, 'file.bin$partSuffix')).exists()) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(
      await File(p.join(xvRecvDir, 'file.bin$partSuffix')).exists(),
      isFalse,
    );

    client.close(force: true);
    await server.stop();
    await root.delete(recursive: true);
  });
}
