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
}
