import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'control_body.dart';
import 'globals.dart';
import 'net_discovery.dart';

// Thrown from inside the upload stream to stop it mid-file. Cancelling has to
// break the stream itself: a flag checked between files lets the current one
// finish, which is exactly what the user asked to avoid.
class _Cancelled implements Exception {
  const _Cancelled();
}

// How a file ended, and whether trying it again could change that. A checksum
// that did not match is worth another go; a file that is no longer what the
// manifest describes is not.
enum _FileResult { sent, retry, hopeless }

typedef _ProtocolResponse = ({int status, String body});

class _SourceFingerprint {
  final int size;
  final DateTime modified;
  final DateTime changed;
  final int mode;
  final Digest digest;

  _SourceFingerprint(FileStat stat, this.digest)
    : size = stat.size,
      modified = stat.modified,
      changed = stat.changed,
      mode = stat.mode;

  bool matches(FileStat stat) =>
      stat.type == FileSystemEntityType.file &&
      stat.size == size &&
      stat.modified == modified &&
      stat.changed == changed &&
      stat.mode == mode;
}

// Sending side. One transfer at a time, files strictly in sequence.
class SendService {
  final Duration connectTimeout;
  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration prepareTimeout;
  final Duration controlBodyTimeout;
  HttpClient? _client;
  TransferSession? _current;
  String? _sessionId;
  Device? _peer;
  bool _cancelled = false;
  bool _inFlight = false;
  final Map<String, _SourceFingerprint> _sentSources = {};

  SendService({
    this.connectTimeout = const Duration(seconds: networkConnectTimeoutSec),
    this.headerTimeout = const Duration(seconds: networkHeaderTimeoutSec),
    this.idleTimeout = const Duration(seconds: networkIdleTimeoutSec),
    this.prepareTimeout = const Duration(
      seconds: acceptTimeoutSec + consentTransportMarginSec,
    ),
    this.controlBodyTimeout = const Duration(
      seconds: protocolBodyTotalTimeoutSec,
    ),
  });

  TransferSession? get current => _current;
  bool get busy => _inFlight;

  // Where the platform keeps copies of picked documents. Off Android there are
  // none; a test replaces this to stand in for a phone's cache directory.
  @visibleForTesting
  Future<String?> Function() pickedCopiesRootOf = pickedCopiesRoot;

  Uri _url(Device peer, String path, [Map<String, String>? query]) =>
      Uri.http('${peer.address}:${peer.port}', '$apiPrefix/$path', query);

