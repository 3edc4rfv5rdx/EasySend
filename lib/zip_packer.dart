import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'file_helpers.dart';
import 'models.dart';

// One file as it went into the archive: the parts of a fingerprint, in the form
// that survives the trip back from the isolate. A Digest is rebuilt on the other
// side rather than sent, so nothing but plain data crosses.
class PackedSource {
  final String id;
  final int size;
  final DateTime modified;
  final DateTime changed;
  final int mode;
  final List<int> digest;

  const PackedSource({
    required this.id,
    required this.size,
    required this.modified,
    required this.changed,
    required this.mode,
    required this.digest,
  });

  SourceFingerprint get fingerprint => SourceFingerprint.parts(
    size: size,
    modified: modified,
    changed: changed,
    mode: mode,
    digest: Digest(digest),
  );
}

// A file the archive had to leave out, with the system's own words for why.
// Never translated here: the isolate has no locales loaded, and the text is
// what a bug report quotes.
class SkippedSource {
  final String id;
  final String reason;

  const SkippedSource(this.id, this.reason);
}

enum PackOutcome { packed, cancelled, failed }

class PackResult {
  final PackOutcome outcome;
  // Size of the finished archive, 0 unless it was finished.
  final int size;
  // System text for a failure, never a translated string.
  final String? error;
  // Only for the files that went in, and only when fingerprints were asked for.
  final List<PackedSource> sources;
  final List<SkippedSource> skipped;

  const PackResult({
    required this.outcome,
    this.size = 0,
    this.error,
    this.sources = const [],
    this.skipped = const [],
  });
}

// What the isolate is asked to do. Records and plain data only: everything here
// is copied across.
class _PackRequest {
  final SendPort replies;
  final String output;
  final List<({String id, String source, String name})> entries;
  final bool fingerprint;

  const _PackRequest(
    this.replies,
    this.output,
    this.entries,
    this.fingerprint,
  );
}

// One file is in, with what it cost. The bytes are the source's, not the
// archive's: the bar is measured against the batch the user picked.
class _PackProgress {
  final String id;
  final int bytes;

  const _PackProgress(this.id, this.bytes);
}

// Packing runs in an isolate of its own. Deflating a folder of photos is
// processor work measured in minutes, and on the app's isolate it would stop
// the screen, the discovery timers and the receive server along with it.
class ZipPacker {
  Isolate? _isolate;
  ReceivePort? _replies;
  Completer<PackResult>? _pending;
  bool _cancelling = false;

  bool get running => _pending != null;

  // Resolves once the archive is written, the packing failed, or the isolate was
  // killed from cancel(). Never throws: the outcome is the answer.
  Future<PackResult> pack({
    required List<FileItem> files,
    required String output,
    required bool fingerprint,
    void Function(String id, int bytes)? onFile,
  }) async {
    if (_pending != null) {
      return const PackResult(
        outcome: PackOutcome.failed,
        error: 'a pack is already running',
      );
    }
    _cancelling = false;
    final Completer<PackResult> done = Completer<PackResult>();
    _pending = done;
    final ReceivePort replies = ReceivePort();
    _replies = replies;
    replies.listen((Object? message) {
      if (message is _PackProgress) {
        onFile?.call(message.id, message.bytes);
        return;
      }
      if (message is PackResult) {
        _finish(message);
        return;
      }
      // Anything else is the isolate itself going: null from onExit, a pair of
      // strings from onError. Either way nothing is coming, and a killed pack
      // is a cancelled one — without this the send would wait for a message
      // that no longer has anyone to send it.
      _finish(
        PackResult(
          outcome: _cancelling ? PackOutcome.cancelled : PackOutcome.failed,
          error: message is List && message.isNotEmpty ? '${message.first}' : null,
        ),
      );
    });

    try {
      final Isolate spawned = await Isolate.spawn(
        _packWorker,
        _PackRequest(
          replies.sendPort,
          output,
          [
            for (final FileItem file in files)
              (
                id: file.id,
                source: file.sourcePath ?? '',
                name: file.relativePath,
              ),
          ],
          fingerprint,
        ),
        onExit: replies.sendPort,
        onError: replies.sendPort,
        errorsAreFatal: true,
      );
      // Cancelled while the isolate was still starting: it has nobody left to
      // answer, and left alone it would go on deflating the whole batch into a
      // file nothing will ever read.
      if (_cancelling) {
        spawned.kill(priority: Isolate.immediate);
      } else {
        _isolate = spawned;
      }
    } catch (e) {
      _finish(PackResult(outcome: PackOutcome.failed, error: '$e'));
    }
    return done.future;
  }

