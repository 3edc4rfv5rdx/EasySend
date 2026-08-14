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

  Device({
    required this.id,
    required this.name,
    this.platform = '',
    this.address = '',
    this.port = defaultPort,
    this.trusted = false,
    this.manual = false,
    this.lastSeen,
  });

  // Discovered devices go silent when gone; manual ones are polled over HTTP
  // and lastSeen is stamped by the poller, so one rule covers both.
  bool get online {
    final DateTime? seen = lastSeen;
    if (seen == null) return false;
    final int limit = manual ? manualPollSec * 2 : deviceTimeoutSec;
    return DateTime.now().difference(seen).inSeconds <= limit;
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
enum TransferStatus { pending, active, done, partial, unconfirmed, cancelled, failed }

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
  // and the progress bar asks for this several times a second.
  final int bytesTotal;

  int bytesDone = 0;
  int currentIndex = 0;
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