  // Returns how it ended, so the caller can decide whether to clear the
  // selection: a failed or cancelled transfer must leave it alone.
  // `move` deletes delivered sources only after the whole batch reaches a
  // non-cancelled terminal result. It is a decision about this one batch, never
  // a setting: the caller asks for it afresh every time.
  Future<TransferStatus> send({
    required Device peer,
    required List<FileItem> files,
    bool move = false,
    bool moveFolders = false,
  }) async {
    if (_inFlight) return TransferStatus.failed;
    _inFlight = true;
    _cancelled = false;
    _sentSources.clear();
    _peer = peer;
    _client = HttpClient()..connectionTimeout = connectTimeout;

    final TransferSession transfer = TransferSession(
      id: const Uuid().v4(),
      incoming: false,
      peerName: peer.name,
      peerId: peer.id,
      files: files,
    );
    _current = transfer;
    // Said once at the top: reading the log later, the deletions further down
    // should not be the first hint that this was a move.
    if (move) transfer.log('Sources are deleted after they arrive');
    xvTransfers.add(transfer);
    transfersChanged();

    try {
      if (peer.manual) {
        // Two ways to fail this, and the user can act on only one of them: a
        // device that has become somebody else needs its address checked, one
        // that did not answer needs turning on.
        final IdentityCheck identity = await manualPoller.verifyIdentity(peer);
        if (identity != IdentityCheck.confirmed) {
          _fail(
            transfer,
            lw(
              identity == IdentityCheck.changed
                  ? 'Device identity changed'
                  : 'Device is offline',
            ),
          );
          return transfer.status;
        }
      }
      final String? sessionId = await _prepare(peer, files);
      if (sessionId == null) return transfer.status;
      if (_cancelled) return transfer.status;
      _sessionId = sessionId;
      transfer.id = sessionId;
      transfer.status = TransferStatus.active;
      transfersChanged();

      await _sendOneByOne(peer, transfer, fingerprintSources: move);
      if (_cancelled) return transfer.status;

      final bool finished = await _finishRemote(peer, transfer, sessionId);
      // A finish that never landed is terminal whatever the files did: the
      // receiver never confirmed the transfer. Calling it partial gave a row
      // reading "3/3, failed: 0" under a status that means some did not make it,
      // with no Retry to offer because nothing was left to retry. _finishRemote
      // has already logged why and set the error this row will show.
      transfer.status = !finished
          ? TransferStatus.failed
          : transfer.failedCount == 0
          ? TransferStatus.done
          : TransferStatus.partial;
      // Deliberately still deleted after a failed finish: each of these got a
      // 200 from verify, so it did arrive and is published on the far side —
      // the best-effort cancel above does not take a published file back, and
      // the receiver marks that session unconfirmed rather than cancelled.
      // Should the receiver ever discard published files on cancel, this is the
      // line that becomes a data-loss bug (see ADD/tofix5.md finding 7).
      if (move) {
        final String? copies = await pickedCopiesRootOf();
        final List<FileItem> delivered = transfer.files
            .where((item) => item.done)
            .toList();
        // Files the app only ever held a copy of are left alone, and the rest of
        // the batch is moved as asked. Deleting a copy would remove the app's
        // own scratch file, leave the user's file exactly where it was, and say
        // in the log that the original had gone.
        int unreachable = 0;
        final List<FileItem> ours = [];
        for (final FileItem item in delivered) {
          final String? source = item.sourcePath;
          if (source != null && isAppOwnedCopy(source, copies)) {
            unreachable++;
            transfer.log(
              'Could not delete it here',
              file: item.relativePath,
              detail: lw('The app cannot reach the original'),
              failure: true,
            );
            continue;
          }
          await _deleteSource(transfer, item);
          ours.add(item);
        }
        if (moveFolders) await _deleteEmptySourceDirs(transfer, ours);
        // Said on screen as well as in the log: a move that quietly kept some
        // originals is exactly the thing nobody thinks to open a log about.
        // Best-effort like every other way of telling the user — a message that
        // cannot be shown must not turn a finished move into a failed transfer.
        if (unreachable > 0) {
          try {
            okInfoBarOrange(
              '${lw('The app cannot reach the original')}: $unreachable',
            );
          } catch (e) {
            myPrint('cannot report the originals left behind: $e');
          }
        }
      }
    } on SocketException catch (e) {
      if (!_cancelled) {
        _fail(transfer, e.osError?.message ?? e.message);
        await _cancelRemoteBestEffort(peer);
      }
    } catch (e) {
      if (!_cancelled) {
        _fail(transfer, _describeError(e));
        await _cancelRemoteBestEffort(peer);
      }
    } finally {
      // Nothing may leave a transfer running. A row stuck at pending or active
      // keeps the main button on Stop, holds the network open against every
      // teardown, and on Android keeps the foreground service with it.
      if (transfer.isRunning) {
        _fail(transfer, transfer.error ?? lw('The transfer did not start'));
      }
      _sessionId = null;
      _peer = null;
      _client?.close(force: true);
      _client = null;
      _sentSources.clear();
      _inFlight = false;
      transfersChanged();
    }
    return transfer.status;
  }

  void _fail(TransferSession transfer, String message) {
    transfer.error = message;
    transfer.status = TransferStatus.failed;
    transfer.log('Transfer failed', detail: message, failure: true);
  }

