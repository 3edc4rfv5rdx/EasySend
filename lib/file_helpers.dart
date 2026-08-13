import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'android_helpers.dart';
import 'globals.dart';

const Uuid _uuid = Uuid();

const int maxPathUtf8Bytes = 4096;
const int maxPathDepth = 64;
// One name, counted twice, because the two ends do not count alike: NTFS caps a
// component at 255 UTF-16 code units, while ext4 and the Android filesystems cap
// it at 255 bytes of UTF-8. A name has to pass both, or it is a name one of the
// two sides cannot create — 255 Cyrillic letters are 255 units and 510 bytes,
// and the write fails with ENAMETOOLONG on the receiver's own disk.
const int maxPathComponentChars = 255;
const int maxPathComponentBytes = 255;
// Incomplete uploads live in a receiver-owned session directory instead of
// borrowing a suffix from the final user name. A valid file is allowed to end
// in `.easysend-part`; startup cleanup must never mistake it for our state.
const String incompleteDirPrefix = '.easysend-incomplete-';
const String _incompleteOwnerFile = '.owner';
const String _incompleteOwnerMagic = 'EasySend incomplete transfer v1\n';
// Ownership is recorded in the app's own config directory and nowhere else.
// Everything inside the receive folder is bytes a peer can send us: a folder
// named like a session, marker file and all, arrives as an ordinary transfer,
// and a name-and-content convention would let it be deleted as if it were ours.
const String _sessionRegistryDir = 'incomplete-sessions';
const String _sessionRecordSuffix = '.dir';
// A session id becomes a directory name in the receive folder and a file name
// in the registry. Ours are UUIDs; anything else is refused, not sanitized.
final RegExp _safeSessionId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
// The backslash is in here on every platform: it is a separator on Windows and
// an ordinary character on Linux, so a name carrying one cannot mean the same
// thing at both ends of a transfer (SPEC 5.7).
final RegExp _windowsForbidden = RegExp(r'[<>:"|?*\\\x00-\x1f]');

// The same channel the foreground service talks over.
const MethodChannel _androidChannel = MethodChannel('easysend/service');

// The receive folder is made when the first file lands, which leaves nothing to
// open before that and nothing to see in a file manager. Called at startup and
// again before opening it, since the storage permission may arrive in between.
Future<bool> ensureRecvDir() async {
  try {
    await Directory(xvRecvDir).create(recursive: true);
    return true;
  } catch (e) {
    myPrint('cannot create $xvRecvDir: $e');
    return false;
  }
}

// Whether files can actually land in this folder, asked at the moment somebody
// picks it rather than when the first transfer arrives. Existing is not the
// same as writable: a folder can be listed and still refuse a file.
Future<bool> canWriteInto(String dir) async {
  try {
    await Directory(dir).create(recursive: true);
    final File probe = File(
      p.join(dir, '.easysend-probe-${DateTime.now().microsecondsSinceEpoch}'),
    );
    await probe.writeAsString('', flush: true);
    await probe.delete();
    return true;
  } catch (e) {
    myPrint('cannot write into $dir: $e');
    return false;
  }
}

// Open the receive folder whatever state the storage is in. The folder is made
// first; if that failed for want of permission, Android is asked for it and the
// folder tried again. Should the folder still not open, the nearest parent that
// does open is used instead: landing in the file manager one level up beats an
// error the user cannot do anything about.
Future<bool> openRecvFolder() async {
  if (!await ensureRecvDir() && Platform.isAndroid) {
    if (await ensureStoragePermission()) await ensureRecvDir();
  }

  String path = xvRecvDir;
  while (path.isNotEmpty) {
    if (await Directory(path).exists() &&
        await openExternally(path, folder: true)) {
      return true;
    }
    final String parent = p.dirname(path);
    if (parent == path) return false; // reached the root and it would not open
    path = parent;
  }
  return false;
}

