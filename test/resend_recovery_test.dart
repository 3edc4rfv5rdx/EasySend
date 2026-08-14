import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef Reply = ({int status, Map<String, dynamic> body});

// What happens when the answer to a request is lost rather than the request.
//
// The receiver publishes a file before it answers the verify that asked about
// it, so a dropped answer says nothing about the file. Sending it again used to
// be refused as out-of-order for the rest of the session: the receiver counted
// the transfer done while the sender called the file failed, and the Retry it
// then offered put a second copy in the receive folder (ADD/tofix6.md #1).
void main() {
  group('the receiver tells a repeat apart from a protocol error', () {
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

    Future<Reply> verify(String session, String file, List<int> data) => post(
      'verify',
      query: {
        'session': session,
        'file': file,
        'crc': getCrc32(data).toRadixString(16),
      },
    );

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

    // What the user would see in the folder: the session's own working
    // directory is not a received file and lives only as long as the session.
    List<String> received() =>
        Directory(xvRecvDir)
            .listSync()
            .map((e) => p.basename(e.path))
            .where((String name) => !name.startsWith(incompleteDirPrefix))
            .toList()
          ..sort();

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-resend-');
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

    test('a repeated upload of a published file says it is already here', () async {
      final String session = await prepare(['a.bin']);
      expect((await upload(session, 'file-0', [7])).status, 200);
      expect((await verify(session, 'file-0', [7])).status, 200);

      final Reply again = await upload(session, 'file-0', [7]);

      expect(again.status, HttpStatus.conflict);
      expect(again.body['reason'], reasonAlreadyVerified);
      // The published file is untouched and no second copy was made.
      expect(await File(p.join(xvRecvDir, 'a.bin')).readAsBytes(), [7]);
      expect(received(), ['a.bin']);
      // And the transfer still ends as the clean one it is.
      expect((await post('finish', query: {'session': session})).status, 200);
      expect(xvTransfers.single.status, TransferStatus.done);
      expect(xvTransfers.single.failedCount, 0);
    });

    test('a repeated verify answers as it answered the first time', () async {
      final String session = await prepare(['a.bin']);
      expect((await upload(session, 'file-0', [7])).status, 200);
      expect((await verify(session, 'file-0', [7])).status, 200);

      final Reply again = await verify(session, 'file-0', [7]);

      expect(again.status, 200);
      expect(again.body['reason'], reasonAlreadyVerified);
      expect(received(), ['a.bin']);
    });

    test('a repeated verify carrying another sum is refused', () async {
      final String session = await prepare(['a.bin']);
      expect((await upload(session, 'file-0', [7])).status, 200);
      expect((await verify(session, 'file-0', [7])).status, 200);

      final Reply other = await verify(session, 'file-0', [9]);

      expect(other.status, HttpStatus.conflict);
      expect(other.body['reason'], 'crc');
      expect(await File(p.join(xvRecvDir, 'a.bin')).readAsBytes(), [7]);
    });

    test('a file that was never verified is sent again from the start', () async {
      final String session = await prepare(['a.bin']);
      // The answer to this one is lost, so the sender repeats the file.
      expect((await upload(session, 'file-0', [7])).status, 200);

      expect((await upload(session, 'file-0', [9])).status, 200);
      expect((await verify(session, 'file-0', [9])).status, 200);

      // The bytes of the second attempt, and one file, not two.
      expect(await File(p.join(xvRecvDir, 'a.bin')).readAsBytes(), [9]);
      expect(received(), ['a.bin']);
      expect((await post('finish', query: {'session': session})).status, 200);
      expect(xvTransfers.single.status, TransferStatus.done);
    });

    test('a request out of order is still refused as one', () async {
      final String session = await prepare(['a.bin', 'b.bin']);

      // Nothing was uploaded for this file, so there is nothing to confirm.
      final Reply early = await verify(session, 'file-0', [7]);
      expect(early.status, HttpStatus.conflict);
      expect(early.body['reason'], 'out-of-order');

      // A file the session is not currently taking cannot jump the queue.
      expect((await upload(session, 'file-0', [7])).status, 200);
      final Reply jumped = await upload(session, 'file-1', [7]);
      expect(jumped.status, HttpStatus.conflict);
      expect(jumped.body['reason'], 'out-of-order');
    });
  });

  group('the sender asks again instead of sending the file again', () {
    late Directory sandbox;
    late HttpServer receiver;
    late Device peer;
    int uploads = 0;
    int verifies = 0;
    int dropVerifyAnswers = 0;
    bool uploadSaysAlreadyVerified = false;

    Future<void> answer(HttpRequest request, String body, {int status = 200}) async {
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(body);
      await request.response.close();
    }

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-confirm-');
      xvDeviceId = 'sender';
      xvDeviceName = 'Sender';
      xvTransfers = [];
      xdef['Program language'] = 'en';
      uploads = 0;
      verifies = 0;
      dropVerifyAnswers = 0;
      uploadSaysAlreadyVerified = false;

      receiver = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      receiver.listen((HttpRequest request) async {
        final String path = request.uri.path;
        await request.drain<void>();
        if (path.endsWith('/prepare')) {
          return answer(request, '{"sessionId":"session"}');
        }
        if (path.endsWith('/upload')) {
          uploads++;
          if (uploadSaysAlreadyVerified) {
            return answer(
              request,
              '{"reason":"$reasonAlreadyVerified"}',
              status: HttpStatus.conflict,
            );
          }
          return answer(request, '{"ok":true}');
        }
        if (path.endsWith('/verify')) {
          verifies++;
          if (verifies <= dropVerifyAnswers) {
            // The receiver has published the file and its answer is lost on
            // the way back: the connection dies with nothing written on it.
            (await request.response.detachSocket()).destroy();
            return;
          }
          return answer(request, '{"ok":true}');
        }
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

    test('a lost confirmation costs a question, not the file', () async {
      dropVerifyAnswers = 1;
      final FileItem item = await pick('a.txt');

      expect(
        await SendService().send(peer: peer, files: [item]),
        TransferStatus.done,
      );

      expect(item.done, isTrue);
      // Asked again; the file itself went over the wire exactly once.
      expect(verifies, 2);
      expect(uploads, 1);
    });

    test('a file the receiver already has counts as delivered', () async {
      uploadSaysAlreadyVerified = true;
      final FileItem item = await pick('a.txt');

      expect(
        await SendService().send(peer: peer, files: [item]),
        TransferStatus.done,
      );

      expect(item.done, isTrue);
      expect(item.failed, isFalse);
      // No retries: there is nothing to try again.
      expect(uploads, 1);
      expect(
        xvTransfers.single.events.map(formatTransferEvent).join('\n'),
        contains('The receiver already has this file'),
      );
    });

    test('a confirmation that never arrives still fails the file', () async {
      dropVerifyAnswers = 99;
      final FileItem item = await pick('a.txt');

      final TransferStatus status = await SendService().send(
        peer: peer,
        files: [item],
      );

      expect(status, anyOf(TransferStatus.partial, TransferStatus.failed));
      expect(item.done, isFalse);
      // Every attempt is written down, so the log says how many there were.
      expect(
        xvTransfers.single.events
            .where((e) => e.message == 'The confirmation did not arrive')
            .length,
        greaterThan(1),
      );
    });
  });
}