  String _describeError(Object error) {
    if (error is TimeoutException) {
      final String detail = error.message == null ? '' : ': ${error.message}';
      return '${lw('Connection timed out')}$detail';
    }
    return '$error';
  }

  Future<bool> _finishRemote(
    Device peer,
    TransferSession transfer,
    String sessionId,
  ) async {
    try {
      final _ProtocolResponse response = await _post(
        _url(peer, 'finish', {'session': sessionId}),
      );
      if (response.status == HttpStatus.ok) return true;
      final String detail = response.body.isEmpty
          ? 'HTTP ${response.status}'
          : 'HTTP ${response.status}: ${response.body}';
      transfer.error = 'HTTP ${response.status}';
      transfer.log(
        'The receiver did not finish the transfer',
        detail: detail,
        failure: true,
      );
    } catch (error) {
      final String detail = _describeError(error);
      transfer.error = detail;
      transfer.log(
        'The receiver did not finish the transfer',
        detail: detail,
        failure: true,
      );
    }
    await _cancelRemoteBestEffort(peer);
    return false;
  }

  // Ask permission first: nothing is streamed until the peer said yes.
  Future<String?> _prepare(Device peer, List<FileItem> files) async {
    final HttpClientRequest req = await _client!
        .postUrl(_url(peer, 'prepare'))
        .timeout(connectTimeout);
    req.headers.contentType = ContentType.json;
    req.write(
      json.encode({
        'senderId': xvDeviceId,
        'senderName': xvDeviceName,
        // Where to reach us back: the receiver sees our address on the connection
        // but has no way to know the port we listen on.
        'senderPort': currentPort,
        'files': files.map((f) => f.toJson()).toList(),
      }),
    );
    final HttpClientResponse resp = await req.close().timeout(prepareTimeout);
    final String body = await _readSmallBody(
      resp,
      inactivityTimeout: headerTimeout,
      totalTimeout: controlBodyTimeout,
    );

    final TransferSession transfer = _current!;
    if (resp.statusCode == HttpStatus.ok) {
      dynamic decoded;
      try {
        decoded = json.decode(body);
      } on FormatException {
        decoded = null;
      }
      final dynamic id = decoded is Map ? decoded['sessionId'] : null;
      // A session id is what every later request is addressed to. Without a
      // usable one there is nothing to continue, and the transfer has to say so
      // rather than sit at pending for the rest of the run.
      if (id is! String ||
          id.isEmpty ||
          utf8.encode(id).length > maxProtocolIdBytes) {
        _fail(transfer, lw('The receiver answered with no session'));
        return null;
      }
      return id;
    }
    final bool declined = resp.statusCode == HttpStatus.forbidden;
    final bool busy = resp.statusCode == HttpStatus.conflict;
    transfer.status = declined
        ? TransferStatus.cancelled
        : TransferStatus.failed;
    final String reason = declined
        ? 'Declined by receiver'
        : busy
        ? 'Receiver is busy'
        : 'The receiver refused the transfer';
    // The row shows an HTTP code for anything unnamed, because there is nothing
    // truer to say about it; the log keeps the code either way.
    transfer.error = declined || busy ? lw(reason) : 'HTTP ${resp.statusCode}';
    transfer.log(reason, detail: 'HTTP ${resp.statusCode}', failure: true);
    return null;
  }