// Hand a file or a folder over to whatever the system has for it. Android goes
// through the native side: a file needs a FileProvider URI, and a folder needs
// a documents URI, since a plain file:// intent is no longer allowed to leave
// the app. Returns false when nothing on the device can open it.
Future<bool> openExternally(String path, {bool folder = false}) async {
  if (path.isEmpty) return false;
  try {
    if (Platform.isAndroid) {
      final bool? ok = await _androidChannel.invokeMethod<bool>(
        folder ? 'openFolder' : 'openFile',
        {'path': path},
      );
      return ok ?? false;
    }
    if (Platform.isLinux) {
      final ProcessResult r = await Process.run('xdg-open', [path]);
      return r.exitCode == 0;
    }
    if (Platform.isWindows) {
      // explorer.exe reports a non-zero exit code even when it worked.
      await Process.run('explorer', [path.replaceAll('/', r'\')]);
      return true;
    }
  } catch (e) {
    myPrint('cannot open $path: $e');
  }
  return false;
}

// Windows device names are unusable as file names even on other platforms,
// because the transfer may land on Windows.
const Set<String> _reservedNames = {
  'con',
  'prn',
  'aux',
  'nul',
  'com1',
  'com2',
  'com3',
  'com4',
  'com5',
  'com6',
  'com7',
  'com8',
  'com9',
  'lpt1',
  'lpt2',
  'lpt3',
  'lpt4',
  'lpt5',
  'lpt6',
  'lpt7',
  'lpt8',
  'lpt9',
};

// Directories a finished move is allowed to take with it, deepest first: the
// folders inside a picked folder, and the picked folder itself.
//
// A file picked on its own contributes nothing. Its relative path is a bare
// name, so the directory holding it is the user's, not part of what was sent,
// and emptying it is no reason to remove it. Depth comes from the relative path
// rather than from the source, which is what keeps the walk from ever stepping
// above the folder the user actually chose.
//
// Being a candidate is not being deleted: the caller removes only the ones that
// are empty by the time it looks.
List<String> prunableSourceDirs(Iterable<FileItem> items) {
  final Set<String> dirs = <String>{};
  for (final FileItem item in items) {
    final String? source = item.sourcePath;
    if (source == null) continue;
    // Relative paths are built with '/' on every platform (see collectFiles),
    // so they are split by that rather than by the platform separator.
    final int depth = item.relativePath.split('/').length - 1;
    String dir = p.dirname(source);
    for (int i = 0; i < depth; i++) {
      dirs.add(dir);
      dir = p.dirname(dir);
    }
  }
  // A folder can only be empty once the folders under it are gone.
  return dirs.toList()
    ..sort((a, b) => p.split(b).length.compareTo(p.split(a).length));
}

// What a pick produced, and whether the walk was cut short by a limit.
class CollectedFiles {
  final List<FileItem> items;
  final bool tooManyFiles;
  final bool tooLarge;

  const CollectedFiles(
    this.items, {
    this.tooManyFiles = false,
    this.tooLarge = false,
  });

  bool get overflowed => tooManyFiles || tooLarge;
}

// Build the transfer manifest out of picked files and folders. A folder keeps
// its own name as the top level, so the structure arrives intact.
//
// The limits are enforced here, while walking, and not by the caller afterwards.
// A cache or dependency folder holds hundreds of thousands of files: collecting
// all of them to then refuse the selection means the stat of every one of them,
// a FileItem per file held in memory, and a UI that cannot answer until the
// whole tree has been read.
//
// `maxFiles` bounds what is collected, not what is finally selected. One item
// past it is enough to know no selection can fit: a collected file that is
// already selected is dropped as a duplicate later, and there can be no more of
// those than the selection holds.
Future<CollectedFiles> collectFiles(
  List<String> paths, {
  int maxFiles = maxManifestFiles,
  int maxBytes = maxDeclaredTransferBytes,
}) async {
  final List<FileItem> items = [];
  int totalBytes = 0;
  bool tooManyFiles = false;
  bool tooLarge = false;
  bool room() => !tooManyFiles && !tooLarge;

  void take(FileItem item) {
    items.add(item);
    totalBytes += item.size;
    if (items.length > maxFiles) tooManyFiles = true;
    if (totalBytes > maxBytes) tooLarge = true;
  }

  for (final String path in paths) {
    if (!room()) break;
    final FileSystemEntityType type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      final File f = File(path);
      final FileStat stat = await f.stat();
      take(
        FileItem(
          id: _uuid.v4(),
          relativePath: p.basename(path),
          size: stat.size,
          sourcePath: path,
          modified: stat.modified,
        ),
      );
    } else if (type == FileSystemEntityType.directory) {
      final String parent = p.dirname(path);
      try {
        await for (final FileSystemEntity entity in Directory(
          path,
        ).list(recursive: true, followLinks: false)) {
          if (entity is! File) continue;
          try {
            final FileStat stat = await entity.stat();
            take(
              FileItem(
                id: _uuid.v4(),
                // Relative to the folder's parent, so the folder itself is
                // included. Split by the platform's own rule rather than by
                // replacing backslashes: on Linux a backslash is an ordinary
                // character in a name, and replacing it would turn one file into
                // a folder before the manifest was even built.
                relativePath: p
                    .split(p.relative(entity.path, from: parent))
                    .join('/'),
                size: stat.size,
                sourcePath: entity.path,
                modified: stat.modified,
              ),
            );
          } catch (e) {
            myPrint('skipping unreadable ${entity.path}: $e');
          }
          // Breaking out of `await for` cancels the directory subscription, so
          // the rest of the tree is never read.
          if (!room()) break;
        }
      } catch (e) {
        // A folder that cannot be listed loses that folder, not the selection.
        myPrint('cannot walk $path: $e');
      }
    }
  }
  return CollectedFiles(
    items,
    tooManyFiles: tooManyFiles,
    tooLarge: tooLarge,
  );
}

// What stops a set of freshly picked files from joining the selection. Every
// path that adds files asks this one question against the selection as it
// stands: an ordinary pick, a drop, a share, and the backslash repair, which
// used to check the count alone and could build a selection the receiver is
// guaranteed to refuse for its size.
enum SelectionLimit { files, bytes }

SelectionLimit? selectionLimitBroken(
  Iterable<FileItem> selected,
  Iterable<FileItem> fresh,
) {
  if (selected.length + fresh.length > maxManifestFiles) {
    return SelectionLimit.files;
  }
  int total = 0;
  for (final FileItem f in selected) {
    total += f.size;
  }
  for (final FileItem f in fresh) {
    total += f.size;
  }
  return total > maxDeclaredTransferBytes ? SelectionLimit.bytes : null;
}

class FileSnapshot {
  final String sourcePath;
  final String relativePath;

  const FileSnapshot({required this.sourcePath, required this.relativePath});
}

List<FileSnapshot> snapshotFiles(Iterable<FileItem> files) => files
    .where((file) => file.sourcePath != null)
    .map(
      (file) => FileSnapshot(
        sourcePath: file.sourcePath!,
        relativePath: file.relativePath,
      ),
    )
    .toList(growable: false);

Future<({List<FileItem> files, int missing})> restoreFileSnapshot(
  Iterable<FileSnapshot> snapshot,
) async {
  final List<FileItem> restored = [];
  int missing = 0;
  for (final FileSnapshot saved in snapshot) {
    final File file = File(saved.sourcePath);
    try {
      final FileStat stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        missing++;
        continue;
      }
      restored.add(
        FileItem(
          id: _uuid.v4(),
          relativePath: saved.relativePath,
          size: stat.size,
          sourcePath: saved.sourcePath,
          modified: stat.modified,
        ),
      );
    } catch (e) {
      missing++;
      myPrint('cannot restore ${saved.sourcePath}: $e');
    }
  }
  return (files: restored, missing: missing);
}

// Make a manifest path safe to write. Returns null when the path cannot be
// trusted at all — absolute paths and any '..' are refused outright rather than
// stripped, because a mangled path is a broken transfer, not a fixed one.
String? sanitizeRelPath(String raw) {
  if (raw.isEmpty || utf8.encode(raw).length > maxPathUtf8Bytes) return null;
  if (raw.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(raw)) {
    return null;
  }

  final List<String> parts = [];
  // '/' is the separator on the wire, whatever the two ends run. A backslash is
  // refused below with the rest of the non-portable characters, not quietly
  // turned into a second separator.
  for (final String segment in raw.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    // Reject lossy or non-portable names instead of silently mapping two
    // different manifest entries onto the same destination.
    if (_windowsForbidden.hasMatch(segment) ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        isComponentTooLong(segment)) {
      return null;
    }
    final String base = segment.split('.').first.toLowerCase();
    if (_reservedNames.contains(base)) return null;
    parts.add(segment);
    if (parts.length > maxPathDepth) return null;
  }
  return parts.isEmpty ? null : parts.join('/');
}

// One name against both limits. Whichever end of the transfer is stricter for
// this particular name is the one that decides.
bool isComponentTooLong(String segment) =>
    segment.length > maxPathComponentChars ||
    utf8.encode(segment).length > maxPathComponentBytes;

// Why a path was refused, when the answer is worth telling the user apart from
// the rest. Length is the one refusal that is nobody's mistake — a name simply
// grew past what a filesystem will hold — so it gets said in those words.
bool isPathTooLong(String raw) {
  if (utf8.encode(raw).length > maxPathUtf8Bytes) return true;
  final List<String> parts = raw
      .split('/')
      .where((String segment) => segment.isNotEmpty && segment != '.')
      .toList();
  return parts.length > maxPathDepth || parts.any(isComponentTooLong);
}

// Which of the rules above a name broke, asked only once the name is known to
// be refused. Order matters: length cannot be repaired by anything, so it wins
// over a backslash that could otherwise have been offered a dash.
PickProblem classifyRefusal(String raw, {int size = 0}) {
  if (size > maxDeclaredFileBytes) return PickProblem.tooLarge;
  if (isPathTooLong(raw)) return PickProblem.tooLong;
  if (raw.contains(r'\')) return PickProblem.backslash;
  for (final String segment in raw.split('/')) {
    if (_reservedNames.contains(segment.split('.').first.toLowerCase())) {
      return PickProblem.reserved;
    }
  }
  return PickProblem.notPortable;
}

// The one refusal worth offering a repair for. Everything else on that list is
// either dangerous or genuinely impossible; a backslash is only ambiguous, and
// a dash carries the name across without inventing a folder. Offered, never
// applied on its own: the file arrives under a name its owner did not choose.
String repairBackslashes(String relativePath) =>
    relativePath.replaceAll(r'\', '-');

// Full lexical destination for a manifest entry. Filesystem containment is
// checked separately immediately before any directory/file operation.
Future<String?> resolveInside(String baseDir, String relPath) async {
  final String? safe = sanitizeRelPath(relPath);
  if (safe == null) return null;
  final String full = p.normalize(p.join(baseDir, safe));
  final String base = p.normalize(baseDir);
  if (!p.isWithin(base, full)) return null;
  return full;
}

String pathEqualityKey(String path, {bool? windows}) {
  final String normalized = p.normalize(path);
  return (windows ?? Platform.isWindows)
      ? normalized.toLowerCase()
      : normalized;
}

class DestinationPlanException implements Exception {
  final String reason;
  const DestinationPlanException(this.reason);

  @override
  String toString() => reason;
}

// Reserve every destination before consent. Names already on disk and names
// allocated earlier in this same manifest participate in one collision set.
Future<Map<String, String>> buildDestinationPlan(
  String baseDir,
  List<FileItem> files, {
  bool? windows,
}) async {
  final Set<String> ids = {};
  final List<String> safePaths = [];
  for (final FileItem file in files) {
    if (file.id.isEmpty || !ids.add(file.id)) {
      throw const DestinationPlanException('duplicate or empty file id');
    }
    final String? safe = sanitizeRelPath(file.relativePath);
    if (safe == null || file.size < 0) {
      throw const DestinationPlanException('invalid file path or size');
    }
    safePaths.add(safe);
  }

  // A file cannot also be the directory required by another entry. Manifest
  // paths always carry '/', so the comparison must not go through the host's
  // separator: normalizing them would give '\' on Windows and match nothing.
  //
  // Asked as a prefix lookup, not pairwise. Comparing every entry with every
  // other one cost nine million comparisons at the manifest limit — with the
  // case folding recomputed inside the inner loop — and all of it runs
  // synchronously inside the prepare handler, before the consent question is
  // even shown. Each entry now only asks whether one of its own parents is
  // itself an entry, which is the same question.
  final bool foldCase = windows ?? Platform.isWindows;
  final List<String> keys = foldCase
      ? [for (final String path in safePaths) path.toLowerCase()]
      : safePaths;
  final Set<String> keySet = keys.toSet();
  for (final String key in keys) {
    for (
      int cut = key.indexOf('/');
      cut >= 0;
      cut = key.indexOf('/', cut + 1)
    ) {
      if (keySet.contains(key.substring(0, cut))) {
        throw const DestinationPlanException('file/directory path conflict');
      }
    }
  }

  final Set<String> reserved = {};
  final Map<String, String> result = {};
  for (int i = 0; i < files.length; i++) {
    final String? full = await resolveInside(baseDir, safePaths[i]);
    if (full == null) {
      throw const DestinationPlanException('path escapes receive directory');
    }
    final String? free = await uniquePath(
      full,
      reserved: reserved,
      windows: windows,
    );
    if (free == null) {
      throw const DestinationPlanException('no free destination name');
    }
    result[files[i].id] = free;
  }
  return result;
}

// The receive root, made and canonicalized once so that every destination in a
// session can be measured against the same answer. Asking the filesystem again
// for every file cost 46 us a call — 281 ms on a manifest of 3000 files, spent
// before the consent dialog even appeared.
Future<String?> resolveReceiveRoot(String baseDir) async {
  try {
    await Directory(baseDir).create(recursive: true);
    return await Directory(baseDir).resolveSymbolicLinks();
  } catch (e) {
    myPrint('cannot resolve $baseDir: $e');
    return null;
  }
}

// Reject links below the configured root and verify the resolved parent stays
// inside it. Dart has no portable atomic O_NOFOLLOW open; callers therefore
// invoke this at prepare and immediately before open/rename. A hostile local
// process can still race those calls on platforms without a no-follow API.
Future<bool> ensureSafeDestination(
  String baseDir,
  String destination, {
  bool createParents = false,
  // The root as resolved once for this session. Passing it also makes the
  // check stricter: a root swapped underneath a running transfer no longer
  // matches, and every destination below it is refused.
  String? resolvedRoot,
}) async {
  final String? root = resolvedRoot ?? await resolveReceiveRoot(baseDir);
  if (root == null) return false;
  final String relative = p.relative(destination, from: baseDir);
  if (relative == '.' ||
      p.isAbsolute(relative) ||
      relative == '..' ||
      relative.startsWith('..${p.separator}')) {
    return false;
  }

  String cursor = root;
  final List<String> components = p.split(relative);
  for (int i = 0; i < components.length - 1; i++) {
    cursor = p.join(cursor, components[i]);
    FileSystemEntityType type = await FileSystemEntity.type(
      cursor,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        type == FileSystemEntityType.file) {
      return false;
    }
    if (type == FileSystemEntityType.notFound) {
      if (!createParents) return true;
      await Directory(cursor).create();
      type = await FileSystemEntity.type(cursor, followLinks: false);
      if (type != FileSystemEntityType.directory) return false;
    }
    final String resolved = await Directory(cursor).resolveSymbolicLinks();
    if (resolved != root && !p.isWithin(root, resolved)) return false;
  }

  // Below the resolved parent, not below the root: a nested destination has to
  // be checked where it actually lands.
  final String finalPath = p.join(cursor, components.last);
  final FileSystemEntityType finalType = await FileSystemEntity.type(
    finalPath,
    followLinks: false,
  );
  if (finalType == FileSystemEntityType.link ||
      finalType == FileSystemEntityType.directory) {
    return false;
  }
  final String parent = await Directory(
    p.dirname(finalPath),
  ).resolveSymbolicLinks();
  return parent == root || p.isWithin(root, parent);
}

// Where the Android side puts a copy of a picked document it could not hand
// over as a plain file. Kept in step with `MainActivity.copyToCache` by name:
// getTemporaryDirectory() is that Activity's `cacheDir`, and `picked` is the
// subdirectory it makes inside it.
const String pickedCopiesDirName = 'picked';

Future<String?> pickedCopiesRoot() async {
  if (!Platform.isAndroid) return null;
  try {
    final Directory temporary = await getTemporaryDirectory();
    return p.join(temporary.path, pickedCopiesDirName);
  } catch (e) {
    myPrint('cannot resolve the picked copies directory: $e');
    return null;
  }
}

// Whether all the app ever had of this file is a copy of its own.
//
// A document on internal storage arrives as a plain path and is the user's own
// file. Anything else — a cloud provider, an SD card, a share from another app —
// only comes as a stream, and the native side copies it into the app's cache to
// have something dart:io can read. Deleting that after a move would remove the
// app's own scratch file, leave the user's file exactly where it was, and report
// it as the original being gone.
bool isAppOwnedCopy(String sourcePath, String? copiesRoot) =>
    copiesRoot != null && p.isWithin(copiesRoot, sourcePath);

// Those copies are nobody's afterwards: a couple of picked videos leave
// gigabytes in the cache for good. Swept once per run rather than after each
// transfer, because a copy may still be sitting in the picked list — and that
// list does not survive a restart, so by the next one nothing refers to them.
bool _copiesSwept = false;

Future<void> sweepPickedCopiesOnce() async {
  if (_copiesSwept) return;
  _copiesSwept = true;
  final String? root = await pickedCopiesRoot();
  if (root == null) return;
  try {
    final Directory copies = Directory(root);
    if (await copies.exists()) await copies.delete(recursive: true);
  } catch (e) {
    myPrint('cannot sweep picked copies: $e');
  }
}

// Remove a file without making a failure anyone's problem. Says whether it is
// gone: a file that was already missing counts as gone, since the point is the
// state afterwards and not who removed it.
Future<bool> deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
    return true;
  } catch (e) {
    myPrint('cannot delete ${file.path}: $e');
    return false;
  }
}

String incompleteSessionDirectory(String baseDir, String sessionId) =>
    p.join(baseDir, '$incompleteDirPrefix$sessionId');

String incompleteFilePath(String baseDir, String sessionId, int index) =>
    p.join(incompleteSessionDirectory(baseDir, sessionId), '$index.part');

// Where this run states, outside anything a transfer can write to, that a
// session directory is its own. Null when the config directory is not resolved
// yet: without a place to record ownership there is no safe way to create
// state we would later have to recognise.
String? _sessionRecordPath(String sessionId) {
  if (xvConfigDir.isEmpty || !_safeSessionId.hasMatch(sessionId)) return null;
  return p.join(
    xvConfigDir,
    _sessionRegistryDir,
    '$sessionId$_sessionRecordSuffix',
  );
}

// Written before the directory exists. A crash in between leaves a record
// pointing at nothing, which the next sweep drops; the other order would leave
// a directory nobody claims and nobody ever deletes.
Future<bool> _recordIncompleteSession(
  String sessionId,
  String directory,
) async {
  final String? recordPath = _sessionRecordPath(sessionId);
  if (recordPath == null) {
    myPrint('cannot own an incomplete session for id "$sessionId"');
    return false;
  }
  final File record = File(recordPath);
  try {
    if (await record.exists() &&
        (await record.readAsString()).trim() == directory) {
      return true;
    }
    await record.parent.create(recursive: true);
    await record.writeAsString('$directory\n', flush: true);
    return true;
  } catch (e) {
    myPrint('cannot record incomplete session $directory: $e');
    return false;
  }
}

Future<bool> ensureIncompleteSessionDirectory(
  String baseDir,
  String sessionId, {
  required String resolvedRoot,
}) async {
  final String directory = incompleteSessionDirectory(baseDir, sessionId);
  if (!await _recordIncompleteSession(sessionId, directory)) return false;
  final String markerPath = p.join(directory, _incompleteOwnerFile);
  if (!await ensureSafeDestination(
    baseDir,
    markerPath,
    createParents: true,
    resolvedRoot: resolvedRoot,
  )) {
    return false;
  }
  // The marker only ever refuses: it stops us writing parts into a directory
  // that is not the one this session made. It never authorises a deletion —
  // the registry record does that, and a sender cannot reach the registry.
  final File marker = File(markerPath);
  try {
    if (await marker.exists()) {
      return await marker.readAsString() == _incompleteOwnerMagic;
    }
    await marker.writeAsString(_incompleteOwnerMagic, flush: true);
    return true;
  } catch (e) {
    myPrint('cannot mark incomplete session $directory: $e');
    return false;
  }
}

// Whether the directory is gone afterwards. A record we cannot act on yet —
// storage permission missing, folder unmounted — keeps its entry so a later
// run tries again.
Future<bool> _removeOwnedSessionDirectory(String directory) async {
  if (!p.basename(directory).startsWith(incompleteDirPrefix)) return true;
  try {
    final FileSystemEntityType type = await FileSystemEntity.type(
      directory,
      followLinks: false,
    );
    // Anything but a real directory at our own path is not ours to delete: a
    // link is never followed, and a file there is not the state we wrote.
    if (type != FileSystemEntityType.directory) return true;
    await Directory(directory).delete(recursive: true);
    return true;
  } catch (e) {
    myPrint('cannot delete orphan session $directory: $e');
    return false;
  }
}

// The receiver's own cleanup when a session ends: the same removal, and the
// ownership record goes with it.
Future<void> discardIncompleteSession(String baseDir, String sessionId) async {
  final String? recordPath = _sessionRecordPath(sessionId);
  if (recordPath == null) return;
  if (await _removeOwnedSessionDirectory(
    incompleteSessionDirectory(baseDir, sessionId),
  )) {
    await deleteQuietly(File(recordPath));
  }
}

// Once per run, which is what SPEC 7 asks for: a killed process leaves owned
// incomplete-session directories behind and nothing else will remove them.
// Tying it to the receive server instead meant a full recursive walk of the
// user's Downloads folder every time the app came back to the screen.
bool _orphansSwept = false;

Future<void> sweepOrphanSessionsOnce() async {
  if (_orphansSwept) return;
  _orphansSwept = true;
  await cleanupOrphanSessions();
}

// Startup recovery deletes the session directories this run's predecessors
// recorded as their own, wherever they are: the record holds an absolute path,
// so a folder that has since stopped being the receive folder is still swept.
// Must run before the receive server can open a session — a live session's
// directory is recorded too, and here that is indistinguishable from a leftover.
Future<void> cleanupOrphanSessions() async {
  if (xvConfigDir.isEmpty) return;
  final Directory registry = Directory(
    p.join(xvConfigDir, _sessionRegistryDir),
  );
  try {
    if (!await registry.exists()) return;
    await for (final FileSystemEntity entity in registry.list(
      recursive: false,
      followLinks: false,
    )) {
      if (entity is! File || !entity.path.endsWith(_sessionRecordSuffix)) {
        continue;
      }
      final String directory = (await entity.readAsString()).trim();
      if (directory.isNotEmpty &&
          !await _removeOwnedSessionDirectory(directory)) {
        continue;
      }
      await deleteQuietly(entity);
    }
  } catch (e) {
    // An unreadable registry is not a reason to fail startup.
    myPrint('cannot sweep incomplete sessions: $e');
  }
}

// A collision suffix must not push a name that only just fitted over the limit
// the sender validated it against. The stem gives up whole characters — code
// points, so a surrogate pair is never cut in half — until the finished name
// fits both counts again. Null when even an empty stem does not help — the
// extension alone is oversized — and then there is no such name to offer.
String? _fitComponent(String stem, String suffix, String ext) {
  String candidate = '$stem$suffix$ext';
  if (!isComponentTooLong(candidate)) return candidate;
  final List<int> runes = stem.runes.toList();
  for (int end = runes.length - 1; end >= 0; end--) {
    candidate = '${String.fromCharCodes(runes.take(end))}$suffix$ext';
    if (!isComponentTooLong(candidate)) return candidate;
  }
  return null;
}

// 'photo.jpg' -> 'photo (1).jpg' when taken. Null when nothing is free: every
// name this returns has been checked and reserved, so a caller may act on it.
// Handing back an unchecked fallback was the same bug in miniature — a name the
// caller believes is free while something already sits there.
Future<String?> uniquePath(
  String fullPath, {
  Set<String>? reserved,
  bool? windows,
}) async {
  Future<bool> unavailable(String candidate) async {
    final String key = pathEqualityKey(candidate, windows: windows);
    return (reserved?.contains(key) ?? false) || await _taken(candidate);
  }

  if (!await unavailable(fullPath)) {
    reserved?.add(pathEqualityKey(fullPath, windows: windows));
    return fullPath;
  }
  final String dir = p.dirname(fullPath);
  final String ext = p.extension(fullPath);
  final String stem = p.basenameWithoutExtension(fullPath);
  for (int i = 1; i < 10000; i++) {
    final String? name = _fitComponent(stem, ' ($i)', ext);
    if (name == null) break;
    final String candidate = p.join(dir, name);
    if (!await unavailable(candidate)) {
      reserved?.add(pathEqualityKey(candidate, windows: windows));
      return candidate;
    }
  }
  // Ten thousand ' (n)' names are all taken. A timestamp is the last thing to
  // try, and it is checked like everything else.
  for (int i = 0; i < 16; i++) {
    // The attempt index keeps two allocations in the same microsecond apart,
    // so a retry can never hand back the name it was just refused.
    final int micros = DateTime.now().microsecondsSinceEpoch;
    final String? name = _fitComponent(
      stem,
      ' ${i == 0 ? micros : '$micros-$i'}',
      ext,
    );
    if (name == null) break;
    final String candidate = p.join(dir, name);
    if (!await unavailable(candidate)) {
      reserved?.add(pathEqualityKey(candidate, windows: windows));
      return candidate;
    }
  }
  myPrint('no free name left for $fullPath');
  return null;
}

// How many times publication may lose the name to somebody else before the
// file is refused. Each loss means an entry appeared between the check and the
// claim, which on a normal machine does not happen twice.
const int _publishAttempts = 8;

// Give a verified part its real name without ever replacing an entry that
// appeared while we were looking. `File.rename` is a clobbering operation: it
// removes whatever holds the destination (documented Dart behaviour), so a
// 'is it free?' check followed by a rename can still destroy a file created in
// between. The name is claimed first with an exclusive create, which fails if
// anybody else already holds it; the rename then only ever replaces our own
// empty placeholder. Returns the name the file actually got, or null when it
// could not be published — the part is left alone for the caller to deal with.
Future<String?> publishVerifiedFile(
  File part,
  String planned, {
  // Containment check for a name this function picks by itself; the caller owns
  // the receive root, so it owns the rule.
  required Future<bool> Function(String candidate) accept,
  Set<String>? reserved,
  bool? windows,
}) async {
  String? candidate = planned;
  for (int attempt = 0; attempt < _publishAttempts; attempt++) {
    if (candidate == null) return null;
    if (!await accept(candidate)) return null;
    if (await _claimName(candidate)) {
      try {
        await part.rename(candidate);
        return candidate;
      } catch (e) {
        myPrint('cannot publish ${part.path} as $candidate: $e');
        // The placeholder is ours and nothing landed in it.
        await deleteQuietly(File(candidate));
        return null;
      }
    }
    // Lost the race for this name: it belongs to whoever created it.
    reserved?.add(pathEqualityKey(candidate, windows: windows));
    candidate = await uniquePath(planned, reserved: reserved, windows: windows);
  }
  myPrint('no name could be claimed for ${part.path}');
  return null;
}

// The only no-clobber primitive dart:io has. Whoever wins the exclusive create
// owns the name; everybody else sees the entry and picks another. It fails on a
// directory or a link there too, which is exactly the answer we want.
Future<bool> _claimName(String path) async {
  try {
    await File(path).create(exclusive: true);
    return true;
  } catch (e) {
    return false;
  }
}

Future<bool> _taken(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;
