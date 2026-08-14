import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

typedef Reply = ({int status, Map<String, dynamic> body});

class _ControlledWriter implements ReceiveFileWriter {
  final List<Completer<void>> _gates = [];
  final StreamController<int> starts = StreamController<int>.broadcast();
  int activeWrites = 0;
  int maxActiveWrites = 0;
  bool aborted = false;

  @override
  Future<void> write(List<int> chunk) async {
    final int index = _gates.length;
    final Completer<void> gate = Completer<void>();
    _gates.add(gate);
    activeWrites++;
    if (activeWrites > maxActiveWrites) maxActiveWrites = activeWrites;
    starts.add(index);
    try {
      await gate.future;
    } finally {
      activeWrites--;
    }
  }

  @override
  Future<void> abort() async {
    aborted = true;
    for (final Completer<void> gate in _gates) {
      if (!gate.isCompleted) gate.complete();
    }
  }

  @override
  Future<void> close() async {}
}

class _FailingWriter implements ReceiveFileWriter {
  @override
  Future<void> write(List<int> chunk) =>
      Future<void>.error(const FileSystemException('disk full'));

  @override
  Future<void> abort() async {}

  @override
  Future<void> close() async {}
}

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
    final req = await client.postUrl(url(route, query));
    if (body != null) {
      req.headers.contentType = ContentType.json;
      req.write(json.encode(body));
    } else {
      req.contentLength = 0;
    }
    final resp = await req.close();
    final text = await utf8.decoder.bind(resp).join();
    return (
      status: resp.statusCode,
      body: text.isEmpty
          ? <String, dynamic>{}
          : (json.decode(text) as Map).cast<String, dynamic>(),
    );
  }

  Map<String, dynamic> manifest(String path, {int size = 1}) => {
    'senderId': 'trusted-sender',
    'senderName': 'Sender',
    'files': [
      {'id': 'file-1', 'path': path, 'size': size},
    ],
  };

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-server-');
    xvConfigDir = p.join(sandbox.path, 'config');
    xvRecvDir = p.join(sandbox.path, 'receive');
    xvDeviceId = 'receiver';
    xvDeviceName = 'Receiver';
    xvPlatform = 'linux';
    xvTransfers = [];
    xvDevices = [Device(id: 'trusted-sender', name: 'Sender', trusted: true)];
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

  test('only one concurrent prepare reserves the receiver', () async {
    final replies = await Future.wait([
      post('prepare', body: manifest('one.bin')),
      post('prepare', body: manifest('two.bin')),
    ]);
    expect(replies.map((r) => r.status), containsAll([200, 409]));
  });

  // One transfer at a time, in either direction (SPEC 5.7). Sending and
  // receiving at once left one Stop button acting on whichever of the two
  // happened to be first in the list.
  test('a sender of our own makes the receiver busy too', () async {
    xvTransfers = [
      TransferSession(
        id: 'outgoing',
        incoming: false,
        peerName: 'Peer',
        files: [FileItem(id: 'f', relativePath: 'f.bin', size: 1)],
      )..status = TransferStatus.active,
    ];

    final Reply refused = await post('prepare', body: manifest('one.bin'));
    expect(refused.status, 409);
    expect(refused.body['reason'], 'busy');

    // And the slot is free the moment that transfer is over.
    xvTransfers.single.status = TransferStatus.done;
    expect((await post('prepare', body: manifest('one.bin'))).status, 200);
  });

  // A repeat of the request the session is on is a sender that lost the answer,
  // not a protocol error, and is answered as a recovery — see
  // resend_recovery_test.dart. What is genuinely out of order still is.
  test(
    'rejects a finish that comes too early and a session used after it ends',
    () async {
      final prepared = await post('prepare', body: manifest('file.bin'));
      final session = prepared.body['sessionId'] as String;

      Future<int> sendFile(List<int> bytes) async {
        final uploadReq = await client.postUrl(
          url('upload', {'session': session, 'file': 'file-1'}),
        );
        uploadReq.contentLength = bytes.length;
        uploadReq.add(bytes);
        final upload = await uploadReq.close();
        await upload.drain<void>();
        return upload.statusCode;
      }

      expect(await sendFile([7]), 200);

      // A file is still waiting to be verified, so the session cannot close.
      expect((await post('finish', query: {'session': session})).status, 409);

      final crc = getCrc32([7]).toRadixString(16);
      expect(
        (await post(
          'verify',
          query: {'session': session, 'file': 'file-1', 'crc': crc},
        )).status,
        200,
      );
      expect((await post('finish', query: {'session': session})).status, 200);
      // The session is gone: nothing addressed to it means anything now, and
      // it says that rather than reading like a malformed request.
      expect(
        (await post('finish', query: {'session': session})).status,
        HttpStatus.gone,
      );
      expect(await sendFile([7]), HttpStatus.gone);
    },
  );

  test('a destination created after prepare is never overwritten', () async {
    final prepared = await post('prepare', body: manifest('late.bin'));
    final session = prepared.body['sessionId'] as String;

    final uploadReq = await client.postUrl(
      url('upload', {'session': session, 'file': 'file-1'}),
    );
    uploadReq.contentLength = 1;
    uploadReq.add([7]);
    final upload = await uploadReq.close();
    expect(upload.statusCode, 200);
    await upload.drain<void>();

    final late = File(p.join(xvRecvDir, 'late.bin'));
    await late.writeAsString('created after prepare');
    final crc = getCrc32([7]).toRadixString(16);
    expect(
      (await post(
        'verify',
        query: {'session': session, 'file': 'file-1', 'crc': crc},
      )).status,
      200,
    );

    expect(await late.readAsString(), 'created after prepare');
    final received = File(p.join(xvRecvDir, 'late (1).bin'));
    expect(await received.readAsBytes(), [7]);
    expect(xvTransfers.single.files.single.destinationPath, received.path);
  });

  test(
    'cancel during upload waits for the writer and removes the part',
    () async {
      final prepared = await post(
        'prepare',
        body: manifest('large.bin', size: 4),
      );
      final session = prepared.body['sessionId'] as String;
      final chunks = StreamController<List<int>>();
      final uploadReq = await client.postUrl(
        url('upload', {'session': session, 'file': 'file-1'}),
      );
      uploadReq.contentLength = 4;
      final uploadFuture = uploadReq
          .addStream(chunks.stream)
          .then((_) => uploadReq.close());
      chunks.add([1, 2]);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final cancelFuture = post('cancel', query: {'session': session});
      chunks.add([3, 4]);
      await chunks.close();
      final cancel = await cancelFuture;
      expect(cancel.status, 200);
      try {
        final upload = await uploadFuture;
        await upload.drain<void>();
      } on HttpException {
        // The cancelled response may close the upload socket first.
      }
      expect(
        await Directory(
          incompleteSessionDirectory(xvRecvDir, session),
        ).exists(),
        isFalse,
      );
      expect(xvTransfers.single.bytesDone, lessThanOrEqualTo(4));
    },
  );

  test(
    'disk backpressure permits one write and cancellation aborts it',
    () async {
      await server.stop();
      final _ControlledWriter writer = _ControlledWriter();
      server = ReceiveServer(fileWriterFactory: (_) => writer);
      expect(await server.start(), isTrue);
      port = server.boundPort!;

      final Reply prepared = await post(
        'prepare',
        body: manifest('slow.bin', size: 2),
      );
      final String session = prepared.body['sessionId'] as String;
      final HttpClientRequest uploadReq = await client.postUrl(
        url('upload', {'session': session, 'file': 'file-1'}),
      );
      uploadReq.contentLength = 2;

      final Future<int> firstStarted = writer.starts.stream.first;
      uploadReq.add([1, 2]);
      final Future<HttpClientResponse> uploadFuture = uploadReq.close();
      expect(await firstStarted, 0);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(writer.maxActiveWrites, 1);
      expect(writer.activeWrites, 1);

      final Reply cancel = await post('cancel', query: {'session': session});
      expect(cancel.status, HttpStatus.ok);
      expect(writer.aborted, isTrue);
      expect(writer.maxActiveWrites, 1);

      final HttpClientResponse upload = await uploadFuture;
      await upload.drain<void>();
      expect(upload.statusCode, HttpStatus.conflict);
    },
  );

  test('a disk write failure leaves the receive session reusable', () async {
    await server.stop();
    int writers = 0;
    server = ReceiveServer(
      fileWriterFactory: (_) {
        writers++;
        return _FailingWriter();
      },
    );
    expect(await server.start(), isTrue);
    port = server.boundPort!;

    final Reply prepared = await post('prepare', body: manifest('full.bin'));
    final String session = prepared.body['sessionId'] as String;

    Future<int> upload() async {
      final HttpClientRequest request = await client.postUrl(
        url('upload', {'session': session, 'file': 'file-1'}),
      );
      request.contentLength = 1;
      request.add([1]);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await upload(), HttpStatus.internalServerError);
    expect(await upload(), HttpStatus.internalServerError);
    expect(writers, 2);
  });

  test('receiver progress uses manifest offsets after a failed file', () async {
    final Reply prepared = await post(
      'prepare',
      body: {
        'senderId': 'trusted-sender',
        'senderName': 'Sender',
        'files': [
          {'id': 'first', 'path': 'first.bin', 'size': 3},
          {'id': 'second', 'path': 'second.bin', 'size': 2},
        ],
      },
    );
    final String session = prepared.body['sessionId'] as String;

    Future<int> upload(String id, List<int> bytes) async {
      final HttpClientRequest request = await client.postUrl(
        url('upload', {'session': session, 'file': id}),
      );
      request.contentLength = bytes.length;
      request.add(bytes);
      final HttpClientResponse response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await upload('first', [1, 2, 3]), HttpStatus.ok);
    expect(xvTransfers.single.bytesDone, 3);
    expect(
      (await post(
        'verify',
        query: {'session': session, 'file': 'first', 'crc': 'bad'},
      )).status,
      HttpStatus.conflict,
    );
    expect(xvTransfers.single.bytesDone, 3);

    expect(await upload('second', [4, 5]), HttpStatus.ok);
    expect(xvTransfers.single.bytesDone, 5);
    expect(
      (await post(
        'verify',
        query: {
          'session': session,
          'file': 'second',
          'crc': getCrc32([4, 5]).toRadixString(16),
        },
      )).status,
      HttpStatus.ok,
    );
    expect((await post('finish', query: {'session': session})).status, 200);
    expect(xvTransfers.single.status, TransferStatus.partial);
    expect(xvTransfers.single.bytesDone, xvTransfers.single.bytesTotal);
  });
}