  Future<void> _sendOneByOne(
    Device peer,
    TransferSession transfer, {
    required bool fingerprintSources,
  }) async {
    int settled = 0;
    for (int i = 0; i < transfer.files.length; i++) {
      if (_cancelled) return;
      final FileItem item = transfer.files[i];
      transfer.currentIndex = i;

      _FileResult result = _FileResult.retry;
      // A failed checksum is almost always a fluke, so retry quietly before
      // bothering anyone; the rest of the queue is not held up either way.
      for (
        int attempt = 0;
        attempt <= maxResendAttempts && result == _FileResult.retry;
        attempt++
      ) {
        if (_cancelled) return;
        result = await _sendFile(
          peer,
          transfer,
          item,
          settled,
          fingerprintSource: fingerprintSources,
        );
      }
      // Do not count an interrupted file as sent: the bar would run to the
      // end even though nothing arrived.
      if (_cancelled) return;
      item.done = result == _FileResult.sent;
      item.failed = !item.done;
      // Every file says how it ended, so the log answers the question the row
      // cannot: which of the three hundred was the one that did not go.
      transfer.log(
        item.done ? 'Sent' : 'Not sent',
        file: item.relativePath,
        failure: !item.done,
        // A file that simply went is the line the cap may drop; one that did
        // not, and the deletion that follows a move, are never dropped.
        routine: item.done,
      );
      settled += item.size;
      transfer.noteProgress(settled);
      transfersChanged();
    }
  }

  // Folders the move emptied, when the user asked for those too. Deepest first,
  // and each one is checked for being empty at the moment it is reached: a file
  // that failed to send, or one that was never part of this batch, keeps the
  // folder holding it and everything above it.
  Future<void> _deleteEmptySourceDirs(
    TransferSession transfer,
    List<FileItem> delivered,
  ) async {
    for (final String path in prunableSourceDirs(delivered)) {
      final Directory dir = Directory(path);
      try {
        if (!await dir.exists()) continue;
        if (!await dir.list(followLinks: false).isEmpty) continue;
        await dir.delete();
        transfer.log('Deleted here', file: p.basename(path));
      } catch (e) {
        transfer.log(
          'Could not delete it here',
          file: p.basename(path),
          detail: '$e',
          failure: true,
        );
      }
    }
  }

  // Empty folders are left standing unless the move was asked to take them:
  // removing what held the files is a second decision, and it is made in the UI.
  Future<void> _deleteSource(TransferSession transfer, FileItem item) async {
    final String? source = item.sourcePath;
    if (source == null) return;
    final File file = File(source);
    final _SourceFingerprint? sent = _sentSources[item.id];
    bool sameSource = sent != null;
    if (sameSource) {
      final FileStat before = await file.stat();
      sameSource = sent.matches(before);
      if (sameSource) {
        try {
          sameSource = await sha256.bind(file.openRead()).first == sent.digest;
          if (sameSource) sameSource = sent.matches(await file.stat());
        } catch (_) {
          sameSource = false;
        }
      }
    }
    if (!sameSource) {
      transfer.log(
        'Could not delete it here',
        file: item.relativePath,
        detail: lw('A file changed on disk'),
        failure: true,
      );
      return;
    }
    final bool gone = await deleteQuietly(file);
    transfer.log(
      gone ? 'Deleted here' : 'Could not delete it here',
      file: item.relativePath,
      failure: !gone,
    );
  }

