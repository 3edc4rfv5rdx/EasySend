import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef Reply = ({int status, Map<String, dynamic> body});

void main() {
  late Directory sandbox;
  late ReceiveServer server;
  late HttpClient client;
  late int port;

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

  Map<String, dynamic> manifest(String path) => {
    'senderId': 'trusted-sender',
    'senderName': 'Sender',
    'files': [
      {'id': 'file-1', 'path': path, 'size': 1},
    ],
  };

  // Prepare, upload and verify one file, leaving the session ready to finish.
  Future<String> sessionReadyToFinish(String name) async {
    final Reply prepared = await post('prepare', body: manifest(name));
    expect(prepared.status, 200);
    final String session = prepared.body['sessionId'] as String;

    final HttpClientRequest uploadReq = await client.postUrl(
      url('upload', {'session': session, 'file': 'file-1'}),
    );
    uploadReq.contentLength = 1;
    uploadReq.add([7]);
    final HttpClientResponse upload = await uploadReq.close();
    expect(upload.statusCode, 200);
    await upload.drain<void>();

    final Reply verified = await post(
      'verify',
      query: {
        'session': session,
        'file': 'file-1',
        'crc': getCrc32([7]).toRadixString(16),
      },
    );
    expect(verified.status, 200);
    return session;
  }

  Future<void> startServer({Duration? sessionTimeout}) async {
    server = sessionTimeout == null
        ? ReceiveServer()
        : ReceiveServer(sessionTimeout: sessionTimeout);
    expect(await server.start(), isTrue);
    port = server.boundPort!;
  }

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-finish-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [Device(id: 'trusted-sender', name: 'Sender', trusted: true)];
    xdef['Port'] = '0';
    client = HttpClient();
    await startServer();
  });

  tearDown(() async {
    client.close(force: true);
    await server.stop();
    await sandbox.delete(recursive: true);
  });

  test('a notification failure still finishes the session', () async {
    server.notifyFinished = (_) async =>
        throw const OSError('notifications are off');
    final String session = await sessionReadyToFinish('done.bin');

    final Reply finished = await post('finish', query: {'session': session});

    expect(finished.status, 200);
    expect(xvTransfers.single.status, TransferStatus.done);
    expect(await File(p.join(xvRecvDir, 'done.bin')).readAsBytes(), [7]);
    expect(
      await Directory(incompleteSessionDirectory(xvRecvDir, session)).exists(),
      isFalse,
    );
    // The slot is free: a stranded session would answer this one with 409.
    final Reply next = await post('prepare', body: manifest('second.bin'));
    expect(next.status, 200);
  });

  // Text sent as a file: the receiver's half of it is the clipboard, and it is
  // filled once the transfer is over rather than as the file lands.
  test('a clipboard file that arrived fills the clipboard', () async {
    final List<String> copied = [];
    final List<String> notified = [];
    server.copyClipboard = (FileItem file) async {
      copied.add(file.relativePath);
      return true;
    };
    server.notifyFinished = (String text) async => notified.add(text);
    final String session = await sessionReadyToFinish(
      'clipboard/x.20260831-143007.txt',
    );

    final Reply finished = await post('finish', query: {'session': session});

    expect(finished.status, 200);
    expect(copied, ['clipboard/x.20260831-143007.txt']);
    // The file is a file like any other and stays where files land.
    expect(
      await File(
        p.join(xvRecvDir, 'clipboard/x.20260831-143007.txt'),
      ).readAsBytes(),
      [7],
    );
    expect(notified.single, contains('Copied to the clipboard'));
    expect(
      xvTransfers.single.events.any(
        (TransferEvent e) => e.message == 'Copied to the clipboard',
      ),
      isTrue,
    );
  });

  test('an ordinary file never touches the clipboard', () async {
    bool asked = false;
    final List<String> notified = [];
    server.copyClipboard = (FileItem file) async {
      asked = true;
      return true;
    };
    server.notifyFinished = (String text) async => notified.add(text);
    final String session = await sessionReadyToFinish('notes.txt');

    expect((await post('finish', query: {'session': session})).status, 200);

    expect(asked, isFalse);
    expect(notified.single, isNot(contains('Copied to the clipboard')));
  });

  // Android refuses the clipboard to an app that is not in front, and the text
  // is on disk either way: the sender must still get its answer.
  test('a clipboard the platform refuses still finishes the session', () async {
    server.copyClipboard = (FileItem file) async =>
        throw const OSError('the clipboard is not ours to write');
    final String session = await sessionReadyToFinish(
      'clipboard/x.20260831-143007.txt',
    );

    final Reply finished = await post('finish', query: {'session': session});

    expect(finished.status, 200);
    expect(xvTransfers.single.status, TransferStatus.done);
    expect(
      xvTransfers.single.events.any(
        (TransferEvent e) => e.message == 'Copied to the clipboard',
      ),
      isFalse,
    );
  });

  // The other end of finding 7: the sender's finish never landed, so it sent a
  // best-effort cancel over a session whose every file is already published.
  // That is not a transfer being stopped, and saying "Cancelled" over a full
  // receive folder had the two ends describing one event differently.
  test('a cancel after every file arrived is not a cancellation', () async {
    final String session = await sessionReadyToFinish('arrived.bin');

    final Reply cancelled = await post('cancel', query: {'session': session});

    expect(cancelled.status, 200);
    expect(xvTransfers.single.status, TransferStatus.unconfirmed);
    expect(xvTransfers.single.doneCount, 1);
    // The file is here and staying: a cancel never takes back what was
    // published, which is what lets the sender delete a moved original.
    expect(await File(p.join(xvRecvDir, 'arrived.bin')).readAsBytes(), [7]);
    expect(
      xvTransfers.single.events.map(formatTransferEvent).join('\n'),
      contains('The sender did not confirm the transfer'),
    );
    // The slot is free again.
    expect((await post('prepare', body: manifest('after.bin'))).status, 200);
  });

  test('a cancel that interrupts a transfer is still a cancellation', () async {
    final Reply prepared = await post('prepare', body: manifest('half.bin'));
    expect(prepared.status, 200);
    final String session = prepared.body['sessionId'] as String;

    final Reply cancelled = await post('cancel', query: {'session': session});

    expect(cancelled.status, 200);
    expect(xvTransfers.single.status, TransferStatus.cancelled);
    expect(
      xvTransfers.single.events.map(formatTransferEvent).join('\n'),
      contains('Cancelled by the sender'),
    );
  });

  test('a sender cancel during finish cannot rewrite the outcome', () async {
    final Completer<void> notifying = Completer<void>();
    final Completer<void> release = Completer<void>();
    server.notifyFinished = (_) async {
      notifying.complete();
      await release.future;
    };
    final String session = await sessionReadyToFinish('race.bin');

    final Future<Reply> finishing = post('finish', query: {'session': session});
    await notifying.future;
    final Reply cancelled = await post('cancel', query: {'session': session});
    release.complete();

    expect(cancelled.status, HttpStatus.conflict);
    expect(cancelled.body['reason'], 'out-of-order');
    expect((await finishing).status, 200);
    expect(xvTransfers.single.status, TransferStatus.done);
    expect(await File(p.join(xvRecvDir, 'race.bin')).readAsBytes(), [7]);
    expect((await post('prepare', body: manifest('after.bin'))).status, 200);
  });

  test('a local stop during finish is ignored', () async {
    final Completer<void> notifying = Completer<void>();
    final Completer<void> release = Completer<void>();
    server.notifyFinished = (_) async {
      notifying.complete();
      await release.future;
    };
    final String session = await sessionReadyToFinish('stopped.bin');

    final Future<Reply> finishing = post('finish', query: {'session': session});
    await notifying.future;
    await server.cancelCurrent();
    release.complete();

    expect((await finishing).status, 200);
    expect(xvTransfers.single.status, TransferStatus.done);
  });

  test('the inactivity timer does not fire during finish', () async {
    await server.stop();
    await startServer(sessionTimeout: const Duration(milliseconds: 60));
    final Completer<void> notifying = Completer<void>();
    final Completer<void> release = Completer<void>();
    server.notifyFinished = (_) async {
      notifying.complete();
      await release.future;
    };
    final String session = await sessionReadyToFinish('slow.bin');

    final Future<Reply> finishing = post('finish', query: {'session': session});
    await notifying.future;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    release.complete();

    expect((await finishing).status, 200);
    expect(xvTransfers.single.status, TransferStatus.done);
    expect(xvTransfers.single.error, isNull);
  });

  test('stopping the server during finish keeps the outcome', () async {
    final Completer<void> notifying = Completer<void>();
    final Completer<void> release = Completer<void>();
    server.notifyFinished = (_) async {
      notifying.complete();
      await release.future;
    };
    final String session = await sessionReadyToFinish('torn.bin');

    final Future<Reply> finishing = post('finish', query: {'session': session});
    await notifying.future;
    final Future<void> stopping = server.stop();
    release.complete();
    await stopping;
    try {
      await finishing;
    } on HttpException {
      // The socket may go before the answer does; the outcome is what matters.
    }

    expect(xvTransfers.single.status, TransferStatus.done);
    expect(await File(p.join(xvRecvDir, 'torn.bin')).readAsBytes(), [7]);
  });
}
