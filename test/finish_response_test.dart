import 'dart:async';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late File source;
  late HttpServer receiver;
  late Device peer;
  int finishStatus = HttpStatus.ok;
  String finishBody = '';
  bool oversizedFinish = false;
  bool disconnectFinish = false;
  Completer<void>? holdFinish;
  int cancels = 0;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-finish-');
    source = File('${sandbox.path}/empty.txt');
    await source.writeAsBytes(const []);
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    xdef['Program language'] = 'en';
    finishStatus = HttpStatus.ok;
    finishBody = '';
    oversizedFinish = false;
    disconnectFinish = false;
    holdFinish = null;
    cancels = 0;

    receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    receiver.listen((HttpRequest request) async {
      await request.drain<void>();
      final String path = request.uri.path;
      if (path.endsWith('/prepare')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessionId":"session"}');
      } else if (path.endsWith('/finish')) {
        if (disconnectFinish) {
          final Socket socket = await request.response.detachSocket(
            writeHeaders: false,
          );
          socket.destroy();
          return;
        }
        request.response.statusCode = finishStatus;
        if (oversizedFinish) {
          request.response.add(List<int>.filled(maxInfoBodyBytes + 1, 1));
        } else {
          request.response.write(finishBody);
        }
        if (holdFinish != null) {
          await request.response.flush();
          await holdFinish!.future;
        }
      } else if (path.endsWith('/cancel')) {
        cancels++;
      }
      try {
        await request.response.close();
      } catch (_) {}
    });
    peer = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: receiver.port,
    );
  });

  tearDown(() async {
    if (holdFinish != null && !holdFinish!.isCompleted) holdFinish!.complete();
    await receiver.close(force: true);
    await sandbox.delete(recursive: true);
  });

  FileItem item() => FileItem(
    id: 'file',
    relativePath: 'empty.txt',
    size: 0,
    sourcePath: source.path,
  );

  SendService service() => SendService(
    connectTimeout: const Duration(milliseconds: 80),
    headerTimeout: const Duration(milliseconds: 80),
    idleTimeout: const Duration(milliseconds: 80),
    prepareTimeout: const Duration(milliseconds: 120),
    controlBodyTimeout: const Duration(milliseconds: 120),
  );

  test('a successful finish is the only path to done', () async {
    expect(
      await service().send(peer: peer, files: [item()]),
      TransferStatus.done,
    );
    expect(cancels, 0);
  });

  // Terminal, not partial: every file arrived, so "partial" gave a row reading
  // "1/1, failed: 0" under a status meaning some did not make it, and no Retry
  // to offer because nothing was left to retry.
  test('a rejected finish is terminal, logged, cleaned and reusable', () async {
    finishStatus = HttpStatus.conflict;
    finishBody = '{"reason":"busy"}';
    final SendService sender = service();
    expect(
      await sender.send(peer: peer, files: [item()]),
      TransferStatus.failed,
    );
    expect(sender.busy, isFalse);
    expect(cancels, 1);
    // The row shows this instead of a count that contradicts its own status.
    expect(xvTransfers.single.error, 'HTTP 409');
    expect(xvTransfers.single.failedCount, 0, reason: 'the file did arrive');
    expect(
      xvTransfers.single.events.map(formatTransferEvent).join('\n'),
      contains('HTTP 409: {"reason":"busy"}'),
    );

    finishStatus = HttpStatus.ok;
    finishBody = '';
    expect(await sender.send(peer: peer, files: [item()]), TransferStatus.done);
  });

  test('a finish body timeout is terminal and attempts cleanup', () async {
    holdFinish = Completer<void>();
    finishBody = 'still-open';
    expect(
      await service().send(peer: peer, files: [item()]),
      TransferStatus.failed,
    );
    expect(xvTransfers.single.error, isNotNull);
    expect(cancels, 1);
  });

  test('disconnect and oversized finish bodies cannot produce done', () async {
    disconnectFinish = true;
    expect(
      await service().send(peer: peer, files: [item()]),
      TransferStatus.failed,
    );
    expect(cancels, 1);

    disconnectFinish = false;
    oversizedFinish = true;
    expect(
      await service().send(peer: peer, files: [item()]),
      TransferStatus.failed,
    );
    expect(cancels, 2);
  });
}
