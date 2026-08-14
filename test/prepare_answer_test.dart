import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late File source;
  late HttpServer server;
  late Device peer;
  String answer = '{}';

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-answer-');
    source = File('${sandbox.path}/file.txt');
    await source.writeAsString('x');
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    xdef['Program language'] = 'en';

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      if (request.uri.path.endsWith('/prepare')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(answer);
      } else {
        // Everything after prepare is refused, so a transfer that got past it
        // still ends, and ends differently from one that never started.
        request.response.statusCode = HttpStatus.notFound;
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

  List<FileItem> batch() => [
    FileItem(
      id: 'file',
      relativePath: 'file.txt',
      size: 1,
      sourcePath: source.path,
    ),
  ];

  Future<TransferSession> sendWith(String reply) async {
    answer = reply;
    final SendService service = SendService();
    await service.send(peer: peer, files: batch());
    expect(service.busy, isFalse);
    return xvTransfers.single;
  }

  for (final (String name, String reply) in [
    ('no session id at all', '{}'),
    ('an empty session id', '{"sessionId":""}'),
    ('a session id that is not a string', '{"sessionId":42}'),
    ('a body that is not an object', '[1,2,3]'),
    ('a body that is not JSON', 'thanks'),
  ]) {
    test('an accepted prepare with $name ends the transfer', () async {
      final TransferSession transfer = await sendWith(reply);
      expect(transfer.isRunning, isFalse);
      expect(transfer.status, TransferStatus.failed);
      // Named for what went wrong, not caught by the last-resort net in send().
      expect(transfer.error, 'No session in the answer');
    });
  }

  test('a usable session id is adopted and the transfer runs on', () async {
    final TransferSession transfer = await sendWith(
      '{"sessionId":"remote-session"}',
    );
    expect(transfer.id, 'remote-session');
    expect(transfer.isRunning, isFalse);
    // What this test is about: the id was adopted, so the transfer addressed
    // its later requests to a real session. This fake refuses every one of
    // them, finish included, so the outcome is terminal — and it is a different
    // ending from a transfer that never got a session at all, which fails
    // before a single byte is read.
    expect(transfer.status, TransferStatus.failed);
    expect(transfer.files.single.failed, isTrue);
  });
}
