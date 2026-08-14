import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef Reply = ({int status, Map<String, dynamic> body});

// A receive stopped on the receiving device, and what the sender makes of it.
//
// Nothing is sent to the sender when the user stops a receive: it finds out by
// being refused. That refusal used to be a bare 400, which reads like a bad
// request, so the sender retried each file three times and walked the whole
// manifest into the same wall — nine thousand round trips for a folder of three
// thousand, with the row still claiming to be running (ADD/tofix6.md #3).
void main() {
  group('the receiver says the session is gone', () {
    late Directory sandbox;
    late ReceiveServer server;
    late HttpClient client;
    late int port;

    Uri url(String route, [Map<String, String>? query]) =>
        Uri.http('127.0.0.1:$port', '$apiPrefix/$route', query);

    Future<Reply> read(HttpClientResponse resp) async {
      final String text = await utf8.decoder.bind(resp).join();
      return (
        status: resp.statusCode,
        body: text.isEmpty
            ? <String, dynamic>{}
            : (json.decode(text) as Map).cast<String, dynamic>(),
      );
    }

    Future<Reply> post(
      String route, {
      Map<String, String>? query,
      Object? body,
    }) async {
      final HttpClientRequest req = await client.postUrl(url(route, query));
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(json.encode(body));
      } else {
        req.contentLength = 0;
      }
      return read(await req.close());
    }

    Future<Reply> upload(String session, String file, List<int> data) async {
      final HttpClientRequest req = await client.postUrl(
        url('upload', {'session': session, 'file': file}),
      );
      req.contentLength = data.length;
      req.add(data);
      return read(await req.close());
    }

    Map<String, dynamic> manifest(List<String> paths) => {
      'senderId': 'trusted-sender',
      'senderName': 'Sender',
      'files': [
        for (int i = 0; i < paths.length; i++)
          {'id': 'file-$i', 'path': paths[i], 'size': 1},
      ],
    };

    Future<String> prepare(List<String> paths) async {
      final Reply prepared = await post('prepare', body: manifest(paths));
      expect(prepared.status, 200);
      return prepared.body['sessionId'] as String;
    }

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-gone-');
      xvConfigDir = p.join(sandbox.path, 'config');
      xvRecvDir = p.join(sandbox.path, 'receive');
      xvDeviceId = 'receiver';
      xvDeviceName = 'Receiver';
      xvPlatform = 'linux';
      xvTransfers = [];
      xvDevices = [Device(id: 'trusted-sender', name: 'Sender', trusted: true)];
      xdef['Port'] = '0';
      xdef['Program language'] = 'en';
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

    test('a receive stopped here answers every later request', () async {
      final String session = await prepare(['a.bin', 'b.bin', 'c.bin']);
      expect((await upload(session, 'file-0', [7])).status, 200);

      await server.cancelCurrent();

      for (final Reply reply in [
        await upload(session, 'file-1', [7]),
        await post(
          'verify',
          query: {'session': session, 'file': 'file-1', 'crc': '0'},
        ),
        await post('finish', query: {'session': session}),
        await post('cancel', query: {'session': session}),
      ]) {
        expect(reply.status, HttpStatus.gone);
        expect(reply.body['reason'], reasonNoSession);
      }
    });

    test('a session that has already closed is gone too', () async {
      final String session = await prepare(['a.bin']);
      expect((await upload(session, 'file-0', [7])).status, 200);
      expect(
        (await post(
          'verify',
          query: {
            'session': session,
            'file': 'file-0',
            'crc': getCrc32([7]).toRadixString(16),
          },
        )).status,
        200,
      );
      expect((await post('finish', query: {'session': session})).status, 200);

      final Reply again = await post('finish', query: {'session': session});

      expect(again.status, HttpStatus.gone);
      expect(again.body['reason'], reasonNoSession);
    });

    test('a live session still refuses a file it never heard of', () async {
      final String session = await prepare(['a.bin']);

      // Not a gone session: this one is here and does not know that file.
      expect((await upload(session, 'file-9', [7])).status, 400);
      expect(
        (await post(
          'verify',
          query: {'session': session, 'file': 'file-9', 'crc': '0'},
        )).status,
        400,
      );
    });
  });

  group('the sender gives the transfer up at once', () {
    late Directory sandbox;
    late HttpServer receiver;
    late Device peer;
    int uploads = 0;
    int uploadsBeforeGone = 999;
    bool finishSaysGone = false;

    Future<void> answer(
      HttpRequest request,
      String body, {
      int status = 200,
    }) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    }

    Future<void> gone(HttpRequest request) =>
        answer(request, '{"reason":"$reasonNoSession"}', status: HttpStatus.gone);

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-gone-send-');
      xvDeviceId = 'sender';
      xvDeviceName = 'Sender';
      xvTransfers = [];
      xdef['Program language'] = 'en';
      uploads = 0;
      uploadsBeforeGone = 999;
      finishSaysGone = false;

      receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      receiver.listen((HttpRequest request) async {
        final String path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/prepare')) {
          return answer(request, '{"sessionId":"session"}');
        }
        if (path.endsWith('/upload')) {
          uploads++;
          if (uploads > uploadsBeforeGone) return gone(request);
          return answer(request, '{"ok":true}');
        }
        if (path.endsWith('/finish') && finishSaysGone) return gone(request);
        return answer(request, '{"ok":true}');
      });
      peer = Device(
        id: 'peer',
        name: 'Peer',
        address: '127.0.0.1',
        port: receiver.port,
      );
    });

    tearDown(() async {
      await receiver.close(force: true);
      await sandbox.delete(recursive: true);
    });

    Future<FileItem> pick(String name) async {
      final File file = File(p.join(sandbox.path, name));
      await file.writeAsString(name);
      return FileItem(
        id: name,
        relativePath: name,
        size: name.length,
        sourcePath: file.path,
      );
    }

    test('the rest of the manifest is not offered to it', () async {
      uploadsBeforeGone = 1;
      final List<FileItem> batch = [
        for (final String name in ['a.txt', 'b.txt', 'c.txt', 'd.txt'])
          await pick(name),
      ];

      final TransferStatus status = await SendService().send(
        peer: peer,
        files: batch,
      );

      expect(status, TransferStatus.failed);
      expect(xvTransfers.single.error, 'The receiver stopped the transfer');
      // One file went, one discovered the session was gone, and that was the
      // end of it: no retries of that file and no walk through the other two.
      expect(uploads, 2);
      expect(batch.first.done, isTrue);
      expect(batch.last.done, isFalse);
    });

    test('a finish refused that way says so instead of a code', () async {
      finishSaysGone = true;
      final FileItem item = await pick('a.txt');

      final TransferStatus status = await SendService().send(
        peer: peer,
        files: [item],
      );

      expect(status, TransferStatus.failed);
      expect(xvTransfers.single.error, 'The receiver stopped the transfer');
      expect(
        xvTransfers.single.events.map(formatTransferEvent).join('\n'),
        contains('The receiver stopped the transfer'),
      );
    });
  });
}
