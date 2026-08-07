import 'dart:convert';
import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'globals.dart';

// Known peers: discovered ones live here only while seen, manual and trusted
// ones are persisted to settings.json.
List<Device> xvDevices = [];

// Namespace for deriving a stable device id out of a platform identifier.
const String _idNamespace = '6f9c1d2e-4a3b-5c6d-8e7f-0a1b2c3d4e5f';

// Config directory, explicitly built rather than taken from
// getApplicationSupportDirectory(): that would give ~/.local/share on Linux and
// an %APPDATA%\<company>\<product> nesting on Windows. We want exactly one level.
Future<String> _resolveConfigDir() async {
  if (Platform.isLinux) {
    final String xdg = Platform.environment['XDG_CONFIG_HOME'] ?? '';
    final String base = xdg.isNotEmpty
        ? xdg
        : p.join(Platform.environment['HOME'] ?? '', '.config');
    return p.join(base, 'EasySend');
  }
  if (Platform.isWindows) {
    final String appData = Platform.environment['APPDATA'] ?? '';
    if (appData.isNotEmpty) return p.join(appData, 'EasySend');
  }
  final Directory dir = await getApplicationSupportDirectory();
  return dir.path;
}

// Subdirectory inside the system downloads folder. getDownloadsDirectory()
// resolves the real localized folder (XDG_DOWNLOAD_DIR on Linux, the Downloads
// known folder on Windows), so a localized folder name is handled for us.
Future<String> _resolveRecvDir() async {
  if (Platform.isAndroid) {
    return p.join('/storage/emulated/0/Download', recvDirName);
  }
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null) return p.join(downloads.path, recvDirName);
  } catch (e) {
    myPrint('getDownloadsDirectory failed: $e');
  }
  final String home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
  if (home.isNotEmpty) return p.join(home, 'Downloads', recvDirName);
  final Directory dir = await getApplicationSupportDirectory();
  return p.join(dir.path, recvDirName);
}

Future<void> initPaths() async {
  xvConfigDir = await _resolveConfigDir();
  xvRecvDir = await _resolveRecvDir();
  myPrint('config dir: $xvConfigDir');
  myPrint('receive dir: $xvRecvDir');
}

File get _settingsFile => File(p.join(xvConfigDir, settFile));

// Load settings and the persisted device list. A damaged file is renamed rather
// than silently overwritten, so nothing is lost without a trace.
Future<void> loadSettings() async {
  final File f = _settingsFile;
  if (!await f.exists()) return;
  try {
    final Map<String, dynamic> data = json.decode(await f.readAsString());
    final Map<String, dynamic> stored = (data['settings'] as Map?)?.cast<String, dynamic>() ?? {};
    // Only keys we know about: an old file must not resurrect dropped options.
    for (final String key in xdef.keys.toList()) {
      if (stored.containsKey(key)) xdef[key] = stored[key];
    }
    final List<dynamic> devices = data['devices'] as List? ?? [];
    xvDevices = devices
        .map((d) => Device.fromJson((d as Map).cast<String, dynamic>()))
        .where((d) => d.id.isNotEmpty)
        .toList();
    myPrint('loadSettings: ${xvDevices.length} stored devices');
  } catch (e) {
    myPrint('loadSettings failed: $e');
    try {
      await f.rename('${f.path}.bad');
    } catch (e2) {
      myPrint('cannot rename damaged settings: $e2');
    }
  }
}

Future<void> saveSettings() async {
  try {
    await Directory(xvConfigDir).create(recursive: true);
    // Discovered-only devices are transient; persist the ones worth remembering.
    final List<Device> keep = xvDevices.where((d) => d.manual || d.trusted).toList();
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    await _settingsFile.writeAsString(encoder.convert({
      'settings': xdef,
      'devices': keep.map((d) => d.toJson()).toList(),
    }));
  } catch (e) {
    myPrint('saveSettings failed: $e');
  }
}

// Default name for this device: its model on Android, its host name elsewhere.
Future<String> _defaultDeviceName() async {
  try {
    if (Platform.isAndroid) {
      final AndroidDeviceInfo info = await DeviceInfoPlugin().androidInfo;
      final String model = info.model.trim();
      if (model.isNotEmpty) return model;
    }
  } catch (e) {
    myPrint('device_info failed: $e');
  }
  final String host = Platform.localHostname.trim();
  return host.isEmpty ? 'EasySend' : host;
}

// A random UUID would be lost on Android, where uninstalling wipes private
// storage — and with it the trust other devices granted us. So on Android the
// id is derived from ANDROID_ID, which survives reinstalls of the same signing
// key. On desktop the config directory survives on its own (SPEC 5.3).
Future<String> _resolveDeviceId() async {
  final String stored = xdef['.Device id'] as String? ?? '';
  if (stored.isNotEmpty) return stored;
  if (Platform.isAndroid) {
    try {
      final String? androidId = await const AndroidId().getId();
      if (androidId != null && androidId.isNotEmpty) {
        // Only the hash goes on the wire, never the raw identifier.
        return const Uuid().v5(_idNamespace, androidId);
      }
    } catch (e) {
      myPrint('ANDROID_ID unavailable: $e');
    }
  }
  return const Uuid().v4();
}

Future<void> initIdentity() async {
  xvPlatform = Platform.isAndroid
      ? 'android'
      : Platform.isWindows
          ? 'windows'
          : Platform.isLinux
              ? 'linux'
              : Platform.operatingSystem;

  xvDeviceId = await _resolveDeviceId();
  if (xdef['.Device id'] != xvDeviceId) {
    xdef['.Device id'] = xvDeviceId;
  }

  if ((xdef['Device name'] as String).isEmpty) {
    xdef['Device name'] = await _defaultDeviceName();
  }
  xvDeviceName = xdef['Device name'];

  if ((xdef['Receive folder'] as String).isEmpty) {
    xdef['Receive folder'] = xvRecvDir;
  } else {
    xvRecvDir = xdef['Receive folder'];
  }

  await saveSettings();
  myPrint('identity: $xvDeviceName [$xvPlatform] $xvDeviceId');
}

int get currentPort => int.tryParse(xdef['Port'] as String? ?? '') ?? defaultPort;
