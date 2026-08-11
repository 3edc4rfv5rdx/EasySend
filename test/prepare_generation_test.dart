import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  Future<Reply> post(String route, {Object? body}) async {
    final HttpClientRequest req = await client.postUrl(url(route));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(json.encode(body));
    } else {
      req.contentLength = 0;
    }
    final HttpClientResponse resp = await req.close();
    final String text = await utf8.decoder.bind(resp).join();
    return (
      status: resp.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : (json.decode(text) as Map).cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> manifest(String path) => {
    'senderId': 'unknown-sender',
    'senderName': 'Stranger',
    'files': [
      {'id': 'file-1', 'path': path, 'size': 1},
    ],
  };

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-consent-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    // Nobody is trusted here, so every prepare has to go through consent.
    xvDevices = [];
    client = HttpClient();
    xdef['Port'] = '0';
    server = ReceiveServer();
    expect(await server.start(), isTrue);
    port = server.boundPort!;
    // Pinned, so a restart comes back on the same port.
    xdef['Port'] = '$port';
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    xdef['Port'] = '$defaultPort';
    await sandbox.delete(recursive: true);
  });

  test(
    'a consent answered after the server stopped installs nothing',
    () async {
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

      // The request dies with the socket; only what it leaves behind matters.
      final Future<void> parked = post(
        'prepare',
        body: manifest('late.bin'),
      ).then((_) {}, onError: (_) {});
      await asked.future;

      await server.stop();
      answer.complete(true);
      await parked;
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(xvTransfers, isEmpty);
      expect(
        await Directory(xvRecvDir)
            .list()
            .where(
              (entity) =>
                  p.basename(entity.path).startsWith(incompleteDirPrefix),
            )
            .isEmpty,
        isTrue,
      );

      // And the receiver that takes its place is free, not stuck on 'busy'.
      expect(await server.start(), isTrue);
      port = server.boundPort!;
      final Reply fresh = await post('prepare', body: manifest('fresh.bin'));
      expect(fresh.status, 200);
      expect(xvTransfers, hasLength(1));
    },
  );

  test('a prepare parked on consent keeps the slot to itself', () async {
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

    final Future<Reply> first = post('prepare', body: manifest('first.bin'));
    await asked.future;

    // Asked while the first question is still on screen: one at a time.
    expect((await post('prepare', body: manifest('second.bin'))).status, 409);

    answer.complete(true);
    expect((await first).status, 200);
    expect(xvTransfers, hasLength(1));
    expect(xvTransfers.single.status, TransferStatus.active);
  });
}
