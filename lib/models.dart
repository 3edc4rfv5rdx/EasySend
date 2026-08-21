import 'dart:io' show FileStat, FileSystemEntityType;

import 'globals.dart';

// A peer device: either discovered by UDP announces or added by hand.
class Device {
  String id; // stable per-device UUID, trust is bound to it, not to IP
  String name;
  String platform; // android | linux | windows
  String address; // IP
  int port;
  bool trusted; // accept from it without asking
  bool manual; // added by hand, stays in the list while offline
  DateTime? lastSeen;
  // When it said goodbye rather than merely going quiet: the app was closed
  // there, the network did not drop. Cleared by the next announce, and never
  // persisted — an app that starts knows nothing about how anyone left.
  DateTime? departedAt;

  Device({
    required this.id,
    required this.name,
    this.platform = '',
    this.address = '',
    this.port = defaultPort,
    this.trusted = false,
    this.manual = false,
    this.lastSeen,
    this.departedAt,
  });

  // Whether the row still says how this device went away. It is news, not a
  // property: the minute it was worth telling apart from an ordinary silence
  // passes, and a device nobody can reach is just offline again. The same
  // minute a discovered device is kept in the list for after it goes quiet.
  bool get departed {
    final DateTime? left = departedAt;
    if (left == null) return false;
    return xvNow().difference(left).inSeconds <= departedNoticeSec;
  }

  // Discovered devices go silent when gone; manual ones are polled over HTTP
  // and lastSeen is stamped by the poller, so one rule covers both.
  bool get online {
    final DateTime? seen = lastSeen;
    if (seen == null) return false;
    final int limit = manual ? manualPollSec * 2 : deviceTimeoutSec;
    return xvNow().difference(seen).inSeconds <= limit;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'platform': platform,
    'address': address,
    'port': port,
    'trusted': trusted,
    'manual': manual,
  };

  // lastSeen is deliberately not persisted: a device is online only if it
  // answers now, never because it answered before the app was closed.
  factory Device.fromJson(Map<String, dynamic> j) => Device(
    id: j['id'] as String? ?? '',
    name: j['name'] as String? ?? '',
    platform: j['platform'] as String? ?? '',
    address: j['address'] as String? ?? '',
    port: j['port'] as int? ?? defaultPort,
    trusted: j['trusted'] as bool? ?? false,
    manual: j['manual'] as bool? ?? false,
  );
}

// What a source file was when its bytes were read, so a move can tell the file
// it sent from a file that has taken its place. Size, both timestamps and the
// mode: any write to a file moves ctime, so a replacement that gets past all
// four does not happen by accident. A SHA-256 of the contents used to be part of
// it and was dropped — it cost the batch a second full read at deletion time and
// caught nothing the timestamps did not. What travelled is a different question,
// and CRC32 answers that one on every file.
//
// Built either from a stat taken here or from the parts an isolate read while
// packing — the same fingerprint, taken in two places.
class SourceFingerprint {
  final int size;
  final DateTime modified;
  final DateTime changed;
  final int mode;

  SourceFingerprint(FileStat stat)
    : size = stat.size,
      modified = stat.modified,
      changed = stat.changed,
      mode = stat.mode;

  SourceFingerprint.parts({
    required this.size,
    required this.modified,
    required this.changed,
    required this.mode,
  });

  bool matches(FileStat stat) =>
      stat.type == FileSystemEntityType.file &&
      stat.size == size &&
      stat.modified == modified &&
      stat.changed == changed &&
      stat.mode == mode;
}

// One file inside a transfer.
class FileItem {
  final String id;
  final String relativePath; // path inside the transfer, keeps folder structure
  final String? sourcePath; // local path, sender side only
  final int size;
  final DateTime? modified; // shown next to the size in the picked list
  String? destinationPath; // receiver-side verified path, never sent on wire
  int? crc32; // computed on the fly, known once the file ends
  bool done = false;
  bool failed = false;

  FileItem({
    required this.id,
    required this.relativePath,
    required this.size,
    this.sourcePath,
    this.modified,
    this.destinationPath,
  });

  // The same file under a name that can travel, when the user has agreed to
  // the change. Everything else about it is what was picked.
  FileItem renamed(String path) => FileItem(
    id: id,
    relativePath: path,
    size: size,
    sourcePath: sourcePath,
    modified: modified,
  );

  String get name {
    final int slash = relativePath.lastIndexOf('/');
    return slash < 0 ? relativePath : relativePath.substring(slash + 1);
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': relativePath,
    'size': size,
  };

  factory FileItem.fromJson(Map<String, dynamic> j) => FileItem(
    id: j['id'] as String? ?? '',
    relativePath: j['path'] as String? ?? '',
    size: j['size'] as int? ?? 0,
  );
}

