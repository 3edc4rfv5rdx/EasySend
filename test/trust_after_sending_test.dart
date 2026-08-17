import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

// A prepare the peer answered is the peer letting us in, and the sender writes
// that down as trust so the first file coming back is taken silently.
void main() {
  late Directory sandbox;
  late File source;
  late HttpServer server;
  late Device peer;
  int prepareStatus = HttpStatus.ok;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-trust-');
    source = File('${sandbox.path}/file.txt');
    await source.writeAsString('x');
    xvConfigDir = sandbox.path;
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    xdef = defaultSettings();
    prepareStatus = HttpStatus.ok;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      if (request.uri.path.endsWith('/prepare')) {
        request.response.statusCode = prepareStatus;
        if (prepareStatus == HttpStatus.ok) {
          request.response.headers.contentType = ContentType.json;
          request.response.write('{"sessionId":"remote-session"}');
        }
      } else {
        // Nothing past prepare has to work here: trust is decided the moment
        // the peer said yes, not by what the files then did.
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
    xvDevices = [peer];
  });

  tearDown(() async {
    await server.close(force: true);
    xvDevices = [];
    await sandbox.delete(recursive: true);
  });

  Future<void> sendOne() async {
    await SendService().send(
      peer: peer,
      files: [
        FileItem(
          id: 'file',
          relativePath: 'file.txt',
          size: 1,
          sourcePath: source.path,
        ),
      ],
    );
  }

  test('an accepted prepare marks the peer trusted', () async {
    await sendOne();
    expect(xvDevices.single.trusted, isTrue);
  });

  test('a refused prepare trusts nobody', () async {
    prepareStatus = HttpStatus.forbidden;
    await sendOne();
    expect(xvDevices.single.trusted, isFalse);
  });

  test('the switch turned off leaves trust alone', () async {
    xdef['Trust after sending'] = 'false';
    await sendOne();
    expect(xvDevices.single.trusted, isFalse);
  });

  test('a peer removed by hand mid-transfer is not put back', () async {
    // The only way out of the list is the user's own ✕, and that removal says
    // getting the device back means typing its address again. Trust nobody
    // asked for must not resurrect it.
    xvDevices = [];
    await sendOne();
    expect(xvDevices, isEmpty);
  });

  test('a second copy of the app on this machine is not remembered', () async {
    peer = Device(
      id: xvDeviceId,
      name: 'Myself',
      address: '127.0.0.1',
      port: server.port,
    );
    xvDevices = [];
    await sendOne();
    expect(xvDevices, isEmpty);
  });
}
