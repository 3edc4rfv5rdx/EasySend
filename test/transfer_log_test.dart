import 'dart:convert';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

TransferSession session({bool incoming = true, int files = 1}) =>
    TransferSession(
      id: 'session',
      incoming: incoming,
      peerName: 'Peer',
      files: [
        for (int i = 0; i < files; i++)
          FileItem(id: 'f$i', relativePath: 'file$i.bin', size: 10),
      ],
    );

void main() {
  test('a line carries the file, the message and the untranslated detail', () {
    final TransferSession transfer = session();
    transfer.log(
      'Size does not match',
      file: 'photo.jpg',
      detail: '7 / 10',
      failure: true,
    );

    final TransferEvent event = transfer.events.single;
    expect(event.failure, isTrue);
    final String line = formatTransferEvent(event);
    expect(line, contains('photo.jpg'));
    expect(line, contains('Size does not match'));
    expect(line, endsWith(': 7 / 10'));
    expect(line, startsWith(formatClock(event.at)));
  });

  test('the log keeps its last lines and drops the quiet ones', () {
    final TransferSession transfer = session();
    for (int i = 0; i < maxTransferEvents + 20; i++) {
      transfer.log('Sent', file: 'file$i.bin', routine: true);
    }

    expect(transfer.events.length, maxTransferEvents);
    expect(transfer.events.first.file, 'file20.bin');
    expect(transfer.events.last.file, 'file${maxTransferEvents + 19}.bin');
    expect(transfer.quietFiles, 20);
  });

  // The whole point of the log is the file that did not make it. A transfer of
  // three thousand ordinary files must not be able to push it out.
  test('a flood of quiet lines never drops a failure', () {
    final TransferSession transfer = session();
    transfer.log('Not sent', file: 'early.bin', failure: true);
    for (int i = 0; i < maxTransferEvents * 6; i++) {
      transfer.log('Sent', file: 'file$i.bin', routine: true);
    }
    transfer.log('Deleted here', file: 'early.bin');

    expect(transfer.events.length, maxTransferEvents);
    expect(transfer.events.first.file, 'early.bin');
    expect(transfer.events.first.failure, isTrue);
    // Not a failure, but it says a source file was removed — never dropped.
    expect(transfer.events.last.message, 'Deleted here');
    expect(transfer.quietFiles, maxTransferEvents * 6 + 2 - maxTransferEvents);
  });

  test('a log of nothing but failures still drops its oldest', () {
    final TransferSession transfer = session();
    for (int i = 0; i < maxTransferEvents + 5; i++) {
      transfer.log('Not sent', file: 'file$i.bin', failure: true);
    }

    expect(transfer.events.length, maxTransferEvents);
    expect(transfer.events.first.file, 'file5.bin');
    expect(transfer.quietFiles, 0, reason: 'no quiet line was there to give up');
  });

  test('a trimmed log accounts for the files it stopped naming', () {
    final TransferSession transfer = session();
    expect(quietFilesLine(transfer), isNull);
    for (int i = 0; i < maxTransferEvents + 7; i++) {
      transfer.log('Received', file: 'file$i.bin', routine: true);
    }

    expect(quietFilesLine(transfer), endsWith(': 7'));
    expect(transferLogText(transfer).split('\n').last, quietFilesLine(transfer));
  });

  test('copied text starts with the build and repeats the header', () {
    xvPlatform = 'linux';
    final TransferSession transfer = session(files: 2);
    transfer.files.first.done = true;
    transfer.error = 'Connection refused';
    transfer.log('Received', file: 'file0.bin');

    final List<String> lines = transferLogText(transfer).split('\n');
    expect(lines.first, '$prgName $progVersion+$buildNumber linux');
    expect(lines, containsAll(transferLogHeader(transfer)));
    expect(lines.last, formatTransferEvent(transfer.events.single));
    expect(transferLogHeader(transfer).last, contains('Connection refused'));
  });

  group('the receiver writes down what happened to each file', () {
    late Directory sandbox;
    late ReceiveServer server;
    late HttpClient client;
    late int port;

    Uri url(String route, [Map<String, String>? query]) =>
        Uri.http('127.0.0.1:$port', '$apiPrefix/$route', query);

    Future<int> post(String route, {Map<String, String>? query}) async {
      final HttpClientRequest req = await client.postUrl(url(route, query));
      req.contentLength = 0;
      final HttpClientResponse resp = await req.close();
      await resp.drain<void>();
      return resp.statusCode;
    }

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-log-');
      xvConfigDir = p.join(sandbox.path, 'config');
      xvRecvDir = p.join(sandbox.path, 'receive');
      xvDeviceId = 'receiver';
      xvDeviceName = 'Receiver';
      xvPlatform = 'linux';
      xvTransfers = [];
      xvDevices = [Device(id: 'sender', name: 'Sender', trusted: true)];
      xdef['Port'] = '0';
      client = HttpClient();
      server = ReceiveServer();
      expect(await server.start(), isTrue);
      port = server.boundPort!;
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
      await sandbox.delete(recursive: true);
    });

    test('a checksum that does not match names the file it belongs to', () async {
      final HttpClientRequest prepare = await client.postUrl(url('prepare'));
      prepare.headers.contentType = ContentType.json;
      prepare.write(
        json.encode({
          'senderId': 'sender',
          'senderName': 'Sender',
          'files': [
            {'id': 'file-1', 'path': 'good.bin', 'size': 1},
            {'id': 'file-2', 'path': 'never.bin', 'size': 1},
          ],
        }),
      );
      final HttpClientResponse answer = await prepare.close();
      final Map<String, dynamic> body =
          (json.decode(await utf8.decoder.bind(answer).join()) as Map)
              .cast<String, dynamic>();
      final String id = body['sessionId'] as String;

      final HttpClientRequest upload = await client.postUrl(
        url('upload', {'session': id, 'file': 'file-1'}),
      );
      upload.contentLength = 1;
      upload.add([7]);
      await (await upload.close()).drain<void>();

      expect(
        await post(
          'verify',
          query: {'session': id, 'file': 'file-1', 'crc': 'dead'},
        ),
        409,
      );
      expect(await post('finish', query: {'session': id}), 200);

      final TransferSession transfer = xvTransfers.single;
      final List<String> lines = transfer.events
          .map(formatTransferEvent)
          .toList();
      // The row can only say "received 0 of 2"; these two lines are the whole
      // reason to have a log at all.
      expect(
        lines.where((l) => l.contains('good.bin')),
        contains(allOf(contains('Checksum did not match'))),
      );
      expect(
        lines.where((l) => l.contains('never.bin')),
        contains(allOf(contains('Not received'))),
      );
      expect(transfer.events.every((e) => e.failure), isTrue);
    });
  });
}