// Why a picked file cannot travel under its own name. Only the backslash is
// worth offering a repair for; the rest are either impossible or unsafe.
enum PickProblem { tooLong, backslash, reserved, notPortable, tooLarge }

typedef RefusedPick = ({FileItem file, PickProblem problem});

// How a transfer ended. `unconfirmed` is the receiver's own: every file of the
// manifest arrived and was published, and then the sender cancelled the session
// instead of closing it — its finish was refused, timed out or dropped. Neither
// `done` nor `cancelled` is true of that, and calling it cancelled over a full
// receive folder made the two ends describe one event differently (SPEC 3.3).
enum TransferStatus {
  pending,
  active,
  done,
  partial,
  unconfirmed,
  cancelled,
  failed,
}

// One thing that happened during a transfer. The message is an English key
// translated on the log screen; the detail is the part worth quoting in a bug
// report — status codes and system text — and is never translated.
class TransferEvent {
  final DateTime at;
  final String? file; // relative path, null when it is about the whole transfer
  final String message;
  final String? detail;
  // Something went wrong here. The screen paints these apart: the one line that
  // explains an outcome should not have to be found by reading all of them.
  final bool failure;
  // One file, nothing to report. These are the only lines a full log gives up:
  // everything else either went wrong, ended the transfer, or deleted something.
  final bool routine;

  const TransferEvent({
    required this.at,
    required this.message,
    this.file,
    this.detail,
    this.failure = false,
    this.routine = false,
  });
}

// One line of the log, the same on screen and in the clipboard.
String formatTransferEvent(TransferEvent event) {
  final String where = event.file == null ? '' : '${event.file}  ';
  final String detail = event.detail == null ? '' : ': ${event.detail}';
  return '${formatClock(event.at)}  $where${lw(event.message)}$detail';
}

// What the log says about the transfer as a whole, above the lines.
List<String> transferLogHeader(TransferSession transfer) => [
  transfer.peerName,
  '${lw(transfer.incoming ? 'Received' : 'Sent')} '
      '${transfer.doneCount}/${transfer.files.length} — '
      '${formatBytes(transfer.bytesTotal)}',
  formatDateTime(transfer.startedAt),
  if (transfer.error != null) '${lw('Error')}: ${transfer.error}',
];

// The last line of a log the cap has trimmed, on screen and in the clipboard
// alike. Null when nothing was trimmed and every line is still there.
//
// One line for both counts, because they answer the same question — what is
// missing from this log — with different news. Quiet files were given up on
// purpose and nothing about them is worth reading; dropped lines had something
// to say and the cap took them anyway, which the reader has to be told rather
// than left to infer from a log that starts mid-transfer.
String? trimmedLogLine(TransferSession transfer) {
  final List<String> parts = [
    if (transfer.quietFiles > 0)
      '${lw('Other files went through quietly')}: '
          '${transfer.quietFiles}',
    if (transfer.droppedLines > 0)
      '${lw('Older lines dropped')}: '
          '${transfer.droppedLines}',
  ];
  return parts.isEmpty ? null : parts.join(' — ');
}

// The whole log as one piece of text. The version goes first: a log quoted in
// a report is worth nothing without the build it came from.
String transferLogText(TransferSession transfer) {
  final String? trimmed = trimmedLogLine(transfer);
  return [
    '$prgName $progVersion+$buildNumber $xvPlatform',
    ...transferLogHeader(transfer),
    '',
    ...transfer.events.map(formatTransferEvent),
    ?trimmed,
  ].join('\n');
}

// One transfer, in either direction. Not persisted: the app keeps no history
// between runs, finished entries only live until restart.
class TransferSession {
  String id;
  final bool incoming;
  final String peerName;
  // Who it went to, so a partial outgoing transfer can be retried later even
  // after the device changed its address.
  final String peerId;
  final List<FileItem> files;
  // Fixed once the manifest is: nothing adds to a session's list afterwards,
  // and the progress bar asks for this several times a second. A ZIP send is
  // the one thing that sets it twice — see repackedAs.
  int bytesTotal;

  int bytesDone = 0;
  int currentIndex = 0;
  // The picked files are being written into one archive. Nothing has been sent
  // yet and the row has no speed to show, so it counts files instead: on a
  // folder of photos this is minutes of work with nothing else to look at.
  bool packing = false;
  // This session sent an archive, and the archive was deleted with the transfer
  // that made it. Nothing here can be retried: the one file it names is gone,
  // and the files it was made of belong to the picked list, not to the session.
  bool archived = false;
  TransferStatus status = TransferStatus.pending;
  DateTime startedAt = DateTime.now();
  String? error;

