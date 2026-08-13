import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

import 'android_helpers.dart';
import 'control_body.dart';
import 'globals.dart';

enum _ReceivePhase {
  ready,
  uploading,
  verifying,
  awaitingVerification,
  finishing,
  cancelled,
}

// Why this process cannot claim to be receiving. `transition` is the one that
// is not about the listener itself: a step of bringing the network up or down
// threw, so what the screen shows and what the sockets are doing may disagree.
enum ReceiveReadinessFailure { folder, port, transition }

class _ProtocolProblem implements Exception {
  final int status;
  final String reason;
  const _ProtocolProblem(this.status, this.reason);
}

abstract interface class ReceiveFileWriter {
  Future<void> write(List<int> chunk);
  Future<void> close();
  Future<void> abort();
}

class _IoReceiveFileWriter implements ReceiveFileWriter {
  final IOSink _sink;
  Future<void>? _closeFuture;

  _IoReceiveFileWriter(File file) : _sink = file.openWrite();

  @override
  Future<void> write(List<int> chunk) async {
    _sink.add(chunk);
    // IOSink.add() only queues data. Waiting for flush couples the next network
    // read to the underlying file consumer and bounds the queued byte count.
    await _sink.flush();
  }

  @override
  Future<void> close() => _closeFuture ??= _sink.close();

  @override
  Future<void> abort() async {
    // dart:io does not support cancelling a flush in flight, and closing an
    // IOSink while flush owns it throws. Backpressure limits this wait to one
    // chunk; _upload observes the cancellation before reading another one.
  }
}

ReceiveFileWriter _openReceiveFileWriter(File file) =>
    _IoReceiveFileWriter(file);

// Where the connection says this peer can be reached, written down only once
// the transfer is on. Behind a router nothing else will ever say it: broadcast
// does not cross one, so a trusted device remembered without an address could
// never be sent to.
//
// Applied on acceptance rather than on arrival, because every line of it
// outlives the request. The address and port are persisted, and the manual flag
// keeps the entry in the list for good and has it polled while the app is on
// screen. A transfer the user refused must leave none of that behind.
//
// `wasOnline` is read when the request arrives, not when this runs: a device
// that merely fell quiet while the question stood on screen has not become one
// that only a poll can find.
void learnSenderAddress(
  Device device, {
  required String address,
  required int port,
  required bool wasOnline,
}) {
  // A loopback source is this machine talking to itself — a second copy of the
  // app, or an emulator behind NAT — and dialling it back would reach us.
  if (isReachableAddress(address)) {
    device.address = address;
    device.port = port;
    // Silent until it knocked on the door: discovery is not reaching it, so
    // only a poll will keep it in the list once the transfer is over.
    if (!wasOnline) device.manual = true;
  }
  device.lastSeen = DateTime.now();
}

// Receiving side of a transfer in flight.
class _Incoming {
  final String sessionId;
  // The folder this session was planned for. Settings may point somewhere else
  // by the time a file lands, and every destination here was resolved against
  // this one — checking them against a newer root would refuse them all.
  final String recvDir;
  // The same folder as the filesystem sees it, worked out once.
  final String resolvedRoot;
  final TransferSession transfer;
  final Map<String, FileItem> byId;
  final Map<String, String> finalPaths; // fileId -> destination path
  final Map<String, String> incompletePaths; // fileId -> owned temporary path
  final Map<String, int> progressOffsets; // fileId -> prior manifest bytes
  final Map<String, int> crc = {}; // fileId -> checksum computed here
  bool cancelled = false; // set when the user stops the receive
  _ReceivePhase phase = _ReceivePhase.ready;
  String? activeFileId;
  Completer<void>? activeOperation;
  Future<void> Function()? cancelActiveOperation;
  Timer? inactivityTimer;

  _Incoming({
    required this.sessionId,
    required this.recvDir,
    required this.resolvedRoot,
    required this.transfer,
    required this.byId,
    required this.finalPaths,
    required this.incompletePaths,
    required this.progressOffsets,
  });
}

