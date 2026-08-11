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
    return p.join(androidRoot, 'Download', recvDirName);
  }
  try {
    final Directory? downloads = await getDownloadsDirectory();
    if (downloads != null) return p.join(downloads.path, recvDirName);
  } catch (e) {
    myPrint('getDownloadsDirectory failed: $e');
  }
  final String home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? '';
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
final SerialQueue _saveQueue = SerialQueue('settings save');
int _saveSerial = 0;

String? _validSetting(String key, dynamic value) {
  if (value is! String) return null;
  switch (key) {
    case 'Program language':
      return langNames.containsKey(value) ? value : null;
    case 'Color theme':
      return value == themeSystem || loadedThemes.containsKey(value)
          ? value
          : null;
    case 'Port':
      final int? port = int.tryParse(value);
      return port != null && port >= 1024 && port <= 65535 ? '$port' : null;
    case 'Receive in background':
    case 'Ask before exit':
    case '.First start':
    case '.External id fallback':
      return value == 'true' || value == 'false' ? value : null;
    case 'Device name':
      return value.length <= 128 && !value.contains(RegExp(r'[\x00-\x1f]'))
          ? value
          : null;
    case 'Receive folder':
      return value.length <= 4096 && !value.contains('\u0000') ? value : null;
    case '.Device id':
      return value.isEmpty || isValidDeviceId(value) ? value : null;
    case '.Prog version':
      return RegExp(r'^\d+\.\d+\.\d+$').hasMatch(value) ? value : null;
    case '.Window bounds':
      return value.isEmpty || parseWindowBounds(value) != null ? value : null;
  }
  return null;
}

Device? _validDevice(dynamic raw) {
  if (raw is! Map) return null;
  final Map<String, dynamic> data;
  try {
    data = raw.cast<String, dynamic>();
  } catch (_) {
    return null;
  }
  final dynamic id = data['id'];
  final dynamic name = data['name'];
  final dynamic address = data['address'];
  final dynamic port = data['port'];
  final dynamic trusted = data['trusted'];
  final dynamic manual = data['manual'];
  final dynamic platform = data['platform'];
  if (id is! String ||
      id.isEmpty ||
      name is! String ||
      name.isEmpty ||
      address is! String ||
      port is! int ||
      port < 1 ||
      port > 65535 ||
      trusted is! bool ||
      manual is! bool ||
      platform is! String) {
    return null;
  }
  if (address.isNotEmpty && InternetAddress.tryParse(address) == null) {
    return null;
  }
  return Device(
    id: id,
    name: name,
    platform: platform,
    address: address,
    port: port,
    trusted: trusted,
    manual: manual,
  );
}

// Load settings and the persisted device list. A damaged file is renamed rather
// than silently overwritten, so nothing is lost without a trace.
Future<void> loadSettings() async {
  final File f = _settingsFile;
  final File recovery = File('${f.path}.old');
  if (!await f.exists() && await recovery.exists()) {
    try {
      await recovery.rename(f.path);
    } catch (e) {
      myPrint('cannot recover settings transaction: $e');
    }
  }
  if (!await f.exists()) {
    xdef['Program language'] = initialLanguageForLocale(Platform.localeName);
    return;
  }
  try {
    final dynamic decoded = json.decode(await f.readAsString());
    if (decoded is! Map) {
      throw const FormatException('settings root is not an object');
    }
    final Map<String, dynamic> data = decoded.cast<String, dynamic>();
    final dynamic rawSettings = data['settings'];
    final Map<String, dynamic> stored = rawSettings is Map
        ? rawSettings.cast<String, dynamic>()
        : const {};
    // Only keys we know about: an old file must not resurrect dropped options.
    for (final String key in xdef.keys.toList()) {
      if (!stored.containsKey(key)) continue;
      final String? valid = _validSetting(key, stored[key]);
      if (valid != null) {
        xdef[key] = valid;
      } else {
        myPrint('invalid setting $key, using default');
      }
    }
    final dynamic rawDevices = data['devices'];
    final List<dynamic> devices = rawDevices is List ? rawDevices : const [];
    final Map<String, Device> unique = {};
    for (final dynamic raw in devices) {
      final Device? device = _validDevice(raw);
      if (device != null) unique.putIfAbsent(device.id, () => device);
    }
    xvDevices = unique.values.toList();
    myPrint('loadSettings: ${xvDevices.length} stored devices');
  } catch (e) {
    myPrint('loadSettings failed: $e');
    try {
      final String stamp = DateTime.now().toUtc().toIso8601String().replaceAll(
        ':',
        '-',
      );
      await f.rename('${f.path}.$stamp.bad');
    } catch (e2) {
      myPrint('cannot rename damaged settings: $e2');
    }
  }
}

