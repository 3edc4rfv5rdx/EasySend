import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef Reply = ({int status, Map<String, dynamic> body});

// What the receiver does with a name that is already taken. The answer comes
// from the person at the screen, and each of the three has to be shown on the
// disk itself: a copy beside the old file, the old file written over, or the
// old file left exactly as it was with nothing new written down.
void main() {
  late Directory sandbox;
  late ReceiveServer server;
  late HttpClient client;
  late int port;
  late List<int> payload;

  Uri url(String route, [Map<String, String>? query]) =>
      Uri.http('127.0.0.1:$port', '$apiPrefix/$route', query);

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
    final HttpClientResponse resp = await req.close();
    final String text = await utf8.decoder.bind(resp).join();
    return (
      status: resp.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : (json.decode(text) as Map).cast<String, dynamic>(),
    );
  }

  void answerWith(ConflictMode mode, {List<int>? seen}) {
    server.askUser =
        ({
          required String senderName,
          required int fileCount,
          required int totalBytes,
          required int occupied,
        }) async {
          seen?.add(occupied);
          return (true, false, mode);
        };
  }

  // Send one file called `name`, from prepare to finish, and give back what
  // verify answered about it.
  Future<Reply> sendOne(String name) async {
    final Reply prepared = await post(
      'prepare',
      body: {
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': 'file-1', 'path': name, 'size': payload.length},
        ],
      },
    );
    expect(prepared.status, 200);
    final String session = prepared.body['sessionId'] as String;

    final HttpClientRequest upload = await client.postUrl(
      url('upload', {'session': session, 'file': 'file-1'}),
    );
    upload.contentLength = payload.length;
    upload.add(payload);
    final HttpClientResponse uploaded = await upload.close();
    expect(uploaded.statusCode, 200);
    await uploaded.drain<void>();

    final Reply verified = await post(
      'verify',
      query: {
        'session': session,
        'file': 'file-1',
        'crc': getCrc32(payload).toRadixString(16),
      },
    );
    expect((await post('finish', query: {'session': session})).status, 200);
    return verified;
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-conflict-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [];
    xdef['Port'] = '0';
    xdef['Program language'] = 'en';
    xdef['Ask about existing files'] = 'true';
    payload = utf8.encode('the new one');
    await Directory(xvRecvDir).create(recursive: true);
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

  Future<File> alreadyHere(String name) async {
    final File file = File(p.join(xvRecvDir, name));
    await file.writeAsString('the old one');
    return file;
  }

  test('the question says how many names are already taken', () async {
    await alreadyHere('note.txt');
    final List<int> seen = [];
    answerWith(ConflictMode.copies, seen: seen);

    await sendOne('note.txt');

    expect(seen, [1]);
  });

  test('a name nothing holds is not asked about', () async {
    final List<int> seen = [];
    answerWith(ConflictMode.copies, seen: seen);

    await sendOne('fresh.txt');

    expect(seen, [0]);
  });

  test('copies leave both files side by side', () async {
    final File old = await alreadyHere('note.txt');
    answerWith(ConflictMode.copies);

    final Reply verified = await sendOne('note.txt');

    expect(verified.status, 200);
    expect(await old.readAsString(), 'the old one');
    expect(
      await File(p.join(xvRecvDir, 'note (1).txt')).readAsString(),
      'the new one',
    );
  });

  test('replace writes over the file that was here', () async {
    final File old = await alreadyHere('note.txt');
    answerWith(ConflictMode.replace);

    final Reply verified = await sendOne('note.txt');

    expect(verified.status, 200);
    expect(await old.readAsString(), 'the new one');
    // And no second name was taken on the way.
    expect(await File(p.join(xvRecvDir, 'note (1).txt')).exists(), isFalse);
    expect(xvTransfers.single.status, TransferStatus.done);
  });

  test('keeping what is here writes nothing and says so', () async {
    final File old = await alreadyHere('note.txt');
    answerWith(ConflictMode.keep);

    final Reply verified = await sendOne('note.txt');

    // The transfer is a success — the bytes arrived and matched — and the
    // answer tells the sender the file is not on this disk, which is what
    // stops a move from deleting the original.
    expect(verified.status, 200);
    expect(verified.body['stored'], isFalse);
    expect(await old.readAsString(), 'the old one');
    expect(await File(p.join(xvRecvDir, 'note (1).txt')).exists(), isFalse);
    expect(xvTransfers.single.status, TransferStatus.done);
    expect(
      xvTransfers.single.events.any(
        (TransferEvent e) => e.message == 'Already here, not saved',
      ),
      isTrue,
    );
  });

  test('keeping does not touch the files whose names are free', () async {
    await alreadyHere('note.txt');
    answerWith(ConflictMode.keep);

    // A name nothing holds is written as usual even in this mode.
    final Reply verified = await sendOne('other.txt');

    expect(verified.status, 200);
    expect(verified.body['stored'], isNull);
    expect(
      await File(p.join(xvRecvDir, 'other.txt')).readAsString(),
      'the new one',
    );
  });

  test('nothing is asked when the setting is off', () async {
    await alreadyHere('note.txt');
    final List<int> seen = [];
    answerWith(ConflictMode.copies, seen: seen);
    xdef['Ask about existing files'] = 'false';

    await sendOne('note.txt');

    expect(seen, [0]);
  });
}
