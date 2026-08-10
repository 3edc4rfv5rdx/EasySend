import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef Reply = ({int status, Map<String, dynamic> body});

void main() {
  late Directory sandbox;
  late ReceiveServer server;
  late HttpClient client;
  late int port;

  Uri url(String route, [Map<String, String>? query]) =>
      Uri.http('127.0.0.1:$port', '$apiPrefix/$route', query);

  Future<Reply> post(
    String route, {
    Map<String, String>? query,
    Object? body,
  }) async {
    final req = await client.postUrl(url(route, query));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(json.encode(body));
    } else {
      req.contentLength = 0;
    }
    final resp = await req.close();
    final text = await utf8.decoder.bind(resp).join();
    return (
      status: resp.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : (json.decode(text) as Map).cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> manifest(String path, {int size = 1}) => {
    'senderId': 'trusted-sender',
    'senderName': 'Sender',
    'files': [
      {'id': 'file-1', 'path': path, 'size': size},
    ],
  };

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-server-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
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
    await sandbox.delete(recursive: true);
  });

  test('only one concurrent prepare reserves the receiver', () async {
    final replies = await Future.wait([
      post('prepare', body: manifest('one.bin')),
      post('prepare', body: manifest('two.bin')),
    ]);
    expect(replies.map((r) => r.status), containsAll([200, 409]));
  });

  test(
    'rejects finish, duplicate upload and duplicate verify out of order',
    () async {
      final prepared = await post('prepare', body: manifest('file.bin'));
      final session = prepared.body['sessionId'] as String;

      final uploadReq = await client.postUrl(
        url('upload', {'session': session, 'file': 'file-1'}),
      );
      uploadReq.contentLength = 1;
      uploadReq.add([7]);
      final upload = await uploadReq.close();
      expect(upload.statusCode, 200);
      await upload.drain<void>();

      expect((await post('finish', query: {'session': session})).status, 409);
      expect(
        (await post(
          'upload',
          query: {'session': session, 'file': 'file-1'},
        )).status,
        409,
      );

      final crc = getCrc32([7]).toRadixString(16);
      expect(
        (await post(
          'verify',
          query: {'session': session, 'file': 'file-1', 'crc': crc},
        )).status,
        200,
      );
      expect(
        (await post(
          'verify',
          query: {'session': session, 'file': 'file-1', 'crc': crc},
        )).status,
        409,
      );
      expect((await post('finish', query: {'session': session})).status, 200);
      expect((await post('finish', query: {'session': session})).status, 400);
    },
  );

  test(
    'cancel during upload waits for the writer and removes the part',
    () async {
      final prepared = await post(
        'prepare',
        body: manifest('large.bin', size: 4),
      );
      final session = prepared.body['sessionId'] as String;
      final chunks = StreamController<List<int>>();
      final uploadReq = await client.postUrl(
        url('upload', {'session': session, 'file': 'file-1'}),
      );
      uploadReq.contentLength = 4;
      final uploadFuture = uploadReq
          .addStream(chunks.stream)
          .then((_) => uploadReq.close());
      chunks.add([1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final cancelFuture = post('cancel', query: {'session': session});
      chunks.add([3, 4]);
      await chunks.close();
      final cancel = await cancelFuture;
      expect(cancel.status, 200);
      try {
        final upload = await uploadFuture;
        await upload.drain<void>();
      } on HttpException {
        // The cancelled response may close the upload socket first.
      }
      expect(
        await File(p.join(xvRecvDir, 'large.bin$partSuffix')).exists(),
        isFalse,
      );
      expect(xvTransfers.single.bytesDone, lessThanOrEqualTo(4));
    },
  );
}