  // Streams one file, then hands over the checksum computed while reading it.
  // addStream keeps the pipe under backpressure, so a huge file never lands in
  // memory as a whole.
  Future<_FileResult> _sendFile(
    Device peer,
    TransferSession transfer,
    FileItem item,
    int settled, {
    required bool fingerprintSource,
  }) async {
    final String? source = item.sourcePath;
    if (source == null) return _FileResult.hopeless;

    // The size came from the moment the file was picked, and the request
    // declares it up front. A file edited since then breaks that declaration
    // halfway through, in a way no number of retries can mend, and the peer
    // would only see a length that does not add up.
    final FileStat stat = await File(source).stat();
    if (stat.type != FileSystemEntityType.file) {
      transfer.error = lw('A file is no longer there');
      transfer.log(
        'A file is no longer there',
        file: item.relativePath,
        failure: true,
      );
      return _FileResult.hopeless;
    }
    if (stat.size != item.size) {
      transfer.error = lw('A file changed on disk');
      transfer.log(
        'A file changed on disk',
        file: item.relativePath,
        detail: '${stat.size} / ${item.size}',
        failure: true,
      );
      return _FileResult.hopeless;
    }

    int crc = 0;
    int sent = 0;
    DateTime lastTick = DateTime.now();
    Digest? sourceDigest;
    final digestOutput = fingerprintSource
        ? ChunkedConversionSink<Digest>.withCallback(
            (digests) => sourceDigest = digests.single,
          )
        : null;
    final digestInput = digestOutput == null
        ? null
        : sha256.startChunkedConversion(digestOutput);

    // The file is at the far end and named. The fingerprint is what lets a move
    // delete this source afterwards, and it is taken from the bytes this
    // attempt read — the window in which the source changes between the read
    // and the deletion is the one ADD/tofix4.md finding 3 accepts.
    _FileResult delivered() {
      final Digest? digest = sourceDigest;
      if (fingerprintSource && digest != null) {
        _sentSources[item.id] = _SourceFingerprint(stat, digest);
      }
      return _FileResult.sent;
    }

    try {
      final HttpClientRequest req = await _client!
          .postUrl(
            _url(peer, 'upload', {'session': _sessionId!, 'file': item.id}),
          )
          .timeout(connectTimeout);
      req.contentLength = item.size;
      await for (final List<int> chunk in File(source).openRead()) {
        if (_cancelled) throw const _Cancelled();
        crc = getCrc32(chunk, crc);
        digestInput?.add(chunk);
        sent += chunk.length;
        req.add(chunk);
        // Flush is the per-progress inactivity boundary. It resets for every
        // chunk, so a healthy multi-gigabyte file has no whole-file deadline.
        await req.flush().timeout(idleTimeout);
        final DateTime now = DateTime.now();
        if (now.difference(lastTick).inMilliseconds >= 100) {
          lastTick = now;
          transfer.noteProgress(settled + sent);
          transfersChanged();
        }
      }
      digestInput?.close();
      final HttpClientResponse resp = await req.close().timeout(headerTimeout);
      // Read rather than drained: a refusal says in its body which refusal it
      // is, and one of them means the file is already there.
      final String rejection = await _readSmallBody(
        resp,
        inactivityTimeout: headerTimeout,
        totalTimeout: controlBodyTimeout,
      );
      if (resp.statusCode != HttpStatus.ok) {
        if (_reasonOf(rejection) == reasonAlreadyVerified) {
          transfer.log(
            'The receiver already has this file',
            file: item.relativePath,
          );
          return delivered();
        }
        transfer.log(
          'The receiver rejected the file',
          file: item.relativePath,
          detail: 'HTTP ${resp.statusCode}',
          failure: true,
        );
        return _FileResult.retry;
      }

      final _ProtocolResponse verify = await _confirmDelivery(
        peer,
        transfer,
        item,
        crc,
      );
      item.crc32 = crc;
      if (verify.status == HttpStatus.ok) return delivered();
      // Each failed attempt writes its own line, so the number of them is what
      // says how many tries the file took.
      transfer.log(
        'Checksum did not match',
        file: item.relativePath,
        failure: true,
      );
      return _FileResult.retry;
    } on _Cancelled {
      transfer.log('Cancelled', file: item.relativePath);
      return _FileResult.hopeless;
    } on SocketException {
      rethrow;
    } catch (e) {
      transfer.log(
        'Sending failed',
        file: item.relativePath,
        detail: '$e',
        failure: true,
      );
      return _FileResult.retry;
    }
  }

  Future<_ProtocolResponse> _post(Uri uri) async {
    final HttpClientRequest req = await _client!
        .postUrl(uri)
        .timeout(connectTimeout);
    req.contentLength = 0;
    final HttpClientResponse resp = await req.close().timeout(headerTimeout);
    final String body = await _readSmallBody(
      resp,
      inactivityTimeout: headerTimeout,
      totalTimeout: controlBodyTimeout,
    );
    return (status: resp.statusCode, body: body);
  }