  // What happened along the way, in order. The row can only say how it ended;
  // this is where a file that did not make it says why. The list belongs to the
  // session, so it goes away with it instead of growing for the whole run.
  final List<TransferEvent> events = [];

  // Routine lines the cap has taken away. Counted rather than kept, and said in
  // one line at the end of the log, so the reader knows those files are simply
  // fine and not missing from the account.
  int quietFiles = 0;

  // Lines the cap had to drop with nothing quiet left to give up. These had
  // something to say — a refusal, a cancel, a deleted source — so losing one is
  // not the same event as retiring a "file sent", and the closing line says so
  // separately. Silence here was the one outcome the cap must not produce.
  int droppedLines = 0;

  void log(
    String message, {
    String? file,
    String? detail,
    bool failure = false,
    bool routine = false,
  }) {
    events.add(
      TransferEvent(
        at: DateTime.now(),
        message: message,
        file: file,
        detail: detail,
        failure: failure,
        routine: routine,
      ),
    );
    // Thousands of files with a retry each would otherwise be held whole. What
    // goes is the oldest line that says a file simply arrived: a transfer of
    // three thousand would otherwise push its early failures out of its own log
    // — the one thing the log exists to answer. Only when there is no such line
    // left does the oldest one go, whatever it says, and then it is counted:
    // a log of nothing but refusals is exactly where losing the early ones
    // matters most, and it must not happen behind the reader's back.
    if (events.length > maxTransferEvents) {
      final int quiet = events.indexWhere((TransferEvent e) => e.routine);
      if (quiet >= 0) {
        events.removeAt(quiet);
        quietFiles++;
      } else {
        events.removeAt(0);
        droppedLines++;
      }
    }
    myPrint([file, message, detail].nonNulls.join(' '));
  }

  // Rolling samples for speed and ETA. The instant rate jumps around too much
  // to read, so both are averaged over speedWindowSec.
  final List<(DateTime, int)> _samples = [];

  // The picked files became one archive, and from here on the session is about
  // that archive: it is what the manifest declares, what the bar measures and
  // what the far end receives. The only thing that ever replaces the list, and
  // it happens before the manifest exists — nothing has been sent, no progress
  // counted, so the totals start again from the size of the file that will go.
  // The originals stay with the caller, which is what a move deletes.
  void repackedAs(FileItem archive) {
    archived = true;
    files
      ..clear()
      ..add(archive);
    bytesTotal = archive.size;
    bytesDone = 0;
    currentIndex = 0;
    packing = false;
    _samples.clear();
  }

  void noteProgress(int totalBytesDone) {
    // Retries revisit an interval of the manifest; they never rewind completed
    // queue work. Clamp late or invalid samples at both ends so the bar, speed
    // and ETA share one monotonic invariant on sender and receiver.
    final int bounded = totalBytesDone.clamp(bytesDone, bytesTotal);
    bytesDone = bounded;
    final DateTime now = DateTime.now();
    _samples.add((now, bounded));
    final DateTime cutoff = now.subtract(
      const Duration(seconds: speedWindowSec),
    );
    while (_samples.length > 2 && _samples.first.$1.isBefore(cutoff)) {
      _samples.removeAt(0);
    }
  }

  // Bytes per second, 0 until there are two samples far enough apart.
  double get speed {
    if (_samples.length < 2) return 0;
    final int micros = _samples.last.$1
        .difference(_samples.first.$1)
        .inMicroseconds;
    if (micros <= 0) return 0;
    final int bytes = _samples.last.$2 - _samples.first.$2;
    return bytes <= 0 ? 0 : bytes * 1000000 / micros;
  }

  // Seconds left, or null while there is not enough data to guess.
  int? get etaSeconds {
    final double rate = speed;
    if (rate <= 0) return null;
    final int left = bytesTotal - bytesDone;
    return left <= 0 ? 0 : (left / rate).round();
  }

  TransferSession({
    required this.id,
    required this.incoming,
    required this.peerName,
    required this.files,
    this.peerId = '',
  }) : bytesTotal = files.fold(0, (int sum, FileItem f) => sum + f.size);

  int get doneCount => files.where((f) => f.done).length;
  int get failedCount => files.where((f) => f.failed).length;

  // Progress counts bytes, not files: with two movies and a picture, counting
  // files would jump a third of the bar for the picture alone.
  double get progress {
    final int total = bytesTotal;
    if (total == 0) {
      return status == TransferStatus.done ||
              status == TransferStatus.partial ||
              status == TransferStatus.unconfirmed
          ? 1
          : 0;
    }
    return bytesDone / total;
  }

  bool get isRunning =>
      status == TransferStatus.pending || status == TransferStatus.active;
}