// HTTP receive server. Plain dart:io rather than shelf: six routes need no
// router, and streaming bodies are easier to control directly.
class ReceiveServer {
  final Duration sessionTimeout;
  final Duration uploadIdleTimeout;
  final Duration controlBodyIdleTimeout;
  final Duration controlBodyTotalTimeout;
  final ReceiveFileWriter Function(File file) fileWriterFactory;
  HttpServer? _http;
  _Incoming? _current;
  bool _preparing = false;
  // Bumped by every stop. A prepare parked on the consent question holds no
  // socket, so nothing else tells it that the server it belongs to is gone.
  int _generation = 0;
  // Completed to take that question off the screen along with the server.
  Completer<void>? _consentAbort;

  // The consent question. Production asks the user — a dialog while the app is
  // on screen, a notification when it is not — and a test replaces this to hold
  // the answer back for as long as it needs.
  @visibleForTesting
  Future<(bool, bool)> Function({
    required String senderName,
    required int fileCount,
    required int totalBytes,
  })?
  askUser;

  // The completion notification. A test replaces this to fail it or to hold it
  // open while something else tries to end the same session.
  @visibleForTesting
  Future<void> Function(String text) notifyFinished = notifyTransferFinished;

  // Set when this process cannot truthfully advertise itself as a receiver.
  ReceiveReadinessFailure? readinessFailure;
  String? readinessError;

  // A step of the network transition failed somewhere other than here. The
  // listener may even be up, but the sequence that was supposed to bring
  // receiving into a known state did not finish, so readiness stops claiming
  // otherwise until a transition completes. The reason is kept deliberately
  // free of paths and addresses: it is shown on screen in a shipped build.
  void noteTransitionFailure() {
    readinessFailure = ReceiveReadinessFailure.transition;
    readinessError = 'network transition failed';
    serverStateChanged();
  }

  ReceiveServer({
    this.sessionTimeout = const Duration(seconds: receiveSessionTimeoutSec),
    this.uploadIdleTimeout = const Duration(seconds: networkIdleTimeoutSec),
    this.controlBodyIdleTimeout = const Duration(
      seconds: protocolBodyTimeoutSec,
    ),
    this.controlBodyTotalTimeout = const Duration(
      seconds: protocolBodyTotalTimeoutSec,
    ),
    ReceiveFileWriter Function(File file)? fileWriterFactory,
  }) : fileWriterFactory = fileWriterFactory ?? _openReceiveFileWriter;

  bool get running => _http != null;
  int? get boundPort => _http?.port;