  // Ask again whether the file arrived, rather than send it again.
  //
  // The answer to verify is the only thing that says a file is at the far end,
  // and the receiver publishes the file before it sends that answer. A lost
  // answer therefore says nothing about the file: sending it a second time gets
  // the bytes refused, ends with a file the receiver counts as received and the
  // sender counts as failed, and offers a Retry that would publish a second
  // copy of it. Asked as quietly, and as many times, as SPEC 5.6.1 gives a
  // re-send. Out of attempts, the error goes to the caller: a re-upload is then
  // the only thing left to try, and a receiver that never saw the verify starts
  // that file over.
  Future<_ProtocolResponse> _confirmDelivery(
    Device peer,
    TransferSession transfer,
    FileItem item,
    int crc,
  ) async {
    for (int attempt = 0; ; attempt++) {
      if (_cancelled) throw const _Cancelled();
      try {
        return await _post(
          _url(peer, 'verify', {
            'session': _sessionId!,
            'file': item.id,
            'crc': crc.toRadixString(16),
          }),
        );
      } catch (error) {
        transfer.log(
          'The confirmation did not arrive',
          file: item.relativePath,
          detail: _describeError(error),
          failure: true,
        );
        if (attempt >= maxResendAttempts) rethrow;
      }
    }
  }

  // The `reason` a control answer carries, for the refusals that mean something
  // other than "that failed". Anything unreadable is no reason at all.
  String? _reasonOf(String body) {
    if (body.isEmpty) return null;
    try {
      final dynamic decoded = json.decode(body);
      final dynamic reason = decoded is Map ? decoded['reason'] : null;
      return reason is String ? reason : null;
    } on FormatException {
      return null;
    }
  }

  Future<String> _readSmallBody(
    HttpClientResponse response, {
    required Duration inactivityTimeout,
    required Duration totalTimeout,
  }) async {
    final List<int> bytes = await readBoundedControlBytes(
      response,
      limit: maxInfoBodyBytes,
      inactivityTimeout: inactivityTimeout,
      totalTimeout: totalTimeout,
      tooLarge: () => const FormatException('response body too large'),
      inactivityExpired: () =>
          TimeoutException('control body stopped', inactivityTimeout),
      totalExpired: () =>
          TimeoutException('control body deadline', totalTimeout),
    );
    return utf8.decode(bytes, allowMalformed: false);
  }

  Future<void> _cancelRemoteBestEffort(Device peer) async {
    final String? sessionId = _sessionId;
    if (sessionId == null) return;
    final HttpClient client = HttpClient()..connectionTimeout = connectTimeout;
    try {
      final HttpClientRequest req = await client
          .postUrl(_url(peer, 'cancel', {'session': sessionId}))
          .timeout(connectTimeout);
      req.contentLength = 0;
      final HttpClientResponse response = await req.close().timeout(
        headerTimeout,
      );
      await readBoundedControlBytes(
        response,
        limit: maxInfoBodyBytes,
        inactivityTimeout: headerTimeout,
        totalTimeout: controlBodyTimeout,
        tooLarge: () => const FormatException('response body too large'),
        inactivityExpired: () =>
            TimeoutException('control body stopped', headerTimeout),
        totalExpired: () =>
            TimeoutException('control body deadline', controlBodyTimeout),
      );
    } catch (e) {
      _current?.log('The receiver was not told', detail: '$e', failure: true);
    } finally {
      client.close(force: true);
    }
  }

  // Cancelling stops the stream here and tells the peer to drop its .part files.
  Future<void> cancel() async {
    final TransferSession? transfer = _current;
    final Device? peer = _peer;
    final String? sessionId = _sessionId;
    if (transfer == null || !transfer.isRunning) return;

    _cancelled = true;
    transfer.status = TransferStatus.cancelled;
    transfer.log('Cancelled');
    transfersChanged();
    _client?.close(force: true);

    if (peer != null && sessionId != null) {
      await _cancelRemoteBestEffort(peer);
    }
  }
}

final SendService sender = SendService();
