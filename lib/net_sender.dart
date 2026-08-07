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
  final HttpClient _client = HttpClient();
  TransferSession? _current;
  String? _sessionId;
  Device? _peer;
  bool _cancelled = false;

  TransferSession? get current => _current;
  bool get busy => _current?.isRunning ?? false;

  Uri _url(Device peer, String path, [Map<String, String>? query]) =>
      Uri.http('${peer.address}:${peer.port}', '$apiPrefix/$path', query);

  Future<void> send({
    required Device peer,
    required List<FileItem> files,
  }) async {
    if (busy) return;
    _cancelled = false;
    _peer = peer;

    final TransferSession transfer = TransferSession(
      id: '',
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
      if (sessionId == null) return;
      _sessionId = sessionId;
      transfer.status = TransferStatus.active;
      transfersChanged();

      await _sendOneByOne(peer, transfer);
      if (_cancelled) return;

      await _post(_url(peer, 'finish', {'session': sessionId}));
      transfer.status = transfer.failedCount == 0
          ? TransferStatus.done
          : TransferStatus.partial;
    } on SocketException catch (e) {
      _fail(transfer, e.osError?.message ?? e.message);
    } catch (e) {
      _fail(transfer, '$e');
    } finally {
      _sessionId = null;
      transfersChanged();
    }
  }

  void _fail(TransferSession transfer, String message) {
    transfer.error = message;
    transfer.status = TransferStatus.failed;
    myPrint('send failed: $message');
  }

  // Ask permission first: nothing is streamed until the peer said yes.
  Future<String?> _prepare(Device peer, List<FileItem> files) async {
    final HttpClientRequest req = await _client.postUrl(_url(peer, 'prepare'));
    req.headers.contentType = ContentType.json;
    req.write(json.encode({
      'senderId': xvDeviceId,
      'senderName': xvDeviceName,
      'files': files.map((f) => f.toJson()).toList(),
    }));
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
  Future<bool> _sendFile(Device peer, TransferSession transfer, FileItem item, int settled) async {
    final String? source = item.sourcePath;
    if (source == null) return false;

    int crc = 0;
    int sent = 0;
    DateTime lastTick = DateTime.now();

    try {
      final HttpClientRequest req = await _client.postUrl(
        _url(peer, 'upload', {'session': _sessionId!, 'file': item.id}),
      );
      req.contentLength = item.size;
      await req.addStream(File(source).openRead().map((chunk) {
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
      }));
      final HttpClientResponse resp = await req.close();
      await resp.drain<void>();
      if (resp.statusCode != HttpStatus.ok) {
        myPrint('upload of ${item.relativePath} returned ${resp.statusCode}');
        return false;
      }

      final HttpClientResponse verify = await _post(_url(peer, 'verify', {
        'session': _sessionId!,
        'file': item.id,
        'crc': crc.toRadixString(16),
      }));
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
    final HttpClientRequest req = await _client.postUrl(uri);
    req.contentLength = 0;
    final HttpClientResponse resp = await req.close();
    await resp.drain<void>();
    return resp;
  }

  // Send again only what did not make it. The peer is looked up by id, so a new
  // address after a DHCP lease change is picked up automatically.
  Future<bool> retryFailed(TransferSession previous) async {
    if (!previous.canRetry || busy) return false;

    final int index = xvDevices.indexWhere((d) => d.id == previous.peerId);
    if (index < 0 || !xvDevices[index].online) return false;

    final List<FileItem> again = previous.files
        .where((f) => f.failed && f.sourcePath != null)
        .map((f) => FileItem(
              id: const Uuid().v4(),
              relativePath: f.relativePath,
              size: f.size,
              sourcePath: f.sourcePath,
            ))
        .toList();
    if (again.isEmpty) return false;

    await send(peer: xvDevices[index], files: again);
    return true;
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

    if (peer != null && sessionId != null) {
      try {
        await _post(_url(peer, 'cancel', {'session': sessionId}));
      } catch (e) {
        myPrint('cancel notice failed: $e');
      }
    }
  }
}

final SendService sender = SendService();
