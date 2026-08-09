import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

import 'android_helpers.dart';
import 'globals.dart';

const Uuid _uuid = Uuid();

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
    if (await Directory(path).exists() && await openExternally(path, folder: true)) {
      return true;
    }
    final String parent = p.dirname(path);
    if (parent == path) return false;   // reached the root and it would not open
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
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
};

// Build the transfer manifest out of picked files and folders. A folder keeps
// its own name as the top level, so the structure arrives intact.
Future<List<FileItem>> collectFiles(List<String> paths) async {
  final List<FileItem> items = [];
  for (final String path in paths) {
    final FileSystemEntityType type = await FileSystemEntity.type(path);
    if (type == FileSystemEntityType.file) {
      final File f = File(path);
      final FileStat stat = await f.stat();
      items.add(FileItem(
        id: _uuid.v4(),
        relativePath: p.basename(path),
        size: stat.size,
        sourcePath: path,
        modified: stat.modified,
      ));
    } else if (type == FileSystemEntityType.directory) {
      final String parent = p.dirname(path);
      await for (final FileSystemEntity entity
          in Directory(path).list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;
        try {
          final FileStat stat = await entity.stat();
          items.add(FileItem(
            id: _uuid.v4(),
            // Relative to the folder's parent, so the folder itself is included.
            relativePath: p.relative(entity.path, from: parent).replaceAll(r'\', '/'),
            size: stat.size,
            sourcePath: entity.path,
            modified: stat.modified,
          ));
        } catch (e) {
          myPrint('skipping unreadable ${entity.path}: $e');
        }
      }
    }
  }
  return items;
}

// Make a manifest path safe to write. Returns null when the path cannot be
// trusted at all — absolute paths and any '..' are refused outright rather than
// stripped, because a mangled path is a broken transfer, not a fixed one.
String? sanitizeRelPath(String raw) {
  if (raw.isEmpty) return null;
  final String unified = raw.replaceAll(r'\', '/');
  if (unified.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(unified)) return null;

  final List<String> parts = [];
  for (final String segment in unified.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') return null;
    if (segment.contains(':')) return null;
    // Trailing dots and spaces are silently dropped by Windows.
    final String cleaned = segment.replaceAll(RegExp(r'[\x00-\x1f]'), '').trimRight();
    if (cleaned.isEmpty || cleaned.endsWith('.')) return null;
    final String base = cleaned.split('.').first.toLowerCase();
    if (_reservedNames.contains(base)) return null;
    parts.add(cleaned);
  }
  return parts.isEmpty ? null : parts.join('/');
}

// Full destination path for a manifest entry, refusing anything that would
// escape the receive folder. Checked after canonicalization, not by string.
Future<String?> resolveInside(String baseDir, String relPath) async {
  final String? safe = sanitizeRelPath(relPath);
  if (safe == null) return null;
  final String full = p.normalize(p.join(baseDir, safe));
  final String base = p.normalize(baseDir);
  if (!p.isWithin(base, full)) return null;
  return full;
}

// 'photo.jpg' -> 'photo (1).jpg' when taken. The .part twin counts as taken
// too, so two transfers of the same name cannot collide mid-flight.
Future<String> uniquePath(String fullPath) async {
  if (!await _taken(fullPath)) return fullPath;
  final String dir = p.dirname(fullPath);
  final String ext = p.extension(fullPath);
  final String stem = p.basenameWithoutExtension(fullPath);
  for (int i = 1; i < 10000; i++) {
    final String candidate = p.join(dir, '$stem ($i)$ext');
    if (!await _taken(candidate)) return candidate;
  }
  return p.join(dir, '$stem ${DateTime.now().millisecondsSinceEpoch}$ext');
}

Future<bool> _taken(String path) async =>
    await File(path).exists() ||
    await Directory(path).exists() ||
    await File('$path$partSuffix').exists();
