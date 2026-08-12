import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late ReceiveServer server;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-readiness-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvTransfers = [];
    xdef['Port'] = '0';
    server = ReceiveServer();
  });

  tearDown(() async {
    await server.stop();
    xdef['Port'] = '$defaultPort';
    await sandbox.delete(recursive: true);
  });

  test('an unusable receive root prevents listening and recovers', () async {
    final File blocker = File(xvRecvDir);
    await blocker.writeAsString('not a directory');

    expect(await server.start(), isFalse);
    expect(server.running, isFalse);
    expect(server.readinessFailure, ReceiveReadinessFailure.folder);

    await blocker.delete();
    expect(await server.start(), isTrue);
    expect(server.running, isTrue);
    expect(server.readinessFailure, isNull);
  });

  test('a folder lost after bind stops the advertised listener', () async {
    expect(await server.start(), isTrue);
    expect(server.running, isTrue);

    await Directory(xvRecvDir).delete(recursive: true);
    await File(xvRecvDir).writeAsString('not a directory');

    expect(await server.start(), isFalse);
    expect(server.running, isFalse);
    expect(server.readinessFailure, ReceiveReadinessFailure.folder);
  });

  test('an occupied port is distinguished and recovers', () async {
    final ServerSocket occupied = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    xdef['Port'] = '${occupied.port}';

    expect(await server.start(), isFalse);
    expect(server.running, isFalse);
    expect(server.readinessFailure, ReceiveReadinessFailure.port);
    expect(server.readinessError, isNotEmpty);

    await occupied.close();
    expect(await server.start(), isTrue);
    expect(server.readinessFailure, isNull);
  });
}
