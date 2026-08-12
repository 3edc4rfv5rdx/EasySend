import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'android_helpers.dart';
import 'globals.dart';

const Uuid _uuid = Uuid();

const int maxPathUtf8Bytes = 4096;
const int maxPathDepth = 64;
// One name, counted the way NTFS and ext4 count it: 255 UTF-16 code units, not
// bytes. Counting bytes would refuse a Cyrillic name of 150 letters that every
// filesystem involved would have taken.
const int maxPathComponentChars = 255;
// Incomplete uploads live in a receiver-owned session directory instead of
// borrowing a suffix from the final user name. A valid file is allowed to end
// in `.easysend-part`; startup cleanup must never mistake it for our state.
const String incompleteDirPrefix = '.easysend-incomplete-';
const String _incompleteOwnerFile = '.owner';
const String _incompleteOwnerMagic = 'EasySend incomplete transfer v1\n';
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

// Build the transfer manifest out of picked files and folders. A folder keeps
// its own name as the top level, so the structure arrives intact.
Future<List<FileItem>> collectFiles(List<String> paths) async {
  final List<FileItem> items = [];
  for (final String path in paths) {
    final FileSystemEntityType type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      final File f = File(path);
      final FileStat stat = await f.stat();
      items.add(
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
      await for (final FileSystemEntity entity in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          final FileStat stat = await entity.stat();
          items.add(
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
      }
    }
  }
  return items;
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
        segment.length > maxPathComponentChars) {
      return null;
    }
    final String base = segment.split('.').first.toLowerCase();
    if (_reservedNames.contains(base)) return null;
    parts.add(segment);
    if (parts.length > maxPathDepth) return null;
  }
  return parts.isEmpty ? null : parts.join('/');
}

// Why a path was refused, when the answer is worth telling the user apart from
// the rest. Length is the one refusal that is nobody's mistake — a name simply
// grew past what a filesystem will hold — so it gets said in those words.
bool isPathTooLong(String raw) {
  if (utf8.encode(raw).length > maxPathUtf8Bytes) return true;
  final List<String> parts = raw
      .split('/')
      .where((String segment) => segment.isNotEmpty && segment != '.')
      .toList();
  return parts.length > maxPathDepth ||
      parts.any((String segment) => segment.length > maxPathComponentChars);
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
  final bool foldCase = windows ?? Platform.isWindows;
  for (int i = 0; i < safePaths.length; i++) {
    final String key = foldCase ? safePaths[i].toLowerCase() : safePaths[i];
    for (int j = 0; j < safePaths.length; j++) {
      if (i == j) continue;
      final String other = foldCase ? safePaths[j].toLowerCase() : safePaths[j];
      if (other.startsWith('$key/')) {
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
    result[files[i].id] = await uniquePath(
      full,
      reserved: reserved,
      windows: windows,
    );
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

Future<bool> ensureIncompleteSessionDirectory(
  String baseDir,
  String sessionId, {
  required String resolvedRoot,
}) async {
  final String directory = incompleteSessionDirectory(baseDir, sessionId);
  final String markerPath = p.join(directory, _incompleteOwnerFile);
  if (!await ensureSafeDestination(
    baseDir,
    markerPath,
    createParents: true,
    resolvedRoot: resolvedRoot,
  )) {
    return false;
  }
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

// Once per run, which is what SPEC 7 asks for: a killed process leaves owned
// incomplete-session directories behind and nothing else will remove them.
// Tying it to the receive
// server instead meant a full recursive walk of the user's Downloads folder
// every time the app came back to the screen.
bool _orphansSwept = false;

Future<void> sweepOrphanPartsOnce(String baseDir) async {
  if (_orphansSwept) return;
  _orphansSwept = true;
  await cleanupOrphanParts(baseDir);
}

// Startup recovery removes only directories carrying the ownership marker we
// wrote before an upload. A filename suffix is not ownership: a verified user
// file may legitimately be named `report.easysend-part`.
Future<void> cleanupOrphanParts(String baseDir) async {
  final Directory root = Directory(baseDir);
  if (!await root.exists()) return;
  try {
    await for (final FileSystemEntity entity in root.list(
      recursive: false,
      followLinks: false,
    )) {
      final FileSystemEntityType type = await FileSystemEntity.type(
        entity.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.directory ||
          !p.basename(entity.path).startsWith(incompleteDirPrefix)) {
        continue;
      }
      final File marker = File(p.join(entity.path, _incompleteOwnerFile));
      if (!await marker.exists() ||
          await marker.readAsString() != _incompleteOwnerMagic) {
        continue;
      }
      try {
        await Directory(entity.path).delete(recursive: true);
      } catch (e) {
        myPrint('cannot delete orphan session ${entity.path}: $e');
      }
    }
  } catch (e) {
    // An unreadable folder is not a reason to fail startup; storage permission
    // may simply not have been granted yet.
    myPrint('cannot sweep $baseDir: $e');
  }
}

// 'photo.jpg' -> 'photo (1).jpg' when taken.
Future<String> uniquePath(
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
    final String candidate = p.join(dir, '$stem ($i)$ext');
    if (!await unavailable(candidate)) {
      reserved?.add(pathEqualityKey(candidate, windows: windows));
      return candidate;
    }
  }
  return p.join(dir, '$stem ${DateTime.now().millisecondsSinceEpoch}$ext');
}

Future<bool> _taken(String path) async =>
    await FileSystemEntity.type(path, followLinks: false) !=
    FileSystemEntityType.notFound;
