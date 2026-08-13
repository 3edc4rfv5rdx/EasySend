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

  test('a failed transition reads as not ready and clears on the next one', () async {
    expect(await server.start(), isTrue);
    expect(server.readinessFailure, isNull);

    // Something else in the transition threw — a sweep, a discovery stop, a
    // platform channel. The listener may be up; readiness stops claiming it.
    final int ticksBefore = serverTick.value;
    server.noteTransitionFailure();
    expect(server.readinessFailure, ReceiveReadinessFailure.transition);
    expect(server.readinessError, isNotEmpty);
    expect(serverTick.value, greaterThan(ticksBefore), reason: 'UI must hear');
    // Nothing about the machine or its folders leaks into a shipped build.
    expect(server.readinessError, isNot(contains(sandbox.path)));

    await server.stop();
    expect(await server.start(), isTrue);
    expect(server.readinessFailure, isNull);
    expect(server.readinessError, isNull);
  });

  // A transition can fail with the listener still bound and still on the right
  // port, and then the next successful one takes the path that rebinds nothing.
  // That path used to clear the failure and return in silence, leaving the
  // banner up until some unrelated tick happened to repaint the screen.
  test('recovering without a rebind still reaches the screen', () async {
    expect(await server.start(), isTrue);
    // Pinned, so the next start finds the listener already where it belongs.
    xdef['Port'] = '${server.boundPort}';
    server.noteTransitionFailure();
    expect(server.readinessFailure, ReceiveReadinessFailure.transition);

    final int ticksBefore = serverTick.value;
    expect(await server.start(), isTrue);

    expect(server.readinessFailure, isNull);
    expect(server.readinessError, isNull);
    expect(
      serverTick.value,
      greaterThan(ticksBefore),
      reason: 'the banner is painted from this and has to be told',
    );
  });

  test('a start that changes nothing says nothing', () async {
    expect(await server.start(), isTrue);
    xdef['Port'] = '${server.boundPort}';
    expect(await server.start(), isTrue);

    final int ticksBefore = serverTick.value;
    expect(await server.start(), isTrue);

    expect(
      serverTick.value,
      ticksBefore,
      reason: 'every resume asks for a start; a receiver that was fine has no news',
    );
  });
}
