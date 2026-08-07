import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'android_helpers.dart';
import 'globals.dart';

// Receiving side of a transfer in flight.
class _Incoming {
  final String sessionId;
  final TransferSession transfer;
  final Map<String, FileItem> byId;
  final Map<String, String> finalPaths; // fileId -> destination path
  final Map<String, int> crc = {};      // fileId -> checksum computed here
  int settledBytes = 0;                 // bytes of files already finished
  bool cancelled = false;               // set when the user stops the receive

  _Incoming({
    required this.sessionId,
    required this.transfer,
    required this.byId,
    required this.finalPaths,
  });
}

// HTTP receive server. Plain dart:io rather than shelf: six routes need no
// router, and streaming bodies are easier to control directly.
class ReceiveServer {
  HttpServer? _http;
  _Incoming? _current;

  // Set when the port could not be taken, shown as a banner on the main screen.
  String? bindError;

  bool get running => _http != null;

  Future<bool> start() async {
    await stop();
    final int port = currentPort;
    try {
      _http = await HttpServer.bind(InternetAddress.anyIPv4, port, shared: false);
      bindError = null;
    } on SocketException catch (e) {
      // Busy port must be visible, not a silent failure to receive.
      bindError = e.osError?.message ?? e.message;
      myPrint('server bind failed on $port: $bindError');
      _http = null;
      serverStateChanged();
      return false;
    }
    _http!.listen(_handle, onError: (Object e) => myPrint('server error: $e'));
    myPrint('receive server started on $port');
    serverStateChanged();
    return true;
  }

