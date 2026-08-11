import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late HttpServer server;
  late Device peer;
  int uploads = 0;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-changed-');
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    xdef['Program language'] = 'en';
    uploads = 0;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      if (request.uri.path.endsWith('/prepare')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessionId":"session"}');
      } else if (request.uri.path.endsWith('/upload')) {
        uploads++;
        // Refused, so a file that is allowed to be retried burns every attempt.
        request.response.statusCode = HttpStatus.badRequest;
      }
      await request.response.close();
    });
    peer = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: server.port,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await sandbox.delete(recursive: true);
  });

  Future<FileItem> pick(String name, String contents, {int? claimedSize}) async {
    final File file = File('${sandbox.path}/$name');
    await file.writeAsString(contents);
    return FileItem(
      id: name,
      relativePath: name,
      size: claimedSize ?? contents.length,
      sourcePath: file.path,
    );
  }

  test('a file that grew since it was picked is not retried', () async {
    // Picked at one byte, five bytes by the time it is sent.
    final FileItem item = await pick('grown.txt', 'xxxxx', claimedSize: 1);
    await SendService().send(peer: peer, files: [item]);

    expect(uploads, 0, reason: 'nothing should have gone on the wire');
    expect(xvTransfers.single.error, 'A file changed on disk');
    expect(item.failed, isTrue);
  });

  test('a file that disappeared is named, not retried', () async {
    final FileItem item = await pick('gone.txt', 'x');
    await File(item.sourcePath!).delete();
    await SendService().send(peer: peer, files: [item]);

    expect(uploads, 0);
    expect(xvTransfers.single.error, 'A file is no longer there');
    expect(item.failed, isTrue);
  });

  test('an unchanged file still gets its retries', () async {
    final FileItem item = await pick('steady.txt', 'x');
    await SendService().send(peer: peer, files: [item]);

    expect(uploads, maxResendAttempts + 1);
    expect(item.failed, isTrue);
  });

  test('one changed file does not hold up the rest of the queue', () async {
    final FileItem changed = await pick('changed.txt', 'yy', claimedSize: 9);
    final FileItem steady = await pick('steady.txt', 'x');
    await SendService().send(peer: peer, files: [changed, steady]);

    expect(uploads, maxResendAttempts + 1, reason: 'only the steady one tried');
    expect(changed.failed, isTrue);
    expect(steady.failed, isTrue);
    expect(xvTransfers.single.status, TransferStatus.partial);
  });
}