Future<void> saveSettings() => _saveQueue.add(_saveSettingsNow);

Future<void> _saveSettingsNow() async {
  File? temporary;
  try {
    await Directory(xvConfigDir).create(recursive: true);
    // Discovered-only devices are transient; persist the ones worth remembering.
    final List<Device> keep = xvDevices
        .where((d) => d.manual || d.trusted)
        .toList();
    const JsonEncoder encoder = JsonEncoder.withIndent('  ');
    final String contents = encoder.convert({
      'settings': xdef,
      'devices': keep.map((d) => d.toJson()).toList(),
    });
    final File destination = _settingsFile;
    temporary = File(
      '${destination.path}.$pid.${DateTime.now().microsecondsSinceEpoch}.${_saveSerial++}.tmp',
    );
    final RandomAccessFile output = await temporary.open(mode: FileMode.write);
    try {
      await output.writeString(contents);
      await output.flush();
    } finally {
      await output.close();
    }
    try {
      await temporary.rename(destination.path);
      temporary = null;
    } on FileSystemException {
      // Windows cannot replace an existing file with rename. Keep a recovery
      // copy so interruption between the two renames is repaired on load.
      final File old = File('${destination.path}.old');
      if (await old.exists()) await old.delete();
      if (await destination.exists()) await destination.rename(old.path);
      await temporary!.rename(destination.path);
      temporary = null;
      if (await old.exists()) await old.delete();
    }
  } catch (e) {
    myPrint('saveSettings failed: $e');
  } finally {
    if (temporary != null && await temporary.exists()) {
      try {
        await temporary.delete();
      } catch (_) {}
    }
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
    xdef['.External id fallback'] = 'true';
    final String? external = await readExternalDeviceId(
      File(p.join(xvRecvDir, '.easysend-id')),
    );
    if (external != null) return external;
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
  if (Platform.isAndroid && xdef['.External id fallback'] == 'true') {
    await writeExternalDeviceIdIfAbsent(
      File(p.join(xvRecvDir, '.easysend-id')),
      xvDeviceId,
    );
  }

  // Drop what can only lead back here: this device under its own id, and any
  // peer remembered at a loopback address. Both were written by an older build
  // and would offer to send a transfer to ourselves.
  final int before = xvDevices.length;
  xvDevices.removeWhere(
    (d) =>
        d.id == xvDeviceId ||
        (d.address.isNotEmpty && !isReachableAddress(d.address)),
  );
  if (xvDevices.length != before) {
    myPrint(
      'dropped ${before - xvDevices.length} devices pointing at ourselves',
    );
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

int get currentPort =>
    int.tryParse(xdef['Port'] as String? ?? '') ?? defaultPort;

String initialLanguageForLocale(String locale) {
  String code = locale.split(RegExp('[-_]')).first.toLowerCase();
  if (code == 'uk') code = 'ua';
  return langNames.containsKey(code) ? code : 'en';
}

Future<String?> readExternalDeviceId(File file) async {
  try {
    if (!await file.exists()) return null;
    final String value = (await file.readAsString()).trim();
    return isValidDeviceId(value) ? value : null;
  } catch (e) {
    myPrint('cannot read ${file.path}: $e');
    return null;
  }
}

Future<bool> writeExternalDeviceIdIfAbsent(File file, String id) async {
  if (!isValidDeviceId(id)) return false;
  try {
    if (await file.exists()) {
      return await readExternalDeviceId(file) == id;
    }
    await file.parent.create(recursive: true);
    await file.writeAsString('$id\n', flush: true);
    return true;
  } catch (e) {
    myPrint('cannot write ${file.path}: $e');
    return false;
  }
}

({double x, double y, double width, double height})? parseWindowBounds(
  String value,
) {
  final List<double?> fields = value.split(',').map(double.tryParse).toList();
  if (fields.length != 4 || fields.any((field) => field == null)) return null;
  final double width = fields[2]!;
  final double height = fields[3]!;
  if (width < 380 || height < 640 || width > 10000 || height > 10000) {
    return null;
  }
  return (x: fields[0]!, y: fields[1]!, width: width, height: height);
}

String encodeWindowBounds({
  required double x,
  required double y,
  required double width,
  required double height,
}) => '${x.round()},${y.round()},${width.round()},${height.round()}';

// Addresses of this device, for typing into another one that cannot discover
// us by broadcast. Loopback is useless to a peer, so it is left out.
Future<List<String>> localAddresses() async {
  final List<String> found = [];
  try {
    final List<NetworkInterface> interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
      includeLinkLocal: false,
    );
    for (final NetworkInterface iface in interfaces) {
      for (final InternetAddress addr in iface.addresses) {
        found.add(addr.address);
      }
    }
  } catch (e) {
    myPrint('cannot list interfaces: $e');
  }
  return found;
}