  Future<void> stop() async {
    await _http?.close(force: true);
    _http = null;
    serverStateChanged();
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final String path = req.uri.path;
      if (req.method == 'GET' && path == '$apiPrefix/info') {
        return _json(req, {
          'id': xvDeviceId,
          'name': xvDeviceName,
          'platform': xvPlatform,
          'version': progVersion,
        });
      }
      if (req.method == 'POST') {
        switch (path) {
          case '$apiPrefix/prepare':
            return await _prepare(req);
          case '$apiPrefix/upload':
            return await _upload(req);
          case '$apiPrefix/verify':
            return await _verify(req);
          case '$apiPrefix/finish':
            return await _finish(req);
          case '$apiPrefix/cancel':
            return await _cancel(req);
        }
      }
      await _status(req, HttpStatus.notFound);
    } catch (e, st) {
      myPrint('request failed: $e\n$st');
      try {
        await _status(req, HttpStatus.internalServerError);
      } catch (_) {
        // The client is already gone; nothing left to answer.
      }
    }
  }

  Future<void> _prepare(HttpRequest req) async {
    // One session at a time: parallel writes into the same folder would race.
    if (_current != null && _current!.transfer.isRunning) {
      return _json(req, {'reason': 'busy'}, status: HttpStatus.conflict);
    }

    final Map<String, dynamic> body = json.decode(await utf8.decoder.bind(req).join());
    final String senderId = body['senderId'] as String? ?? '';
    final String senderName = body['senderName'] as String? ?? senderId;
    final List<dynamic> rawFiles = body['files'] as List? ?? [];
    if (senderId.isEmpty || rawFiles.isEmpty) {
      return _status(req, HttpStatus.badRequest);
    }

    final List<FileItem> files = rawFiles
        .map((f) => FileItem.fromJson((f as Map).cast<String, dynamic>()))
        .toList();

    // Resolve every destination before answering: a manifest that cannot be
    // written safely is refused as a whole, not half-accepted.
    final Map<String, String> finalPaths = {};
    for (final FileItem f in files) {
      final String? dest = await resolveInside(xvRecvDir, f.relativePath);
      if (dest == null || f.size < 0) {
        myPrint('refused unsafe path: ${f.relativePath}');
        return _status(req, HttpStatus.badRequest);
      }
      finalPaths[f.id] = await uniquePath(dest);
    }

    final int totalBytes = files.fold(0, (sum, f) => sum + f.size);
    if (!await _askAccept(senderId, senderName, files.length, totalBytes)) {
      return _json(req, {'reason': 'declined'}, status: HttpStatus.forbidden);
    }

    final TransferSession transfer = TransferSession(
      id: const Uuid().v4(),
      incoming: true,
      peerName: senderName,
      files: files,
    );
    transfer.status = TransferStatus.active;
    xvTransfers.add(transfer);
    transfersChanged();

    _current = _Incoming(
      sessionId: transfer.id,
      transfer: transfer,
      byId: {for (final FileItem f in files) f.id: f},
      finalPaths: finalPaths,
    );
    return _json(req, {'sessionId': transfer.id});
  }

  // Trusted senders are accepted silently; an unknown one has to be confirmed,
  // and stays unconfirmed if nobody answers in time.
  Future<bool> _askAccept(String senderId, String senderName, int count, int bytes) async {
    final int known = xvDevices.indexWhere((d) => d.id == senderId);
    if (known >= 0 && xvDevices[known].trusted) return true;

    // Off screen there is nobody to show a dialog to; ask by notification.
    final bool accepted;
    bool trust = false;
    if (Platform.isAndroid && !appInForeground) {
      accepted = await askAcceptViaNotification(
        senderName: senderName,
        fileCount: count,
        totalBytes: bytes,
      );
    } else {
      (accepted, trust) = await showAcceptDialog(
        senderName: senderName,
        fileCount: count,
        totalBytes: bytes,
      );
    }
    if (accepted && trust) {
      if (known >= 0) {
        xvDevices[known].trusted = true;
      } else {
        xvDevices.add(Device(id: senderId, name: senderName, trusted: true));
      }
      await saveSettings();
      devicesChanged();
    }
    return accepted;
  }

  Future<void> _upload(HttpRequest req) async {
    final _Incoming? session = _sessionOf(req);
    final String fileId = req.uri.queryParameters['file'] ?? '';
    final FileItem? item = session?.byId[fileId];
    if (session == null || item == null) {
      return _status(req, HttpStatus.badRequest);
    }

    final String dest = session.finalPaths[fileId]!;
    final String partPath = '$dest$partSuffix';
    await Directory(p.dirname(dest)).create(recursive: true);

    final File part = File(partPath);
    final IOSink sink = part.openWrite();
    int written = 0;
    int crc = 0;
    DateTime lastTick = DateTime.now();
    bool overflow = false;

    try {
      await for (final List<int> chunk in req) {
        if (session.cancelled) break;
        written += chunk.length;
        // Never write past the declared size: the manifest is the contract.
        if (written > item.size) {
          overflow = true;
          break;
        }
        crc = getCrc32(chunk, crc);
        sink.add(chunk);

        final DateTime now = DateTime.now();
        if (now.difference(lastTick).inMilliseconds >= 100) {
          lastTick = now;
          session.transfer.noteProgress(session.settledBytes + written);
          transfersChanged();
        }
      }
      await sink.flush();
    } finally {
      await sink.close();
    }

    if (session.cancelled) {
      await _deleteQuietly(part);
      return _status(req, HttpStatus.conflict);
    }

    if (overflow || written != item.size) {
      await _deleteQuietly(part);
      myPrint('size mismatch for ${item.relativePath}: $written of ${item.size}');
      return _status(req, HttpStatus.badRequest);
    }

    session.crc[fileId] = crc;
    session.transfer.noteProgress(session.settledBytes + written);
    transfersChanged();
    return _json(req, {'ok': true});
  }

  // The sender only knows its checksum once the file has been fully read, so
  // the comparison arrives right after the body, not inside it.
  Future<void> _verify(HttpRequest req) async {
    final _Incoming? session = _sessionOf(req);
    final String fileId = req.uri.queryParameters['file'] ?? '';
    final FileItem? item = session?.byId[fileId];
    if (session == null || item == null) {
      return _status(req, HttpStatus.badRequest);
    }

    final int? theirs = int.tryParse(req.uri.queryParameters['crc'] ?? '', radix: 16);
    final int? ours = session.crc[fileId];
    final String dest = session.finalPaths[fileId]!;
    final File part = File('$dest$partSuffix');

    if (theirs == null || ours == null || theirs != ours) {
      await _deleteQuietly(part);
      session.crc.remove(fileId);
      myPrint('checksum mismatch for ${item.relativePath}');
      return _json(req, {'reason': 'crc'}, status: HttpStatus.conflict);
    }

    // Only now does the file get its real name: a partial file must never look
    // like a complete one.
    await part.rename(dest);
    item.done = true;
    item.failed = false;
    session.settledBytes += item.size;
    session.transfer.noteProgress(session.settledBytes);
    transfersChanged();
    return _json(req, {'ok': true});
  }

  Future<void> _finish(HttpRequest req) async {
    final _Incoming? session = _sessionOf(req);
    if (session == null) return _status(req, HttpStatus.badRequest);

    final TransferSession transfer = session.transfer;
    for (final FileItem f in transfer.files) {
      if (!f.done) f.failed = true;
    }
    transfer.status = transfer.failedCount == 0
        ? TransferStatus.done
        : TransferStatus.partial;
    await notifyTransferFinished(transfer.failedCount == 0
        ? '${lw('Received')}: ${transfer.doneCount} — ${formatBytes(transfer.bytesTotal)}'
        : '${lw('Received')} ${transfer.doneCount}/${transfer.files.length}, ${lw('failed')}: ${transfer.failedCount}');
    await _cleanupParts(session);
    _current = null;
    transfersChanged();
    return _json(req, {'ok': true});
  }

  Future<void> _cancel(HttpRequest req) async {
    final _Incoming? session = _sessionOf(req);
    if (session == null) return _status(req, HttpStatus.badRequest);
    await _abort(session, TransferStatus.cancelled);
    return _json(req, {'ok': true});
  }

  // Stop an incoming transfer from this side. The upload loop notices the flag
  // and drops what it was writing.
  Future<void> cancelCurrent() async {
    final _Incoming? session = _current;
    if (session == null || !session.transfer.isRunning) return;
    session.cancelled = true;
    await _abort(session, TransferStatus.cancelled);
  }

  Future<void> _abort(_Incoming session, TransferStatus status) async {
    session.transfer.status = status;
    await _cleanupParts(session);
    _current = null;
    transfersChanged();
  }

  // Files that never passed verification leave nothing behind.
  Future<void> _cleanupParts(_Incoming session) async {
    for (final String dest in session.finalPaths.values) {
      await _deleteQuietly(File('$dest$partSuffix'));
    }
  }

  _Incoming? _sessionOf(HttpRequest req) {
    final String id = req.uri.queryParameters['session'] ?? '';
    final _Incoming? session = _current;
    if (session == null || session.sessionId != id) return null;
    return session;
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (e) {
      myPrint('cannot delete ${file.path}: $e');
    }
  }

  Future<void> _json(HttpRequest req, Map<String, dynamic> body, {int status = HttpStatus.ok}) async {
    req.response.statusCode = status;
    req.response.headers.contentType = ContentType.json;
    req.response.write(json.encode(body));
    await req.response.close();
  }

  Future<void> _status(HttpRequest req, int status) async {
    req.response.statusCode = status;
    await req.response.close();
  }
}

final ReceiveServer receiveServer = ReceiveServer();
