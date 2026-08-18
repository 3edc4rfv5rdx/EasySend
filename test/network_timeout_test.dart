import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:easysend/control_body.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:easysend/net_sender.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('total deadline cancels a drip-fed control body', () async {
    bool cancelled = false;
    final StreamController<List<int>> drip = StreamController<List<int>>(
      onCancel: () => cancelled = true,
    );
    final Timer feed = Timer.periodic(
      const Duration(milliseconds: 35),
      (_) => drip.add([1]),
    );

    await expectLater(
      readBoundedControlBytes(
        drip.stream,
        limit: 100,
        inactivityTimeout: const Duration(milliseconds: 100),
        totalTimeout: const Duration(milliseconds: 140),
        tooLarge: () => StateError('large'),
        inactivityExpired: () => StateError('idle'),
        totalExpired: () => TimeoutException('total'),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(cancelled, isTrue);
    feed.cancel();
    await drip.close();

    expect(
      await readBoundedControlBytes(
        Stream<List<int>>.value([1, 2, 3]),
        limit: 3,
        inactivityTimeout: const Duration(milliseconds: 100),
        totalTimeout: const Duration(milliseconds: 140),
        tooLarge: () => StateError('large'),
        inactivityExpired: () => StateError('idle'),
        totalExpired: () => TimeoutException('total'),
      ),
      [1, 2, 3],
    );
  });

  test('sender total deadline releases a drip-fed response', () async {
    int requests = 0;
    final HttpServer receiver = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    receiver.listen((HttpRequest request) async {
      requests++;
      await request.drain<void>();
      if (requests > 1) {
        request.response.statusCode = HttpStatus.forbidden;
        await request.response.close();
        return;
      }
      request.response.headers.contentType = ContentType.json;
      for (final int byte in utf8.encode('{"sessionId":"slow"}')) {
        try {
          request.response.add([byte]);
          await request.response.flush();
        } catch (_) {
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 35));
      }
      await request.response.close();
    });
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    final SendService service = SendService(
      connectTimeout: const Duration(milliseconds: 100),
      headerTimeout: const Duration(milliseconds: 100),
      idleTimeout: const Duration(milliseconds: 100),
      prepareTimeout: const Duration(milliseconds: 200),
      controlBodyTimeout: const Duration(milliseconds: 140),
    );
    final Device peer = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: receiver.port,
    );

    expect(
      await service.send(
        peer: peer,
        files: [FileItem(id: 'one', relativePath: 'one.txt', size: 0)],
      ),
      TransferStatus.failed,
    );
    expect(service.busy, isFalse);
    expect(
      await service.send(
        peer: peer,
        files: [FileItem(id: 'two', relativePath: 'two.txt', size: 0)],
      ),
      TransferStatus.cancelled,
    );
    expect(requests, 2);

    await receiver.close(force: true);
  });

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

  test('an oversized info body is dropped, not taken as an answer', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    server.listen((HttpRequest request) async {
      // Valid JSON, so size is the only reason to turn it down.
      final String padding = 'x' * maxInfoBodyBytes;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"id":"peer","name":"$padding"}');
      await request.response.close();
    });
    final Device device = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: server.port,
      manual: true,
    );
    xvDevices = [device];
    final ManualPoller poller = ManualPoller(
      timeout: const Duration(milliseconds: 200),
    );
    await poller.pollNow().timeout(const Duration(seconds: 5));
    expect(device.lastSeen, isNull);
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

  test('one pass reaches every manual device at once', () async {
    const Duration pollTimeout = Duration(milliseconds: 100);
    final Completer<void> release = Completer<void>();
    final HttpServer silent = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    silent.listen((HttpRequest request) async {
      // Answers nothing: what a device that is switched off looks like once
      // something else has taken its address.
      await release.future;
      await request.response.close();
    });

    final HttpServer healthy = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    healthy.listen((HttpRequest request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"id":"alive","name":"Alive"}');
      await request.response.close();
    });

    final List<Device> dead = [
      for (int i = 0; i < 4; i++)
        Device(
          id: 'dead-$i',
          name: 'Dead $i',
          address: '127.0.0.1',
          port: silent.port,
          manual: true,
        ),
    ];
    final Device alive = Device(
      id: 'alive',
      name: 'Alive',
      address: '127.0.0.1',
      port: healthy.port,
      manual: true,
    );
    // Last in the list: the one that used to pay for everyone ahead of it.
    xvDevices = [...dead, alive];

    final ManualPoller poller = ManualPoller(timeout: pollTimeout);
    final Stopwatch watch = Stopwatch()..start();
    await poller.pollNow().timeout(const Duration(seconds: 5));

    // Measured on this harness: one after another costs 410 ms for these four,
    // all at once costs 104 ms. The threshold is the sequential lower bound.
    expect(
      watch.elapsedMilliseconds,
      lessThan(dead.length * pollTimeout.inMilliseconds),
      reason: 'a pass still costs one timeout per silent device',
    );
    expect(alive.lastSeen, isNotNull);
    for (final Device device in dead) {
      expect(device.lastSeen, isNull);
    }

    release.complete();
    await silent.close(force: true);
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
    final incomplete = File(incompleteFilePath(xvRecvDir, session, 0));
    for (int i = 0; i < 10; i++) {
      if (!await incomplete.exists()) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await incomplete.exists(), isFalse);

    client.close(force: true);
    await server.stop();
    await root.delete(recursive: true);
  });
}
