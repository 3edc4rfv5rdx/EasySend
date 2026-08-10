import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';

import 'globals.dart';

// Thrown from inside the upload stream to stop it mid-file. Cancelling has to
// break the stream itself: a flag checked between files lets the current one
// finish, which is exactly what the user asked to avoid.
class _Cancelled implements Exception {
  const _Cancelled();
}

// Sending side. One transfer at a time, files strictly in sequence.
class SendService {
  HttpClient? _client;
  TransferSession? _current;
  String? _sessionId;
  Device? _peer;
  bool _cancelled = false;
  bool _inFlight = false;

  TransferSession? get current => _current;
  bool get busy => _inFlight;

  Uri _url(Device peer, String path, [Map<String, String>? query]) =>
      Uri.http('${peer.address}:${peer.port}', '$apiPrefix/$path', query);

  // Returns how it ended, so the caller can decide whether to clear the
  // selection: a failed or cancelled transfer must leave it alone.
  Future<TransferStatus> send({
    required Device peer,
    required List<FileItem> files,
  }) async {
    if (_inFlight) return TransferStatus.failed;
    _inFlight = true;
    _cancelled = false;
    _peer = peer;
    _client = HttpClient();

    final TransferSession transfer = TransferSession(
      id: const Uuid().v4(),
      incoming: false,
      peerName: peer.name,
      peerId: peer.id,
      files: files,
    );
    _current = transfer;
    xvTransfers.add(transfer);
    transfersChanged();

    try {
      final String? sessionId = await _prepare(peer, files);
      if (sessionId == null) return transfer.status;
      if (_cancelled) return transfer.status;
      _sessionId = sessionId;
      transfer.id = sessionId;
      transfer.status = TransferStatus.active;
      transfersChanged();

      await _sendOneByOne(peer, transfer);
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
        _fail(transfer, '$e');
        await _cancelRemoteBestEffort(peer);
      }
    } finally {
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
    myPrint('send failed: $message');
  }

  // Ask permission first: nothing is streamed until the peer said yes.
  Future<String?> _prepare(Device peer, List<FileItem> files) async {
    final HttpClientRequest req = await _client!.postUrl(_url(peer, 'prepare'));
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
    final HttpClientResponse resp = await req.close();
    final String body = await utf8.decoder.bind(resp).join();

    if (resp.statusCode == HttpStatus.ok) {
      return (json.decode(body) as Map)['sessionId'] as String?;
    }
    final TransferSession transfer = _current!;
    transfer.status = resp.statusCode == HttpStatus.forbidden
        ? TransferStatus.cancelled
        : TransferStatus.failed;
    transfer.error = resp.statusCode == HttpStatus.forbidden
        ? lw('Declined by receiver')
        : resp.statusCode == HttpStatus.conflict
        ? lw('Receiver is busy')
        : 'HTTP ${resp.statusCode}';
    return null;
  }

  Future<void> _sendOneByOne(Device peer, TransferSession transfer) async {
    int settled = 0;
    for (int i = 0; i < transfer.files.length; i++) {
      if (_cancelled) return;
      final FileItem item = transfer.files[i];
      transfer.currentIndex = i;

      bool ok = false;
      // A failed checksum is almost always a fluke, so retry quietly before
      // bothering anyone; the rest of the queue is not held up either way.
      for (int attempt = 0; attempt <= maxResendAttempts && !ok; attempt++) {
        if (_cancelled) return;
        ok = await _sendFile(peer, transfer, item, settled);
      }
      // Do not count an interrupted file as sent: the bar would run to the
      // end even though nothing arrived.
      if (_cancelled) return;
      item.done = ok;
      item.failed = !ok;
      settled += item.size;
      transfer.noteProgress(settled);
      transfersChanged();
    }
  }

  // Streams one file, then hands over the checksum computed while reading it.
  // addStream keeps the pipe under backpressure, so a huge file never lands in
  // memory as a whole.
  Future<bool> _sendFile(
    Device peer,
    TransferSession transfer,
    FileItem item,
    int settled,
  ) async {
    final String? source = item.sourcePath;
    if (source == null) return false;

    int crc = 0;
    int sent = 0;
    DateTime lastTick = DateTime.now();

    try {
      final HttpClientRequest req = await _client!.postUrl(
        _url(peer, 'upload', {'session': _sessionId!, 'file': item.id}),
      );
      req.contentLength = item.size;
      await req.addStream(
        File(source).openRead().map((chunk) {
          if (_cancelled) throw const _Cancelled();
          crc = getCrc32(chunk, crc);
          sent += chunk.length;
          final DateTime now = DateTime.now();
          if (now.difference(lastTick).inMilliseconds >= 100) {
            lastTick = now;
            transfer.noteProgress(settled + sent);
            transfersChanged();
          }
          return chunk;
        }),
      );
      final HttpClientResponse resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode != HttpStatus.ok) {
        myPrint('upload of ${item.relativePath} returned ${resp.statusCode}');
        return false;
      }

      final HttpClientResponse verify = await _post(
        _url(peer, 'verify', {
          'session': _sessionId!,
          'file': item.id,
          'crc': crc.toRadixString(16),
        }),
      );
      item.crc32 = crc;
      return verify.statusCode == HttpStatus.ok;
    } on _Cancelled {
      myPrint('upload of ${item.relativePath} cancelled');
      return false;
    } on SocketException {
      rethrow;
    } catch (e) {
      myPrint('sending ${item.relativePath} failed: $e');
      return false;
    }
  }

  Future<HttpClientResponse> _post(Uri uri) async {
    final HttpClientRequest req = await _client!.postUrl(uri);
    req.contentLength = 0;
    final HttpClientResponse resp = await req.close();
    await resp.drain<void>();
    return resp;
  }

  Future<void> _cancelRemoteBestEffort(Device peer) async {
    final String? sessionId = _sessionId;
    if (sessionId == null) return;
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.postUrl(
        _url(peer, 'cancel', {'session': sessionId}),
      );
      req.contentLength = 0;
      final HttpClientResponse response = await req.close();
      await response.drain<void>();
    } catch (e) {
      myPrint('terminal cancel notice failed: $e');
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
    transfersChanged();
    _client?.close(force: true);

    if (peer != null && sessionId != null) {
      await _cancelRemoteBestEffort(peer);
    }
  }
}

final SendService sender = SendService();
