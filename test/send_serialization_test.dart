import 'dart:async';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cancelled send retains ownership until its request unwinds', () async {
    final prepareSeen = Completer<void>();
    final releasePrepare = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path.endsWith('/prepare')) {
        await request.drain<void>();
        if (!prepareSeen.isCompleted) prepareSeen.complete();
        await releasePrepare.future;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessionId":"remote-session"}');
      }
      await request.response.close();
    });

    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    final peer = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: server.port,
    );
    final service = SendService();
    final directory = await Directory.systemTemp.createTemp('easysend-send-');
    final file = File('${directory.path}/file.txt');
    await file.writeAsString('x');
    final files = [
      FileItem(
        id: 'file',
        relativePath: 'file.txt',
        size: 1,
        sourcePath: file.path,
      ),
    ];

    final first = service.send(peer: peer, files: files);
    await prepareSeen.future;
    await service.cancel();
    expect(service.busy, isTrue);
    expect(await service.send(peer: peer, files: files), TransferStatus.failed);
    releasePrepare.complete();
    expect(await first, TransferStatus.cancelled);
    expect(service.busy, isFalse);
    expect(xvTransfers.single.status, TransferStatus.cancelled);

    await server.close(force: true);
    await directory.delete(recursive: true);
  });

  test('a cancel in flight still reaches the receiver', () async {
    int cancels = 0;
    final uploadSeen = Completer<void>();
    final releaseUpload = Completer<void>();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      if (path.endsWith('/prepare')) {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessionId":"remote-session"}');
      } else if (path.endsWith('/upload')) {
        if (!uploadSeen.isCompleted) uploadSeen.complete();
        // Held open so the cancel lands while the upload is still running.
        await releaseUpload.future;
      } else if (path.endsWith('/cancel')) {
        await request.drain<void>();
        cancels++;
      }
      try {
        await request.response.close();
      } catch (_) {}
    });

    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    final peer = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: server.port,
    );
    final service = SendService();
    final directory = await Directory.systemTemp.createTemp('easysend-cancel-');
    final file = File('${directory.path}/file.txt');
    await file.writeAsString('x');
    final files = [
      FileItem(
        id: 'file',
        relativePath: 'file.txt',
        size: 1,
        sourcePath: file.path,
      ),
    ];

    final sending = service.send(peer: peer, files: files);
    await uploadSeen.future;
    // cancel() force-closes the transfer's own client first, so the request
    // below can only go out over a client of its own.
    await service.cancel();
    expect(cancels, 1, reason: 'the receiver was told to drop its .part file');
    releaseUpload.complete();
    expect(await sending, TransferStatus.cancelled);

    await server.close(force: true);
    await directory.delete(recursive: true);
  });
}
