import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory sandbox;
  late HttpClient client;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-recovery-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [Device(id: 'sender', name: 'Sender', trusted: true)];
    xdef['Port'] = '0';
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await sandbox.delete(recursive: true);
  });

  Future<HttpClientResponse> prepare(
    int port,
    String id, {
    String? path,
  }) async {
    final req = await client.postUrl(
      Uri.http('127.0.0.1:$port', '$apiPrefix/prepare'),
    );
    req.headers.contentType = ContentType.json;
    req.write(
      json.encode({
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': id, 'path': path ?? '$id.bin', 'size': 1},
        ],
      }),
    );
    return req.close();
  }

  test(
    'stale prepared session times out and releases the receive slot',
    () async {
      final server = ReceiveServer(
        sessionTimeout: const Duration(milliseconds: 80),
      );
      await server.start();
      final first = await prepare(server.boundPort!, 'first');
      expect(first.statusCode, 200);
      await first.drain<void>();
      await Future<void>.delayed(const Duration(milliseconds: 180));
      expect(xvTransfers.single.status, TransferStatus.failed);
      final second = await prepare(server.boundPort!, 'second');
      expect(second.statusCode, 200);
      await second.drain<void>();
      await server.stop();
    },
  );

  test('startup removes only owned incomplete sessions', () async {
    final receive = await Directory(xvRecvDir).create(recursive: true);
    final legitimate = File(p.join(receive.path, 'old.easysend-part'));
    final ordinary = File(p.join(receive.path, 'keep.txt'));
    await legitimate.writeAsString('verified user file');
    await ordinary.writeAsString('user');

    final root = (await resolveReceiveRoot(receive.path))!;
    expect(
      await ensureIncompleteSessionDirectory(
        receive.path,
        'owned',
        resolvedRoot: root,
      ),
      isTrue,
    );
    final orphan = File(incompleteFilePath(receive.path, 'owned', 0));
    await orphan.writeAsString('partial');

    // Exactly what a receiver writes for itself, arriving as a transfer: the
    // prefix, the marker file, the marker's contents. It is user data.
    Future<File> forgery(String directory) async {
      await Directory(directory).create(recursive: true);
      await File(
        p.join(directory, '.owner'),
      ).writeAsString('EasySend incomplete transfer v1\n');
      final File carried = File(p.join(directory, 'keep.txt'));
      await carried.writeAsString('user');
      return carried;
    }

    final lookalike = await forgery(
      p.join(receive.path, '${incompleteDirPrefix}user-data'),
    );
    final nested = await forgery(
      p.join(receive.path, 'album', '${incompleteDirPrefix}nested'),
    );
    final doubled = await forgery(
      p.join(receive.path, '$incompleteDirPrefix$incompleteDirPrefix-twice'),
    );

    final outside = await Directory(p.join(sandbox.path, 'outside')).create();
    final outsidePart = File(p.join(outside.path, 'outside.part'));
    await outsidePart.writeAsString('outside');
    await Link(
      p.join(receive.path, '${incompleteDirPrefix}linked'),
    ).create(outside.path);

    await cleanupOrphanSessions();
    expect(await orphan.exists(), isFalse);
    expect(await legitimate.exists(), isTrue);
    expect(await ordinary.exists(), isTrue);
    expect(await lookalike.readAsString(), 'user');
    expect(await nested.readAsString(), 'user');
    expect(await doubled.readAsString(), 'user');
    expect(await outsidePart.exists(), isTrue);
  });

  test('a leftover is swept after the receive folder moved on', () async {
    final abandoned = await Directory(
      p.join(sandbox.path, 'old-receive'),
    ).create(recursive: true);
    final root = (await resolveReceiveRoot(abandoned.path))!;
    expect(
      await ensureIncompleteSessionDirectory(
        abandoned.path,
        'stranded',
        resolvedRoot: root,
      ),
      isTrue,
    );
    final File orphan = File(incompleteFilePath(abandoned.path, 'stranded', 0));
    await orphan.writeAsString('partial');

    // The user pointed the app at another folder; the crash leftover is still
    // ours and its record still says where it is.
    xvRecvDir = p.join(sandbox.path, 'new-receive');
    await Directory(xvRecvDir).create(recursive: true);

    await cleanupOrphanSessions();
    expect(await orphan.exists(), isFalse);
    expect(await Directory(p.dirname(orphan.path)).exists(), isFalse);
    expect(
      Directory(p.join(xvConfigDir, 'incomplete-sessions')).listSync(),
      isEmpty,
      reason: 'a swept session must not leave its ownership record behind',
    );
  });

  test(
    'verified names ending in the legacy part suffix survive cleanup',
    () async {
      final server = ReceiveServer();
      await server.start();
      final prepared = await prepare(
        server.boundPort!,
        'suffix',
        path: 'report.easysend-part',
      );
      final body = json.decode(await utf8.decoder.bind(prepared).join());
      final session = body['sessionId'] as String;

      final upload = await client.postUrl(
        Uri.http('127.0.0.1:${server.boundPort}', '$apiPrefix/upload', {
          'session': session,
          'file': 'suffix',
        }),
      );
      upload.add([7]);
      final uploaded = await upload.close();
      expect(uploaded.statusCode, 200);
      await uploaded.drain<void>();

      final verify = await client.postUrl(
        Uri.http('127.0.0.1:${server.boundPort}', '$apiPrefix/verify', {
          'session': session,
          'file': 'suffix',
          'crc': getCrc32([7]).toRadixString(16),
        }),
      );
      final verified = await verify.close();
      expect(verified.statusCode, 200);
      await verified.drain<void>();
      await server.stop();

      final received = File(p.join(xvRecvDir, 'report.easysend-part'));
      expect(await received.readAsBytes(), [7]);
      expect(
        Directory(p.join(xvConfigDir, 'incomplete-sessions')).listSync(),
        isEmpty,
        reason: 'a finished session releases its ownership record',
      );
      await cleanupOrphanSessions();
      expect(await received.readAsBytes(), [7]);
    },
  );

  test('the sweep is a startup job, not a server one', () async {
    final receive = await Directory(xvRecvDir).create(recursive: true);
    final root = (await resolveReceiveRoot(receive.path))!;
    await ensureIncompleteSessionDirectory(
      receive.path,
      'first',
      resolvedRoot: root,
    );
    final File first = File(incompleteFilePath(receive.path, 'first', 0));
    await first.writeAsString('partial');

    await sweepOrphanSessionsOnce();
    expect(await first.exists(), isFalse);

    // A later start must not walk the whole folder again — on a phone that is
    // the user's Downloads, and it happened on every return to the screen.
    await ensureIncompleteSessionDirectory(
      receive.path,
      'later',
      resolvedRoot: root,
    );
    final File later = File(incompleteFilePath(receive.path, 'later', 0));
    await later.writeAsString('partial');
    await sweepOrphanSessionsOnce();
    expect(await later.exists(), isTrue);

    final server = ReceiveServer();
    expect(await server.start(), isTrue);
    expect(await later.exists(), isTrue, reason: 'start() must not sweep');
    await server.stop();
    await later.delete();
  });
}
