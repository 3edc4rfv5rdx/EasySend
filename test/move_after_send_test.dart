import 'dart:async';
import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late HttpServer server;
  late Device peer;
  // File ids the fake receiver refuses to verify, so a file can be made to fail
  // while the rest of the batch goes through.
  late Set<String> refuse;
  Completer<void>? holdUpload;
  String? holdUploadFor;
  Completer<void>? uploadHeld;
  Completer<void>? holdVerify;
  Completer<void>? verifyHeld;
  String? holdVerifyFor;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-move-');
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    xdef['Program language'] = 'en';
    refuse = <String>{};
    holdUpload = null;
    holdUploadFor = null;
    uploadHeld = null;
    holdVerify = null;
    verifyHeld = null;
    holdVerifyFor = null;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      await request.drain<void>();
      final String path = request.uri.path;
      final String file = request.uri.queryParameters['file'] ?? '';
      if (path.endsWith('/prepare')) {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessionId":"session"}');
      } else if (path.endsWith('/upload')) {
        final Completer<void>? hold = holdUpload;
        if (hold != null && (holdUploadFor == null || holdUploadFor == file)) {
          final Completer<void>? held = uploadHeld;
          if (held != null && !held.isCompleted) held.complete();
          await hold.future;
        }
      } else if (path.endsWith('/verify')) {
        final Completer<void>? hold = holdVerify;
        if (hold != null && (holdVerifyFor == null || holdVerifyFor == file)) {
          final Completer<void>? held = verifyHeld;
          if (held != null && !held.isCompleted) held.complete();
          await hold.future;
        }
        if (refuse.contains(file)) {
          request.response.statusCode = HttpStatus.conflict;
        }
      }
      await request.response.close();
    });
    peer = Device(
      id: 'peer',
      name: 'Peer',
      address: '127.0.0.1',
      port: server.port,
    );
  });

  tearDown(() async {
    await server.close(force: true);
    await sandbox.delete(recursive: true);
  });

  Future<FileItem> pick(String name) async {
    final File file = File('${sandbox.path}/$name');
    await file.writeAsString(name);
    return FileItem(
      id: name,
      relativePath: name,
      size: name.length,
      sourcePath: file.path,
    );
  }

  // A file picked as part of a folder: its relative path carries the structure,
  // which is what tells a move how far up it may clean.
  Future<FileItem> pickInFolder(String relative) async {
    final File file = File('${sandbox.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(relative);
    return FileItem(
      id: relative,
      relativePath: relative,
      size: relative.length,
      sourcePath: file.path,
    );
  }

  test('the folders tick takes the folders the move emptied', () async {
    final FileItem item = await pickInFolder('box/inner/moved.txt');
    expect(
      await SendService().send(
        peer: peer,
        files: [item],
        move: true,
        moveFolders: true,
      ),
      TransferStatus.done,
    );

    expect(await File(item.sourcePath!).exists(), isFalse);
    expect(await Directory('${sandbox.path}/box/inner').exists(), isFalse);
    expect(await Directory('${sandbox.path}/box').exists(), isFalse);
    // Never above the folder that was picked.
    expect(await sandbox.exists(), isTrue);
  });

  test('without the folders tick the emptied folder stays', () async {
    final FileItem item = await pickInFolder('box/moved.txt');
    expect(
      await SendService().send(peer: peer, files: [item], move: true),
      TransferStatus.done,
    );

    expect(await File(item.sourcePath!).exists(), isFalse);
    expect(await Directory('${sandbox.path}/box').exists(), isTrue);
  });

  test('a folder still holding something is left standing', () async {
    final FileItem item = await pickInFolder('box/moved.txt');
    final File bystander = File('${sandbox.path}/box/stays.txt');
    await bystander.writeAsString('stays');

    expect(
      await SendService().send(
        peer: peer,
        files: [item],
        move: true,
        moveFolders: true,
      ),
      TransferStatus.done,
    );

    expect(await Directory('${sandbox.path}/box').exists(), isTrue);
    expect(await bystander.exists(), isTrue);
  });

  test('a file picked on its own never takes the folder it sat in', () async {
    final FileItem item = await pick('alone.txt');
    expect(
      await SendService().send(
        peer: peer,
        files: [item],
        move: true,
        moveFolders: true,
      ),
      TransferStatus.done,
    );

    expect(await File(item.sourcePath!).exists(), isFalse);
    expect(await sandbox.exists(), isTrue);
  });

  test('without the tick nothing is deleted', () async {
    final FileItem item = await pick('kept.txt');
    expect(
      await SendService().send(peer: peer, files: [item]),
      TransferStatus.done,
    );
    expect(await File(item.sourcePath!).exists(), isTrue);
  });

  test('a moved file is deleted and says so in the log', () async {
    final FileItem item = await pick('moved.txt');
    expect(
      await SendService().send(peer: peer, files: [item], move: true),
      TransferStatus.done,
    );

    expect(await File(item.sourcePath!).exists(), isFalse);
    final List<String> lines = xvTransfers.single.events
        .map(formatTransferEvent)
        .toList();
    expect(lines.first, contains('Sources are deleted after they arrive'));
    expect(
      lines.where((l) => l.contains('moved.txt')),
      contains(contains('Deleted here')),
    );
  });

  test('a file that did not make it stays where it is', () async {
    final FileItem bad = await pick('refused.txt');
    final FileItem good = await pick('landed.txt');
    refuse.add(bad.id);

    expect(
      await SendService().send(peer: peer, files: [bad, good], move: true),
      TransferStatus.partial,
    );
    // The file is the unit of atomicity, so one failure does not hold back the
    // deletion of the file that did arrive, and does not cause its own.
    expect(await File(bad.sourcePath!).exists(), isTrue);
    expect(await File(good.sourcePath!).exists(), isFalse);
  });

  test('cancelling in flight deletes nothing', () async {
    final FileItem item = await pick('cancelled.txt');
    final Completer<void> hold = Completer<void>();
    holdUpload = hold;

    final SendService service = SendService();
    final Future<TransferStatus> sending = service.send(
      peer: peer,
      files: [item],
      move: true,
    );
    // Cancel while the receiver is still holding the upload open.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await service.cancel();
    hold.complete();
    expect(await sending, TransferStatus.cancelled);

    expect(await File(item.sourcePath!).exists(), isTrue);
  });

  test('cancelling after one verified file preserves every source', () async {
    final FileItem first = await pick('first.txt');
    final FileItem second = await pick('second.txt');
    final Completer<void> hold = Completer<void>();
    final Completer<void> held = Completer<void>();
    holdUpload = hold;
    holdUploadFor = second.id;
    uploadHeld = held;

    final SendService service = SendService();
    final Future<TransferStatus> sending = service.send(
      peer: peer,
      files: [first, second],
      move: true,
    );
    await held.future;
    expect(first.done, isTrue, reason: 'the first file was already verified');
    expect(await File(first.sourcePath!).exists(), isTrue);

    await service.cancel();
    hold.complete();
    expect(await sending, TransferStatus.cancelled);
    expect(await File(first.sourcePath!).exists(), isTrue);
    expect(await File(second.sourcePath!).exists(), isTrue);
  });

  test('Move preserves a same-size replacement that was never sent', () async {
    final FileItem item = await pick('replace.txt');
    final File source = File(item.sourcePath!);
    final File original = File('${source.path}.original');
    final Completer<void> hold = Completer<void>();
    final Completer<void> held = Completer<void>();
    holdVerify = hold;
    holdVerifyFor = item.id;
    verifyHeld = held;

    final Future<TransferStatus> sending = SendService().send(
      peer: peer,
      files: [item],
      move: true,
    );
    await held.future;
    await source.rename(original.path);
    await source.writeAsString('XXXXXXXXXXX');
    expect(await source.length(), item.size);
    hold.complete();

    expect(await sending, TransferStatus.done);
    expect(await source.readAsString(), 'XXXXXXXXXXX');
    expect(await original.readAsString(), 'replace.txt');
    expect(
      xvTransfers.single.events.any(
        (event) =>
            event.file == item.relativePath &&
            event.message == 'Could not delete it here',
      ),
      isTrue,
    );
  });
}
