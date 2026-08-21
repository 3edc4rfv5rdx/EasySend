import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:easysend/globals.dart';
import 'package:easysend/net_sender.dart';
import 'package:easysend/zip_packer.dart';
import 'package:flutter_test/flutter_test.dart';

// The whole batch as one archive. What has to hold: the far end is handed one
// file and it is a real ZIP with the picked names inside; the picked files are
// counted as delivered because they travelled inside it; a move deletes the
// originals and never the archive; and nothing is left in the app's cache
// whichever way the transfer ended.
void main() {
  late Directory sandbox;
  late Directory staging;
  late HttpServer server;
  late Device peer;
  // What the receiver was told to expect, and what actually arrived.
  late Map<String, String> manifest;
  late Map<String, List<int>> uploaded;
  // Holds the archive at the receiver's door, so a test can act on the sources
  // at a moment when the packing is certainly over and the deletion certainly
  // has not started.
  Completer<void>? holdUpload;
  Completer<void>? uploadHeld;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('easysend-zip-');
    staging = Directory('${sandbox.path}/cache/zip');
    xvDeviceId = 'sender';
    xvDeviceName = 'Sender';
    xvTransfers = [];
    xdef['Program language'] = 'en';
    manifest = {};
    uploaded = {};
    holdUpload = null;
    uploadHeld = null;

    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      final String path = request.uri.path;
      final String file = request.uri.queryParameters['file'] ?? '';
      if (path.endsWith('/prepare')) {
        final String body = await utf8.decoder.bind(request).join();
        for (final dynamic entry
            in (json.decode(body) as Map)['files'] as List) {
          manifest[entry['id'] as String] = entry['path'] as String;
        }
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"sessionId":"session"}');
      } else if (path.endsWith('/upload')) {
        final Completer<void>? hold = holdUpload;
        if (hold != null) {
          final Completer<void>? held = uploadHeld;
          if (held != null && !held.isCompleted) held.complete();
          await hold.future;
        }
        final List<int> bytes = [];
        await for (final List<int> chunk in request) {
          bytes.addAll(chunk);
        }
        uploaded[file] = bytes;
      } else {
        await request.drain<void>();
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

  SendService zipSender() =>
      SendService()..zipStagingRootOf = (() async => staging.path);

  Future<FileItem> pick(String relative, [String? content]) async {
    final File file = File('${sandbox.path}/$relative');
    await file.parent.create(recursive: true);
    await file.writeAsString(content ?? 'contents of $relative');
    return FileItem(
      id: relative,
      relativePath: relative,
      size: await file.length(),
      sourcePath: file.path,
    );
  }

  // The one file the receiver was handed, read back as an archive.
  Archive receivedArchive() {
    expect(uploaded, hasLength(1));
    return ZipDecoder().decodeBytes(uploaded.values.single);
  }

  String receivedName() => manifest[uploaded.keys.single]!;

  group('a batch sent as one archive', () {
    test('the far end gets a single ZIP holding the picked paths', () async {
      final FileItem one = await pick('Trip/beach.txt');
      final FileItem two = await pick('Trip/hills/hut.txt', 'hut');

      expect(
        await zipSender().send(peer: peer, files: [one, two], asZip: true),
        TransferStatus.done,
      );

      expect(receivedName(), 'Trip.zip');
      final Archive archive = receivedArchive();
      expect(
        archive.files.map((ArchiveFile f) => f.name).toSet(),
        {'Trip/beach.txt', 'Trip/hills/hut.txt'},
      );
      expect(
        utf8.decode(
          archive.files
              .firstWhere((ArchiveFile f) => f.name.endsWith('hut.txt'))
              .content,
        ),
        'hut',
      );
    });

    // The row is about the archive from the moment it exists: it is the file
    // the manifest declares and the one the bar measures.
    test('the session ends up describing the archive, not the batch', () async {
      final FileItem one = await pick('Trip/beach.txt');
      final FileItem two = await pick('Trip/hills/hut.txt');

      await zipSender().send(peer: peer, files: [one, two], asZip: true);

      final TransferSession transfer = xvTransfers.single;
      expect(transfer.files, hasLength(1));
      expect(transfer.files.single.relativePath, 'Trip.zip');
      expect(transfer.bytesTotal, transfer.files.single.size);
      expect(transfer.packing, isFalse);
    });

    // The picked list is pruned by what has been delivered. Files that went
    // inside the archive did arrive, and a list that still held them would
    // offer to send them a second time.
    test('the picked files count as delivered', () async {
      final FileItem one = await pick('loose.txt');
      final FileItem two = await pick('other.txt');

      await zipSender().send(peer: peer, files: [one, two], asZip: true);

      expect(one.done, isTrue);
      expect(two.done, isTrue);
      // Loose files have no folder to be named after.
      expect(receivedName(), startsWith('EasySend-'));
      expect(receivedName(), endsWith('.zip'));
    });

    test('the archive is gone from the cache afterwards', () async {
      final FileItem item = await pick('Trip/beach.txt');

      await zipSender().send(peer: peer, files: [item], asZip: true);

      expect(
        staging.existsSync() ? staging.listSync() : const <FileSystemEntity>[],
        isEmpty,
      );
    });

    // A move deletes what the archive holds — the picked files — and it can
    // only do that because they were fingerprinted as they were read into it.
    test('a move deletes the originals and not the archive', () async {
      final FileItem one = await pick('Trip/beach.txt');
      final FileItem two = await pick('Trip/hills/hut.txt');

      expect(
        await zipSender().send(
          peer: peer,
          files: [one, two],
          move: true,
          asZip: true,
        ),
        TransferStatus.done,
      );

      expect(await File(one.sourcePath!).exists(), isFalse);
      expect(await File(two.sourcePath!).exists(), isFalse);
      expect(
        staging.existsSync() ? staging.listSync() : const <FileSystemEntity>[],
        isEmpty,
      );
    });

    // Same rule as a plain move: what the sender did not send, it does not
    // delete. A file that changed between the packing and the deletion is not
    // the file inside the archive.
    test('a move keeps an original that changed after it was packed', () async {
      final FileItem item = await pick('Trip/beach.txt');
      final File source = File(item.sourcePath!);
      final Completer<void> hold = Completer<void>();
      final Completer<void> held = Completer<void>();
      holdUpload = hold;
      uploadHeld = held;

      final Future<TransferStatus> sending = zipSender().send(
        peer: peer,
        files: [item],
        move: true,
        asZip: true,
      );
      // The archive is at the door: everything it holds has been read.
      await held.future;
      await source.writeAsString('rewritten while it travelled');
      hold.complete();

      expect(await sending, TransferStatus.done);
      expect(await source.readAsString(), 'rewritten while it travelled');
      expect(
        xvTransfers.single.events.any(
          (TransferEvent event) => event.message == 'Could not delete it here',
        ),
        isTrue,
      );
    });

    // One unreadable file is not worth the batch's archive: it is left out,
    // said in the log, and a move does not delete what never went in.
    test('a file that disappeared is left out and said in the log', () async {
      final FileItem one = await pick('Trip/beach.txt');
      final FileItem two = await pick('Trip/gone.txt');
      await File(two.sourcePath!).delete();

      expect(
        await zipSender().send(
          peer: peer,
          files: [one, two],
          move: true,
          asZip: true,
        ),
        TransferStatus.done,
      );

      expect(
        receivedArchive().files.map((ArchiveFile f) => f.name),
        ['Trip/beach.txt'],
      );
      expect(two.failed, isTrue);
      expect(two.done, isFalse);
      expect(await File(one.sourcePath!).exists(), isFalse);
      expect(
        xvTransfers.single.events.any(
          (TransferEvent event) => event.message == 'Could not pack the file',
        ),
        isTrue,
      );
    });

    // Nothing readable at all is a failed transfer and not an empty archive
    // sent to somebody as if it were their files.
    test('a batch with nothing readable fails before it is declared', () async {
      final FileItem item = await pick('Trip/gone.txt');
      await File(item.sourcePath!).delete();

      expect(
        await zipSender().send(peer: peer, files: [item], asZip: true),
        TransferStatus.failed,
      );
      expect(uploaded, isEmpty);
      expect(manifest, isEmpty);
    });

    // Without a place to build it there is no archive, and the transfer says so
    // instead of sending the batch file by file behind the user's back.
    test('no staging directory fails the transfer', () async {
      final FileItem item = await pick('Trip/beach.txt');
      final SendService service = SendService()
        ..zipStagingRootOf = (() async => null);

      expect(
        await service.send(peer: peer, files: [item], asZip: true),
        TransferStatus.failed,
      );
      expect(uploaded, isEmpty);
    });
  });

  group('the packer itself', () {
    test('a cancel before the isolate answers ends the pack', () async {
      final FileItem item = await pick('Trip/beach.txt');
      final ZipPacker packer = ZipPacker();
      final Future<PackResult> packing = packer.pack(
        files: [item],
        output: '${staging.path}/cancelled/Trip.zip',
        fingerprint: false,
      );
      packer.cancel();

      expect((await packing).outcome, PackOutcome.cancelled);
    });

    test('fingerprints are taken only when they are asked for', () async {
      final FileItem item = await pick('Trip/beach.txt');
      final ZipPacker packer = ZipPacker();

      final PackResult plain = await packer.pack(
        files: [item],
        output: '${staging.path}/plain/Trip.zip',
        fingerprint: false,
      );
      expect(plain.outcome, PackOutcome.packed);
      expect(plain.sources, isEmpty);

      final PackResult fingerprinted = await packer.pack(
        files: [item],
        output: '${staging.path}/fingerprinted/Trip.zip',
        fingerprint: true,
      );
      expect(fingerprinted.outcome, PackOutcome.packed);
      expect(fingerprinted.sources.single.id, item.id);
      expect(fingerprinted.sources.single.digest, isNotEmpty);
      expect(
        fingerprinted.sources.single.fingerprint.matches(
          File(item.sourcePath!).statSync(),
        ),
        isTrue,
      );
    });
  });

  // The encoder deflates a file into memory as a whole. Everything else here is
  // about not handing it something that will not fit.
  group('what goes in compressed and what goes in as it is', () {
    test('a photo or a video is stored, whatever its size', () {
      expect(zipStoresAsIs('holiday.JPG', 1024), isTrue);
      expect(zipStoresAsIs('clip.mp4', 1024), isTrue);
      expect(zipStoresAsIs('backup.zip', 1024), isTrue);
    });

    test('a document is compressed while it is small enough', () {
      expect(zipStoresAsIs('notes.txt', 1024), isFalse);
      expect(zipStoresAsIs('notes.txt', zipDeflateMaxBytes), isFalse);
    });

    test('anything past the memory limit is stored', () {
      expect(zipStoresAsIs('notes.txt', zipDeflateMaxBytes + 1), isTrue);
    });
  });

  group('what the archive is called', () {
    FileItem named(String relative) =>
        FileItem(id: relative, relativePath: relative, size: 1);

    final DateTime made = DateTime(2026, 2, 3, 4, 5, 6);

    test('one picked folder gives the archive its name', () {
      expect(
        zipArchiveName([named('Trip/a.txt'), named('Trip/b/c.txt')], made),
        'Trip.zip',
      );
    });

    test('anything else is stamped with the moment it was made', () {
      expect(zipArchiveName([named('a.txt')], made), 'EasySend-20260203-040506.zip');
      expect(
        zipArchiveName([named('Trip/a.txt'), named('Walk/b.txt')], made),
        'EasySend-20260203-040506.zip',
      );
      // A folder and a loose file: the folder does not speak for the batch.
      expect(
        zipArchiveName([named('Trip/a.txt'), named('b.txt')], made),
        'EasySend-20260203-040506.zip',
      );
    });

    test('a folder name with no room left for .zip takes the stamp', () {
      final String long = 'f' * 255;
      expect(
        zipArchiveName([named('$long/a.txt')], made),
        'EasySend-20260203-040506.zip',
      );
    });
  });
}
