import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late HttpClient client;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-recovery-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [Device(id: 'sender', name: 'Sender', trusted: true)];
    xdef['Port'] = '0';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await sandbox.delete(recursive: true);
  });

  Future<HttpClientResponse> prepare(int port, String id) async {
    final req = await client.postUrl(
      Uri.http('127.0.0.1:$port', '$apiPrefix/prepare'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      json.encode({
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': id, 'path': '$id.bin', 'size': 1},
        ],
      }),
    );
    return req.close();
  }

  test(
    'stale prepared session times out and releases the receive slot',
    () async {
      final server = ReceiveServer(
        sessionTimeout: const Duration(milliseconds: 80),
      );
      await server.start();
      final first = await prepare(server.boundPort!, 'first');
      expect(first.statusCode, 200);
      await first.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(xvTransfers.single.status, TransferStatus.failed);
      final second = await prepare(server.boundPort!, 'second');
      expect(second.statusCode, 200);
      await second.drain<void>();
      await server.stop();
    },
  );

  test(
    'startup removes only exact orphan suffixes without following links',
    () async {
      final receive = await Directory(xvRecvDir).create(recursive: true);
      final orphan = File(p.join(receive.path, 'old$partSuffix'));
      final ordinary = File(p.join(receive.path, 'keep.txt'));
      final similar = File(p.join(receive.path, 'keep${partSuffix}x'));
      await orphan.writeAsString('partial');
      await ordinary.writeAsString('user');
      await similar.writeAsString('user');

      final outside = await Directory(p.join(sandbox.path, 'outside')).create();
      final outsidePart = File(p.join(outside.path, 'outside$partSuffix'));
      await outsidePart.writeAsString('outside');
      await Link(p.join(receive.path, 'linked')).create(outside.path);

      final server = ReceiveServer();
      await server.start();
      expect(await orphan.exists(), isFalse);
      expect(await ordinary.exists(), isTrue);
      expect(await similar.exists(), isTrue);
      expect(await outsidePart.exists(), isTrue);
      await server.stop();
    },
  );
}
