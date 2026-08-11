import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late ReceiveServer server;
  late HttpClient client;
  late int port;
  late String folderA;
  late String folderB;

  Uri url(String route, [Map<String, String>? query]) =>
      Uri.http('127.0.0.1:$port', '$apiPrefix/$route', query);

  Future<int> post(String route, {Map<String, String>? query}) async {
    final HttpClientRequest req = await client.postUrl(url(route, query));
    req.contentLength = 0;
    final HttpClientResponse resp = await req.close();
    await resp.drain<void>();
    return resp.statusCode;
  }

  Future<String> prepare(String path, String fileId) async {
    final HttpClientRequest req = await client.postUrl(url('prepare'));
    req.headers.contentType = ContentType.json;
    req.write(
      json.encode({
        'senderId': 'trusted-sender',
        'senderName': 'Sender',
        'files': [
          {'id': fileId, 'path': path, 'size': 2},
        ],
      }),
    );
    final HttpClientResponse resp = await req.close();
    final String text = await utf8.decoder.bind(resp).join();
    expect(resp.statusCode, 200);
    return ((json.decode(text) as Map).cast<String, dynamic>())['sessionId']
        as String;
  }

  Future<void> deliver(String session, String fileId) async {
    final HttpClientRequest upload = await client.postUrl(
      url('upload', {'session': session, 'file': fileId}),
    );
    upload.contentLength = 2;
    upload.add([9, 9]);
    final HttpClientResponse uploaded = await upload.close();
    await uploaded.drain<void>();
    expect(uploaded.statusCode, 200);
    expect(
      await post(
        'verify',
        query: {
          'session': session,
          'file': fileId,
          'crc': getCrc32([9, 9]).toRadixString(16),
        },
      ),
      200,
    );
    expect(await post('finish', query: {'session': session}), 200);
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-folder-');
    folderA = p.join(sandbox.path, 'first');
    folderB = p.join(sandbox.path, 'second');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = folderA;
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [Device(id: 'trusted-sender', name: 'Sender', trusted: true)];
    xdef['Port'] = '0';
    client = HttpClient();
    server = ReceiveServer();
    expect(await server.start(), isTrue);
    port = server.boundPort!;
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    xdef['Port'] = '$defaultPort';
    xvRecvDir = '';
    await sandbox.delete(recursive: true);
  });

  test('a session finishes in the folder it was prepared for', () async {
    final String session = await prepare('kept.bin', 'file-1');

    // Settings move the receive folder while the transfer is already planned.
    xvRecvDir = folderB;
    await deliver(session, 'file-1');

    expect(await File(p.join(folderA, 'kept.bin')).exists(), isTrue);
    expect(await File(p.join(folderB, 'kept.bin')).exists(), isFalse);
    expect(xvTransfers.single.status, TransferStatus.done);
  });

  test('the next session uses the new folder', () async {
    xvRecvDir = folderB;
    final String session = await prepare('later.bin', 'file-2');
    await deliver(session, 'file-2');

    expect(await File(p.join(folderB, 'later.bin')).exists(), isTrue);
    expect(await File(p.join(folderA, 'later.bin')).exists(), isFalse);
  });

  test('canWriteInto tells a usable folder from an unusable one', () async {
    expect(await canWriteInto(folderA), isTrue);
    expect(await File(p.join(folderA, 'kept.bin')).exists(), isFalse);

    final File blocker = File(p.join(sandbox.path, 'not-a-folder'));
    await blocker.writeAsString('x');
    expect(await canWriteInto(blocker.path), isFalse);
  });
}