  // Stops the pack wherever it is, mid-file included: an archive nobody will
  // send is not worth the minutes it has left. The half-written file is the
  // caller's to remove, along with the directory it made for it.
  void cancel() {
    if (_pending == null) return;
    _cancelling = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    // A spawn that never got as far as an isolate still has to answer.
    _finish(const PackResult(outcome: PackOutcome.cancelled));
  }

  void _finish(PackResult result) {
    final Completer<PackResult>? pending = _pending;
    _pending = null;
    _isolate = null;
    _replies?.close();
    _replies = null;
    if (pending != null && !pending.isCompleted) pending.complete(result);
  }
}

// Runs in the spawned isolate: no globals, no locales, no Flutter. Everything
// it has to say goes back through the port as plain data.
Future<void> _packWorker(_PackRequest request) async {
  final ZipFileEncoder encoder = ZipFileEncoder();
  final List<PackedSource> sources = [];
  final List<SkippedSource> skipped = [];
  int packed = 0;
  try {
    await Directory(p.dirname(request.output)).create(recursive: true);
    encoder.create(request.output);
    for (final entry in request.entries) {
      final File file = File(entry.source);
      try {
        final FileStat stat = await file.stat();
        if (stat.type != FileSystemEntityType.file) {
          skipped.add(SkippedSource(entry.id, 'no longer a file'));
          continue;
        }
        // Taken before the bytes are read, exactly as a plain send takes it:
        // the fingerprint has to describe the file this archive holds.
        if (request.fingerprint) {
          sources.add(
            PackedSource(
              id: entry.id,
              size: stat.size,
              modified: stat.modified,
              changed: stat.changed,
              mode: stat.mode,
              digest: (await _digestOf(file)).bytes,
            ),
          );
        }
        // Built here rather than through addFile, which has no way to say that
        // a file is to be stored: the encoder deflates into memory, and a video
        // put through it would ask for its own size in RAM.
        final InputFileStream input = InputFileStream(entry.source);
        final ArchiveFile archived = ArchiveFile.stream(entry.name, input)
          ..lastModTime = stat.modified.millisecondsSinceEpoch ~/ 1000
          ..mode = stat.mode;
        if (zipStoresAsIs(entry.name, stat.size)) {
          archived.compression = CompressionType.none;
        }
        encoder.addArchiveFile(archived);
        await input.close();
        packed++;
        request.replies.send(_PackProgress(entry.id, stat.size));
      } catch (e) {
        // One unreadable file does not cost the batch its archive: it is left
        // out, said in the log, and a move will not delete what never went in.
        skipped.add(SkippedSource(entry.id, '$e'));
        sources.removeWhere((PackedSource s) => s.id == entry.id);
      }
    }
    await encoder.close();
    if (packed == 0) {
      request.replies.send(
        PackResult(
          outcome: PackOutcome.failed,
          error: 'nothing could be packed',
          skipped: skipped,
        ),
      );
      return;
    }
    request.replies.send(
      PackResult(
        outcome: PackOutcome.packed,
        size: await File(request.output).length(),
        sources: sources,
        skipped: skipped,
      ),
    );
  } catch (e) {
    try {
      await encoder.close();
    } catch (_) {
      // The archive is being abandoned; a close that fails changes nothing.
    }
    request.replies.send(
      PackResult(outcome: PackOutcome.failed, error: '$e', skipped: skipped),
    );
  }
}

// Streamed, never held: these are the same files the sender refuses to load
// whole, and the isolate has no more memory than the app does.
Future<Digest> _digestOf(File file) async {
  Digest? digest;
  final ByteConversionSink input = sha256.startChunkedConversion(
    ChunkedConversionSink<Digest>.withCallback(
      (List<Digest> digests) => digest = digests.single,
    ),
  );
  await for (final List<int> chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return digest!;
}
