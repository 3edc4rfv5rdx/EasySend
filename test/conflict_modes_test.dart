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

  // The answer covers the names the question counted. A file that appears at a
  // destination which was free when the plan was built was never part of that
  // question, so Replace must not write over it: it claims its name like any
  // other file and steps aside when somebody else already holds it.
  test('replace only writes over the names that were asked about', () async {
    final File old = await alreadyHere('asked.txt');
    answerWith(ConflictMode.replace);

    final Reply prepared = await post(
      'prepare',
      body: {
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': 'file-1', 'path': 'asked.txt', 'size': payload.length},
          {'id': 'file-2', 'path': 'free.txt', 'size': payload.length},
        ],
      },
    );
    expect(prepared.status, 200);
    final String session = prepared.body['sessionId'] as String;

    // Somebody else takes the second destination while the transfer runs.
    final File latecomer = File(p.join(xvRecvDir, 'free.txt'));
    await latecomer.writeAsString('written after prepare');

    for (final String id in ['file-1', 'file-2']) {
      final HttpClientRequest upload = await client.postUrl(
        url('upload', {'session': session, 'file': id}),
      );
      upload.contentLength = payload.length;
      upload.add(payload);
      await (await upload.close()).drain<void>();
      expect(
        (await post(
          'verify',
          query: {
            'session': session,
            'file': id,
            'crc': getCrc32(payload).toRadixString(16),
          },
        )).status,
        200,
      );
    }
    expect((await post('finish', query: {'session': session})).status, 200);

    // The name that was counted is written over, as the answer asked.
    expect(await old.readAsString(), 'the new one');
    // The one nobody was asked about is untouched, and the arriving file is
    // beside it rather than instead of it.
    expect(await latecomer.readAsString(), 'written after prepare');
    expect(
      await File(p.join(xvRecvDir, 'free (1).txt')).readAsString(),
      'the new one',
    );
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

  // A clipboard is a file like any other here, so it can be the file whose name
  // is already taken. Keeping means nothing was written — and nothing may be
  // pasted either, least of all the receiver's own older file.
  group('a clipboard whose name is already taken', () {
    late String name;
    late File old;

    setUp(() async {
      name = 'x.20260831-120000.txt';
      old = File(p.join(xvRecvDir, clipboardDirName, name));
      await old.parent.create(recursive: true);
      await old.writeAsString('what was here before');
    });

    test('keeping it pastes nothing', () async {
      answerWith(ConflictMode.keep);
      final List<FileItem> asked = [];
      server.copyClipboard = (FileItem file) async {
        asked.add(file);
        return true;
      };

      final Reply prepared = await post(
        'prepare',
        body: {
          'senderId': 'sender',
          'senderName': 'Sender',
          'files': [
            {
              'id': 'file-1',
              'path': '$clipboardDirName/$name',
              'size': payload.length,
            },
          ],
        },
      );
      expect(prepared.body['skip'], ['file-1']);
      // What a sender that honoured the skip list does: nothing to upload.
      expect(
        (await post(
          'finish',
          query: {'session': prepared.body['sessionId'] as String},
        )).status,
        200,
      );

      expect(asked, isEmpty);
      expect(await old.readAsString(), 'what was here before');
      expect(
        xvTransfers.single.events.any(
          (TransferEvent e) => e.message == 'Copied to the clipboard',
        ),
        isFalse,
      );
    });

    test('a copy beside it is pasted as always', () async {
      answerWith(ConflictMode.copies);
      final List<FileItem> asked = [];
      server.copyClipboard = (FileItem file) async {
        asked.add(file);
        return true;
      };

      expect((await sendOne('$clipboardDirName/$name')).status, 200);

      expect(asked.single.relativePath, '$clipboardDirName/$name');
      expect(
        asked.single.destinationPath,
        p.join(xvRecvDir, clipboardDirName, 'x.20260831-120000 (1).txt'),
      );
      expect(await old.readAsString(), 'what was here before');
    });
  });

  // A folder wearing the name of an arriving file used to be counted as a taken
  // name, offered all three answers, and then refused by the containment check
  // once one of them was picked — taking the whole manifest with it.
  test('a folder on the name never refuses the transfer', () async {
    await Directory(p.join(xvRecvDir, 'Photos')).create();
    final List<int> statuses = [];
    final List<int> asked = [];
    for (final ConflictMode mode in ConflictMode.values) {
      answerWith(mode, seen: asked);

      final Reply prepared = await post(
        'prepare',
        body: {
          'senderId': 'sender',
          'senderName': 'Sender',
          'files': [
            {'id': 'file-1', 'path': 'Photos', 'size': payload.length},
            {'id': 'file-2', 'path': 'beside.txt', 'size': payload.length},
          ],
        },
      );
      statuses.add(prepared.status);
      if (prepared.status != 200) continue;
      expect(prepared.body['skip'], isNull, reason: '$mode');
      expect(
        (await post(
          'cancel',
          query: {'session': prepared.body['sessionId'] as String},
        )).status,
        200,
      );
    }
    // The answer the dialog offered must never be the thing that kills the
    // transfer: every one of the three has to get as far as a session.
    expect(statuses, [200, 200, 200]);
    // And nothing was worth asking about: a folder is not one of the files the
    // question is about.
    expect(asked, [0, 0, 0]);
    expect(
      await FileSystemEntity.type(
        p.join(xvRecvDir, 'Photos'),
        followLinks: false,
      ),
      FileSystemEntityType.directory,
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

  // A file the receiver will throw away need not travel at all: prepare names
  // it, and a sender that understands the field never sends it.
  test('keeping asks the sender not to send those files', () async {
    await alreadyHere('note.txt');
    answerWith(ConflictMode.keep);

    final Reply prepared = await post(
      'prepare',
      body: {
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': 'file-1', 'path': 'note.txt', 'size': 3},
          {'id': 'file-2', 'path': 'fresh.txt', 'size': 3},
        ],
      },
    );

    expect(prepared.status, 200);
    expect(prepared.body['skip'], ['file-1']);
  });

  test('the other answers ask for everything', () async {
    await alreadyHere('note.txt');
    for (final ConflictMode mode in [
      ConflictMode.copies,
      ConflictMode.replace,
    ]) {
      answerWith(mode);
      final Reply prepared = await post(
        'prepare',
        body: {
          'senderId': 'sender',
          'senderName': 'Sender',
          'files': [
            {'id': 'file-1', 'path': 'note.txt', 'size': 3},
          ],
        },
      );
      expect(prepared.body['skip'], isNull);
      expect(
        (await post(
          'cancel',
          query: {'session': prepared.body['sessionId'] as String},
        )).status,
        200,
      );
    }
  });

  test('a file nobody sent because we asked is not a failure', () async {
    final File old = await alreadyHere('note.txt');
    answerWith(ConflictMode.keep);

    final Reply prepared = await post(
      'prepare',
      body: {
        'senderId': 'sender',
        'senderName': 'Sender',
        'files': [
          {'id': 'file-1', 'path': 'note.txt', 'size': 3},
        ],
      },
    );
    expect(prepared.status, 200);
    // Straight to finish: this is what a sender that honoured the skip list
    // does, having had nothing to upload.
    final Reply finished = await post(
      'finish',
      query: {'session': prepared.body['sessionId'] as String},
    );

    expect(finished.status, 200);
    expect(xvTransfers.single.status, TransferStatus.done);
    expect(xvTransfers.single.failedCount, 0);
    expect(await old.readAsString(), 'the old one');
    expect(
      xvTransfers.single.events.any(
        (TransferEvent e) => e.message == 'Already here, not saved',
      ),
      isTrue,
    );
  });
}
