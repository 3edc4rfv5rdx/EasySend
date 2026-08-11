import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';

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

// Sending side. One transfer at a time, files strictly in sequence.
class SendService {
  final Duration connectTimeout;
  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration prepareTimeout;
  HttpClient? _client;
  TransferSession? _current;
  String? _sessionId;
  Device? _peer;
  bool _cancelled = false;
  bool _inFlight = false;

  SendService({
    this.connectTimeout = const Duration(seconds: networkConnectTimeoutSec),
    this.headerTimeout = const Duration(seconds: networkHeaderTimeoutSec),
    this.idleTimeout = const Duration(seconds: networkIdleTimeoutSec),
    this.prepareTimeout = const Duration(
      seconds: acceptTimeoutSec + consentTransportMarginSec,
    ),
  });

  TransferSession? get current => _current;
  bool get busy => _inFlight;

  Uri _url(Device peer, String path, [Map<String, String>? query]) =>
      Uri.http('${peer.address}:${peer.port}', '$apiPrefix/$path', query);

  // Returns how it ended, so the caller can decide whether to clear the
  // selection: a failed or cancelled transfer must leave it alone.
  // `move` deletes each source once that file has been received and verified on
  // the other side. It is a decision about this one batch, never a setting: the
  // caller asks for it afresh every time.
  Future<TransferStatus> send({
    required Device peer,
    required List<FileItem> files,
    bool move = false,
  }) async {
    if (_inFlight) return TransferStatus.failed;
    _inFlight = true;
    _cancelled = false;
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
      if (peer.manual && !await manualPoller.verifyIdentity(peer)) {
        _fail(transfer, lw('Device identity changed'));
        return transfer.status;
      }
      final String? sessionId = await _prepare(peer, files);
      if (sessionId == null) return transfer.status;
      if (_cancelled) return transfer.status;
      _sessionId = sessionId;
      transfer.id = sessionId;
      transfer.status = TransferStatus.active;
      transfersChanged();

      await _sendOneByOne(peer, transfer, move: move);
      if (_cancelled) return transfer.status;

      await _post(_url(peer, 'finish', {'session': sessionId}));
      transfer.status = transfer.failedCount == 0
          ? TransferStatus.done
          : TransferStatus.partial;
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
    final String body = await _readSmallBody(resp, timeout: headerTimeout);

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
    required bool move,
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
        result = await _sendFile(peer, transfer, item, settled);
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
      );
      // The file is the unit of atomicity (SPEC 5.6), so it is also the unit of
      // moving: this one is verified on the other side and nothing that happens
      // to the rest of the queue can take that back. A file that did not make it
      // stays where it is.
      if (move && item.done) await _deleteSource(transfer, item);
      settled += item.size;
      transfer.noteProgress(settled);
      transfersChanged();
    }
  }

  // Empty folders are left standing: the user asked for the files to move, and
  // removing what held them is a second decision nobody made here.
  Future<void> _deleteSource(TransferSession transfer, FileItem item) async {
    final String? source = item.sourcePath;
    if (source == null) return;
    final bool gone = await deleteQuietly(File(source));
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
    int settled,
  ) async {
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
      final HttpClientResponse resp = await req.close().timeout(headerTimeout);
      await _drainWithTimeout(resp);
      if (resp.statusCode != HttpStatus.ok) {
        transfer.log(
          'The receiver rejected the file',
          file: item.relativePath,
          detail: 'HTTP ${resp.statusCode}',
          failure: true,
        );
        return _FileResult.retry;
      }

      final HttpClientResponse verify = await _post(
        _url(peer, 'verify', {
          'session': _sessionId!,
          'file': item.id,
          'crc': crc.toRadixString(16),
        }),
      );
      item.crc32 = crc;
      if (verify.statusCode == HttpStatus.ok) return _FileResult.sent;
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

  Future<HttpClientResponse> _post(Uri uri) async {
    final HttpClientRequest req = await _client!
        .postUrl(uri)
        .timeout(connectTimeout);
    req.contentLength = 0;
    final HttpClientResponse resp = await req.close().timeout(headerTimeout);
    await _drainWithTimeout(resp);
    return resp;
  }

  Future<void> _drainWithTimeout(HttpClientResponse response) async {
    await response.drain<void>().timeout(headerTimeout);
  }

  Future<String> _readSmallBody(
    HttpClientResponse response, {
    required Duration timeout,
  }) async {
    final List<int> bytes = [];
    await for (final List<int> chunk in response.timeout(timeout)) {
      if (bytes.length + chunk.length > maxInfoBodyBytes) {
        throw const FormatException('response body too large');
      }
      bytes.addAll(chunk);
    }
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
      await response.drain<void>().timeout(headerTimeout);
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
