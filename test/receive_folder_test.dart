import 'dart:async';
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

  // What the settings screen asks before letting the folder move. The transfer
  // list cannot answer it: a request still waiting to be accepted has resolved
  // every one of its destinations already and appears in no list yet.
  group('the receive slot is held from the request, not from the first byte', () {
    test('an idle receiver holds nothing', () {
      expect(server.receiveSlotHeld, isFalse);
    });

    test('a prepare waiting for consent holds the slot', () async {
      xvDevices = [Device(id: 'stranger', name: 'Stranger')];
      final Completer<void> asked = Completer<void>();
      final Completer<bool> answer = Completer<bool>();
      server.askUser =
          ({
            required String senderName,
            required int fileCount,
            required int totalBytes,
          }) async {
            if (!asked.isCompleted) asked.complete();
            return (await answer.future, false);
          };

      final HttpClientRequest req = await client.postUrl(url('prepare'));
      req.headers.contentType = ContentType.json;
      req.write(
        json.encode({
          'senderId': 'stranger',
          'senderName': 'Stranger',
          'files': [
            {'id': 'file-9', 'path': 'asked.bin', 'size': 2},
          ],
        }),
      );
      final Future<HttpClientResponse> parked = req.close();
      await asked.future;

      expect(server.receiveSlotHeld, isTrue);
      expect(
        xvTransfers,
        isEmpty,
        reason: 'nothing in the list yet, which is the whole point',
      );

      answer.complete(false);
      final HttpClientResponse resp = await parked;
      await resp.drain<void>();
      expect(resp.statusCode, 403);
      expect(server.receiveSlotHeld, isFalse, reason: 'a refusal frees it');
    });

    test('an accepted session holds it until it finishes', () async {
      final String session = await prepare('held.bin', 'file-3');
      expect(server.receiveSlotHeld, isTrue);

      await deliver(session, 'file-3');
      expect(server.receiveSlotHeld, isFalse);
    });
  });

  test('canWriteInto tells a usable folder from an unusable one', () async {
    expect(await canWriteInto(folderA), isTrue);
    expect(await File(p.join(folderA, 'kept.bin')).exists(), isFalse);

    final File blocker = File(p.join(sandbox.path, 'not-a-folder'));
    await blocker.writeAsString('x');
    expect(await canWriteInto(blocker.path), isFalse);
  });
}