  Future<bool> start() async {
    // Existing and newly created folders get the same capability check. A
    // listener already bound on this port must stop if storage disappears or
    // becomes unwritable while the app is away.
    if (!await canWriteInto(xvRecvDir)) {
      readinessFailure = ReceiveReadinessFailure.folder;
      readinessError = 'receive folder unavailable';
      if (running) {
        await stop();
      } else {
        serverStateChanged();
      }
      return false;
    }
    // Already listening where the settings point: rebinding would abort the
    // session in flight for nothing. Coming back to the foreground asks for a
    // start on every resume, and an incoming transfer has to survive that.
    if (running && boundPort == currentPort) {
      readinessFailure = null;
      readinessError = null;
      return true;
    }
    await stop();
    final int port = currentPort;
    try {
      _http = await HttpServer.bind(
        InternetAddress.anyIPv4,
        port,
        shared: false,
      );
      readinessFailure = null;
      readinessError = null;
    } on SocketException catch (e) {
      // Busy port must be visible, not a silent failure to receive.
      readinessFailure = ReceiveReadinessFailure.port;
      readinessError = e.osError?.message ?? e.message;
      myPrint('server bind failed on $port: $readinessError');
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
    // Before any await: a consent answered while this is running belongs to the
    // server that is going away, not to the one that may take its place.
    _generation++;
    _abortConsent();
    // A session already finishing keeps its outcome: its files are verified and
    // its own cleanup is running. Marking it cancelled here would make the row
    // disagree with what the sender was told.
    final _Incoming? session = _current?.phase == _ReceivePhase.finishing
        ? null
        : _current;
    if (session != null) {
      session.cancelled = true;
      session.phase = _ReceivePhase.cancelled;
      session.transfer.log('Receiving stopped');
    }
    await _http?.close(force: true);
    _http = null;
    if (session != null) {
      await _abort(session, TransferStatus.cancelled);
    }
    _preparing = false;
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
    if (_preparing || _current != null) {
      return _json(req, {'reason': 'busy'}, status: HttpStatus.conflict);
    }

    // Reserve the one receive slot before body parsing or the consent await.
    _preparing = true;
    final int generation = _generation;
    try {
      if (req.headers.contentType?.mimeType != ContentType.json.mimeType) {
        throw const _ProtocolProblem(
          HttpStatus.unsupportedMediaType,
          'content-type',
        );
      }
      final dynamic decoded = json.decode(
        await _readRequestText(req, maxPrepareBodyBytes),
      );
      if (decoded is! Map) {
        throw const _ProtocolProblem(HttpStatus.badRequest, 'json-object');
      }
      final Map<String, dynamic> body;
      try {
        body = decoded.cast<String, dynamic>();
      } catch (_) {
        throw const _ProtocolProblem(HttpStatus.badRequest, 'json-object');
      }
      final dynamic rawSenderId = body['senderId'];
      final dynamic rawSenderName = body['senderName'];
      final dynamic rawManifest = body['files'];
      if (rawSenderId is! String ||
          rawSenderId.isEmpty ||
          utf8.encode(rawSenderId).length > maxProtocolIdBytes ||
          rawSenderName is! String ||
          !isValidDeviceName(rawSenderName, allowEmpty: true) ||
          rawManifest is! List ||
          rawManifest.isEmpty ||
          rawManifest.length > maxManifestFiles) {
        throw const _ProtocolProblem(HttpStatus.badRequest, 'manifest-shape');
      }
      final String senderId = rawSenderId;
      final String senderName = rawSenderName.isEmpty
          ? senderId
          : rawSenderName;
      final List<FileItem> files = [];
      int totalBytes = 0;
      for (final dynamic raw in rawManifest) {
        if (raw is! Map) {
          throw const _ProtocolProblem(HttpStatus.badRequest, 'file-shape');
        }
        final Map<String, dynamic> data;
        try {
          data = raw.cast<String, dynamic>();
        } catch (_) {
          throw const _ProtocolProblem(HttpStatus.badRequest, 'file-shape');
        }
        final dynamic id = data['id'];
        final dynamic path = data['path'];
        final dynamic size = data['size'];
        if (id is! String ||
            id.isEmpty ||
            utf8.encode(id).length > maxProtocolIdBytes ||
            path is! String ||
            size is! int ||
            size < 0 ||
            size > maxDeclaredFileBytes) {
          throw const _ProtocolProblem(HttpStatus.badRequest, 'file-shape');
        }
        totalBytes += size;
        if (totalBytes > maxDeclaredTransferBytes) {
          throw const _ProtocolProblem(HttpStatus.badRequest, 'total-size');
        }
        files.add(FileItem(id: id, relativePath: path, size: size));
      }

      // Resolve every destination before answering: a manifest that cannot be
      // written safely is refused as a whole, not half-accepted. The folder is
      // read once here and carried by the session from now on.
      final String recvDir = xvRecvDir;
      final Map<String, String> finalPaths;
      final String root;
      try {
        final String? resolved = await resolveReceiveRoot(recvDir);
        if (resolved == null) {
          throw const DestinationPlanException('receive folder unavailable');
        }
        root = resolved;
        finalPaths = await buildDestinationPlan(recvDir, files);
        for (final String dest in finalPaths.values) {
          if (!await ensureSafeDestination(recvDir, dest, resolvedRoot: root)) {
            throw const DestinationPlanException('unsafe filesystem component');
          }
        }
      } on DestinationPlanException catch (e) {
        myPrint('refused manifest: $e');
        return _json(req, {'reason': e.reason}, status: HttpStatus.badRequest);
      }

      if (!await _askAccept(
        senderId,
        senderName,
        files.length,
        totalBytes,
        address: req.connectionInfo?.remoteAddress.address ?? '',
        port: _senderPort(body['senderPort']),
      )) {
        return _json(req, {'reason': 'declined'}, status: HttpStatus.forbidden);
      }

      // The answer can arrive after the server was torn down — the app was put
      // away with the question still on screen, or the port changed. Installing
      // a session now would leave a receiver that answers 'busy' to everyone
      // until its own deadline expires, over a transfer nobody can finish.
      if (generation != _generation) {
        myPrint('consent arrived after the server stopped, dropping it');
        return _json(req, {
          'reason': 'stopped',
        }, status: HttpStatus.serviceUnavailable);
      }

      final TransferSession transfer = TransferSession(
        id: const Uuid().v4(),
        incoming: true,
        peerName: senderName,
        files: files,
      );
      for (final FileItem file in files) {
        file.destinationPath = finalPaths[file.id];
      }
      transfer.status = TransferStatus.active;
      xvTransfers.add(transfer);
      transfersChanged();

      _current = _Incoming(
        sessionId: transfer.id,
        recvDir: recvDir,
        resolvedRoot: root,
        transfer: transfer,
        byId: {for (final FileItem f in files) f.id: f},
        finalPaths: finalPaths,
        incompletePaths: {
          for (int i = 0; i < files.length; i++)
            files[i].id: incompleteFilePath(recvDir, transfer.id, i),
        },
        progressOffsets: _manifestProgressOffsets(files),
      );
      _touch(_current!);
      return _json(req, {'sessionId': transfer.id});
    } on _ProtocolProblem catch (e) {
      return _json(req, {'reason': e.reason}, status: e.status);
    } on FormatException {
      return _json(req, {
        'reason': 'invalid-json',
      }, status: HttpStatus.badRequest);
    } finally {
      // Only the prepare that still owns the slot may release it: a stale one
      // would be handing away a slot a newer prepare has already taken.
      if (generation == _generation) _preparing = false;
    }
  }

  // Trusted senders are accepted silently; an unknown one has to be confirmed,
  // and stays unconfirmed if nobody answers in time.
  Future<bool> _askAccept(
    String senderId,
    String senderName,
    int count,
    int bytes, {
    required String address,
    required int port,
  }) async {
    // A sender carrying our own id is this machine talking to itself: a second
    // copy of the app started alongside the first. The transfer is still worth
    // accepting, but nothing about it belongs in the list of other devices.
    final bool self = senderId == xvDeviceId;
    final bool reachable = !self && isReachableAddress(address);
    final int known = self ? -1 : xvDevices.indexWhere((d) => d.id == senderId);
    // Read now, acted on later: whether discovery was reaching this device at
    // the moment it knocked, and not thirty seconds afterwards. A device that
    // merely fell quiet while the question stood on screen has not become one
    // that only a poll can find.
    final bool wasOnline = known >= 0 && xvDevices[known].online;
    // A trusted sender is accepted here and now, so what the connection says
    // about it can be written down here and now too.
    if (known >= 0 && xvDevices[known].trusted) {
      learnSenderAddress(
        xvDevices[known],
        address: address,
        port: port,
        wasOnline: wasOnline,
      );
      await saveSettings();
      devicesChanged();
      return true;
    }

    // Off screen there is nobody to show a dialog to; ask by notification.
    // Either way the question is withdrawn if the server stops underneath it:
    // an answer nobody can act on should not sit there asking to be given.
    final Completer<void> abort = Completer<void>();
    _consentAbort = abort;
    final bool accepted;
    bool trust = false;
    final Future<(bool, bool)> Function({
      required String senderName,
      required int fileCount,
      required int totalBytes,
    })?
    prompt = askUser;
    if (prompt != null) {
      (accepted, trust) = await prompt(
        senderName: senderName,
        fileCount: count,
        totalBytes: bytes,
      );
    } else if (Platform.isAndroid && !appInForeground) {
      accepted = await askAcceptViaNotification(
        senderName: senderName,
        fileCount: count,
        totalBytes: bytes,
        cancelled: abort.future,
      );
    } else {
      (accepted, trust) = await showAcceptDialog(
        senderName: senderName,
        fileCount: count,
        totalBytes: bytes,
        cancelled: abort.future,
      );
    }
    if (identical(_consentAbort, abort)) _consentAbort = null;
    if (accepted && !self) {
      // Resolved again instead of through the index taken before the question:
      // the list does not hold still for thirty seconds. Discovery adds entries,
      // forgets silent ones and evicts transient ones while the dialog stands
      // there, and the old index could by now name somebody else entirely.
      final int now = xvDevices.indexWhere((d) => d.id == senderId);
      if (now >= 0) {
        final Device device = xvDevices[now];
        learnSenderAddress(
          device,
          address: address,
          port: port,
          wasOnline: wasOnline,
        );
        if (trust) device.trusted = true;
        await saveSettings();
        devicesChanged();
      } else if (trust) {
        xvDevices.add(
          Device(
            id: senderId,
            name: senderName,
            address: reachable ? address : '',
            port: port,
            // Nothing announced this one to us, so only an HTTP poll can keep it
            // in the list — which is what manual means here.
            manual: reachable,
            trusted: true,
            lastSeen: DateTime.now(),
          ),
        );
        await saveSettings();
        devicesChanged();
      }
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
    if (session.phase != _ReceivePhase.ready || item.done) {
      session.transfer.log(
        'Unexpected request',
        file: item.relativePath,
        detail: 'upload, ${session.phase.name}',
        failure: true,
      );
      return _json(req, {
        'reason': 'out-of-order',
      }, status: HttpStatus.conflict);
    }
    session.phase = _ReceivePhase.uploading;
    session.activeFileId = fileId;
    session.activeOperation = Completer<void>();
    session.transfer.currentIndex = session.transfer.files.indexOf(item);
    transfersChanged();

    File? part;
    try {
      final String dest = session.finalPaths[fileId]!;
      final String partPath = session.incompletePaths[fileId]!;
      if (!await ensureIncompleteSessionDirectory(
        session.recvDir,
        session.sessionId,
        resolvedRoot: session.resolvedRoot,
      )) {
        session.transfer.log(
          'Cannot write here',
          file: item.relativePath,
          failure: true,
        );
        session.phase = _ReceivePhase.ready;
        return _status(req, HttpStatus.badRequest);
      }
      if (!await ensureSafeDestination(
            session.recvDir,
            dest,
            createParents: true,
            resolvedRoot: session.resolvedRoot,
          ) ||
          !await ensureSafeDestination(
            session.recvDir,
            partPath,
            createParents: true,
            resolvedRoot: session.resolvedRoot,
          )) {
        session.transfer.log(
          'Cannot write here',
          file: item.relativePath,
          failure: true,
        );
        session.phase = _ReceivePhase.ready;
        return _status(req, HttpStatus.badRequest);
      }

      part = File(partPath);
      final ReceiveFileWriter writer = fileWriterFactory(part);
      session.cancelActiveOperation = writer.abort;
      int written = 0;
      int crc = 0;
      DateTime lastTick = DateTime.now();
      bool overflow = false;
      final StreamIterator<List<int>> chunks = StreamIterator<List<int>>(req);

      try {
        while (await chunks.moveNext().timeout(
          uploadIdleTimeout,
          onTimeout: () => throw TimeoutException(
            'upload made no progress',
            uploadIdleTimeout,
          ),
        )) {
          if (session.cancelled) break;
          final List<int> chunk = chunks.current;
          written += chunk.length;
          // Never write past the declared size: the manifest is the contract.
          if (written > item.size) {
            overflow = true;
            break;
          }
          crc = getCrc32(chunk, crc);
          await writer.write(chunk);

          final DateTime now = DateTime.now();
          if (now.difference(lastTick).inMilliseconds >= 100) {
            lastTick = now;
            // Refreshed on the same tick as the progress, not on every chunk:
            // a stalled upload is already caught by the stream's own idle
            // timeout, and this deadline only has to outlive that.
            _touch(session);
            session.transfer.noteProgress(
              session.progressOffsets[fileId]! + written,
            );
            transfersChanged();
          }
        }
      } finally {
        await chunks.cancel();
        await writer.close();
      }

      if (session.cancelled) {
        await deleteQuietly(part);
        return _status(req, HttpStatus.conflict);
      }

      if (overflow || written != item.size) {
        await deleteQuietly(part);
        session.transfer.log(
          'Size does not match',
          file: item.relativePath,
          detail: '$written / ${item.size}',
          failure: true,
        );
        session.phase = _ReceivePhase.ready;
        return _status(req, HttpStatus.badRequest);
      }

      session.crc[fileId] = crc;
      _touch(session);
      session.phase = _ReceivePhase.awaitingVerification;
      session.transfer.noteProgress(session.progressOffsets[fileId]! + written);
      transfersChanged();
      return _json(req, {'ok': true});
    } on TimeoutException {
      if (part != null) await deleteQuietly(part);
      session.transfer.log(
        'The file stopped arriving',
        file: item.relativePath,
        failure: true,
      );
      session.phase = _ReceivePhase.ready;
      return _json(req, {
        'reason': 'upload-timeout',
      }, status: HttpStatus.requestTimeout);
    } catch (error) {
      if (part != null) await deleteQuietly(part);
      if (session.cancelled) return _status(req, HttpStatus.conflict);
      session.transfer.log(
        'Cannot write here',
        file: item.relativePath,
        detail: '$error',
        failure: true,
      );
      session.phase = _ReceivePhase.ready;
      return _json(req, {
        'reason': 'write-failed',
      }, status: HttpStatus.internalServerError);
    } finally {
      _endOperation(
        session,
        keepFile: session.phase == _ReceivePhase.awaitingVerification,
      );
    }
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
    if (session.phase != _ReceivePhase.awaitingVerification ||
        session.activeFileId != fileId ||
        item.done) {
      session.transfer.log(
        'Unexpected request',
        file: item.relativePath,
        detail: 'verify, ${session.phase.name}',
        failure: true,
      );
      return _json(req, {
        'reason': 'out-of-order',
      }, status: HttpStatus.conflict);
    }
    session.phase = _ReceivePhase.verifying;
    session.activeOperation = Completer<void>();

    try {
      final int? theirs = int.tryParse(
        req.uri.queryParameters['crc'] ?? '',
        radix: 16,
      );
      final int? ours = session.crc[fileId];
      String dest = session.finalPaths[fileId]!;
      final File part = File(session.incompletePaths[fileId]!);

      if (theirs == null || ours == null || theirs != ours) {
        await deleteQuietly(part);
        session.crc.remove(fileId);
        session.transfer.log(
          'Checksum did not match',
          file: item.relativePath,
          failure: true,
        );
        session.phase = _ReceivePhase.ready;
        return _json(req, {'reason': 'crc'}, status: HttpStatus.conflict);
      }

      // Only now does the file get its real name: a partial file must never look
      // like a complete one. Publication claims the name before it renames, so
      // an entry that appears between the two keeps its place and this file
      // takes the next free name instead.
      final Set<String> reserved = {
        for (final entry in session.finalPaths.entries)
          if (entry.key != fileId) pathEqualityKey(entry.value),
      };
      final String? published =
          await ensureSafeDestination(
            session.recvDir,
            part.path,
            resolvedRoot: session.resolvedRoot,
          )
          ? await publishVerifiedFile(
              part,
              dest,
              accept: (String candidate) => ensureSafeDestination(
                session.recvDir,
                candidate,
                resolvedRoot: session.resolvedRoot,
              ),
              reserved: reserved,
            )
          : null;
      if (published == null) {
        await deleteQuietly(part);
        session.transfer.log(
          'Cannot write here',
          file: item.relativePath,
          failure: true,
        );
        session.phase = _ReceivePhase.ready;
        return _status(req, HttpStatus.conflict);
      }
      dest = published;
      session.finalPaths[fileId] = dest;
      item.destinationPath = dest;
      item.done = true;
      item.failed = false;
      session.transfer.log(
        'Received',
        file: item.relativePath,
        // Nothing to report about this one, so it is the first line the cap
        // takes back when a transfer of thousands fills the log.
        routine: true,
      );
      session.transfer.noteProgress(
        session.progressOffsets[fileId]! + item.size,
      );
      _touch(session);
      session.phase = _ReceivePhase.ready;
      transfersChanged();
      return _json(req, {'ok': true});
    } finally {
      if (session.phase == _ReceivePhase.verifying) {
        session.phase = _ReceivePhase.ready;
      }
      _endOperation(session);
    }
  }

  Future<void> _finish(HttpRequest req) async {
    final _Incoming? session = _sessionOf(req);
    if (session == null) return _status(req, HttpStatus.badRequest);
    if (session.phase != _ReceivePhase.ready) {
      return _json(req, {
        'reason': 'out-of-order',
      }, status: HttpStatus.conflict);
    }
    // From here this session is over and nothing else may decide otherwise:
    // every file it holds is either verified and published or missed, and a
    // cancel arriving during the notification would only rewrite a settled
    // outcome. The inactivity timer goes with it — the session is no longer
    // waiting for anything.
    session.phase = _ReceivePhase.finishing;
    session.inactivityTimer?.cancel();

    final TransferSession transfer = session.transfer;
    try {
      for (final FileItem f in transfer.files) {
        if (f.done) continue;
        f.failed = true;
        // The sender gave up on this one and moved past it; from here it simply
        // never arrived, and the log has to say so for every such file.
        transfer.log('Not received', file: f.relativePath, failure: true);
      }
      transfer.status = transfer.failedCount == 0
          ? TransferStatus.done
          : TransferStatus.partial;
      transfer.noteProgress(transfer.bytesTotal);
      try {
        await notifyFinished(
          transfer.failedCount == 0
              ? '${lw('Received')}: ${transfer.doneCount} — ${formatBytes(transfer.bytesTotal)}'
              : '${lw('Received')} ${transfer.doneCount}/${transfer.files.length}, ${lw('failed')}: ${transfer.failedCount}',
        );
      } catch (e) {
        // Telling the user is best-effort. A notification that cannot be posted
        // changes nothing about the files that did arrive, and it must not cost
        // the sender its answer or leave the receive slot occupied.
        myPrint('cannot notify about the finished transfer: $e');
      }
    } finally {
      // Exactly once, whatever happened above.
      await _cleanupParts(session);
      if (_current == session) _current = null;
      transfersChanged();
    }
    return _json(req, {'ok': true});
  }

  Future<void> _cancel(HttpRequest req) async {
    final _Incoming? session = _sessionOf(req);
    if (session == null) return _status(req, HttpStatus.badRequest);
    if (session.phase == _ReceivePhase.finishing) {
      return _json(req, {
        'reason': 'out-of-order',
      }, status: HttpStatus.conflict);
    }
    session.transfer.log('Cancelled by the sender');
    await _abort(session, TransferStatus.cancelled);
    return _json(req, {'ok': true});
  }

  // Stop an incoming transfer from this side. The upload loop notices the flag
  // and drops what it was writing.
  Future<void> cancelCurrent() async {
    final _Incoming? session = _current;
    if (session == null || !session.transfer.isRunning) return;
    // Finish has already committed this transfer's outcome.
    if (session.phase == _ReceivePhase.finishing) return;
    session.cancelled = true;
    session.transfer.log('Cancelled');
    await _abort(session, TransferStatus.cancelled);
  }

  Future<void> _abort(_Incoming session, TransferStatus status) async {
    if (session.cancelled &&
        session.phase == _ReceivePhase.cancelled &&
        _current != session) {
      return;
    }
    session.cancelled = true;
    session.phase = _ReceivePhase.cancelled;
    session.inactivityTimer?.cancel();
    final Future<void>? active = session.activeOperation?.future;
    final Future<void> Function()? cancelActive = session.cancelActiveOperation;
    if (cancelActive != null) {
      try {
        await cancelActive();
      } catch (error) {
        myPrint('cannot abort active receive write: $error');
      }
    }
    if (active != null) await active;
    session.transfer.status = status;
    await _cleanupParts(session);
    // Only if it is still this session's slot: a prepare that arrived while
    // this abort was awaiting owns it now.
    if (_current == session) _current = null;
    transfersChanged();
  }

  // Files that never passed verification leave nothing behind, and neither
  // does the ownership record that let startup recovery clean up after a crash.
  Future<void> _cleanupParts(_Incoming session) async {
    await discardIncompleteSession(session.recvDir, session.sessionId);
  }

  _Incoming? _sessionOf(HttpRequest req) {
    final String id = req.uri.queryParameters['session'] ?? '';
    final _Incoming? session = _current;
    if (session == null || session.sessionId != id) return null;
    return session;
  }

  void _endOperation(_Incoming session, {bool keepFile = false}) {
    final Completer<void>? operation = session.activeOperation;
    if (operation != null && !operation.isCompleted) operation.complete();
    session.activeOperation = null;
    session.cancelActiveOperation = null;
    if (!keepFile) session.activeFileId = null;
    if (session.phase == _ReceivePhase.uploading ||
        session.phase == _ReceivePhase.verifying) {
      session.phase = _ReceivePhase.ready;
    }
  }

  void _abortConsent() {
    final Completer<void>? abort = _consentAbort;
    _consentAbort = null;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void _touch(_Incoming session) {
    session.inactivityTimer?.cancel();
    session.inactivityTimer = Timer(sessionTimeout, () async {
      if (_current != session || session.cancelled) return;
      session.transfer.error = lw('Connection timed out');
      session.transfer.log('Connection timed out', failure: true);
      await _abort(session, TransferStatus.failed);
    });
  }

  int _senderPort(dynamic value) {
    if (value == null) return currentPort;
    if (value is! int || value < 1 || value > 65535) {
      throw const _ProtocolProblem(HttpStatus.badRequest, 'sender-port');
    }
    return value;
  }

  Map<String, int> _manifestProgressOffsets(List<FileItem> files) {
    int offset = 0;
    final Map<String, int> result = {};
    for (final FileItem file in files) {
      result[file.id] = offset;
      offset += file.size;
    }
    return result;
  }

  Future<String> _readRequestText(HttpRequest request, int limit) async {
    final List<int> bytes = await readBoundedControlBytes(
      request,
      limit: limit,
      inactivityTimeout: controlBodyIdleTimeout,
      totalTimeout: controlBodyTotalTimeout,
      tooLarge: () => const _ProtocolProblem(
        HttpStatus.requestEntityTooLarge,
        'body-too-large',
      ),
      inactivityExpired: () =>
          const _ProtocolProblem(HttpStatus.requestTimeout, 'body-timeout'),
      totalExpired: () => const _ProtocolProblem(
        HttpStatus.requestTimeout,
        'body-total-timeout',
      ),
    );
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw const _ProtocolProblem(HttpStatus.badRequest, 'invalid-utf8');
    }
  }

  Future<void> _json(
    HttpRequest req,
    Map<String, dynamic> body, {
    int status = HttpStatus.ok,
  }) async {
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
