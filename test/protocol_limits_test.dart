import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

void main() {
  late Directory root;
  late ReceiveServer server;
  late HttpClient client;
  late Uri uri;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('easysend-limits-');
    xvConfigDir = p.join(root.path, 'config');
    xvRecvDir = p.join(root.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvDevices = [Device(id: 'sender', name: 'Sender', trusted: true)];
    xvTransfers = [];
    xdef['Port'] = '0';
    server = ReceiveServer();
    await server.start();
    client = HttpClient();
    uri = Uri.http('127.0.0.1:${server.boundPort}', '$apiPrefix/prepare');
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await root.delete(recursive: true);
  });

  Future<int> send(Object body, {ContentType? type}) async {
    final request = await client.postUrl(uri);
    request.headers.contentType = type ?? ContentType.json;
    request.write(json.encode(body));
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode;
  }

  Map<String, dynamic> manifest(List<Object> files) => {
    'senderId': 'sender',
    'senderName': 'Sender',
    'files': files,
  };

  test('rejects wrong content type and non-object JSON', () async {
    expect(await send({}, type: ContentType.text), 415);
    expect(await send([]), 400);
  });

  test(
    'rejects too many files and huge declared values before consent',
    () async {
      final files = List.generate(
        maxManifestFiles + 1,
        (index) => {'id': '$index', 'path': '$index.txt', 'size': 0},
      );
      expect(await send(manifest(files)), 400);
      expect(
        await send(
          manifest([
            {'id': 'x', 'path': 'x', 'size': maxDeclaredFileBytes + 1},
          ]),
        ),
        400,
      );
    },
  );

  test('rejects invalid shapes and excessive path depth', () async {
    expect(await send(manifest(['not-an-object'])), 400);
    final deep = '${List.filled(maxPathDepth + 1, 'd').join('/')}/x';
    expect(
      await send(
        manifest([
          {'id': 'x', 'path': deep, 'size': 0},
        ]),
      ),
      400,
    );
  });

  test('a full manifest of real paths fits inside the body limit', () async {
    // The two limits are coupled: raising the file count without the body cap
    // would turn a legal pick into 413 instead of a transfer.
    final List<Map<String, dynamic>> files = List.generate(
      maxManifestFiles,
      (index) => {
        'id': const Uuid().v4(),
        // Deeper and longer than what a phone's camera folder produces.
        'path':
            'Pictures/Camera Roll/2026/08/Holiday in the mountains/'
            'IMG_20260811_123456_$index.jpg',
        'size': 3456789,
      },
    );
    final int bytes = utf8.encode(json.encode(manifest(files))).length;
    expect(bytes, lessThan(maxPrepareBodyBytes));
  });

  test('bounds a chunked prepare body without Content-Length', () async {
    // Two honest endings: the 413 comes back, or the receiver drops the
    // connection while the sender is still writing. Which one depends on how
    // much of the body fits in socket buffers before the limit is hit, so both
    // count — what must never happen is the body being taken.
    int? status;
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.write('{"senderId":"sender","senderName":"');
      for (int i = 0; i <= maxPrepareBodyBytes ~/ 4096; i++) {
        request.write('x' * 4096);
      }
      final response = await request.close();
      status = response.statusCode;
      await response.drain<void>();
    } on HttpException {
      status = null;
    } on SocketException {
      status = null;
    }
    expect(status, anyOf(isNull, HttpStatus.requestEntityTooLarge));

    // And the receiver is free for the next sender either way.
    expect(
      await send(
        manifest([
          {'id': 'x', 'path': 'x.txt', 'size': 0},
        ]),
      ),
      200,
    );
  });
}
