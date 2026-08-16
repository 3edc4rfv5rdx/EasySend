import 'dart:convert';
import 'dart:io' show InternetAddress;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

// Imported as well as re-exported: globals.dart itself holds the shared state
// typed with these models.
import 'models.dart';

export 'file_helpers.dart';
export 'models.dart';
export 'settings_helpers.dart';
export 'ui_helpers.dart';

// Global key for accessing ScaffoldMessenger
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
// Global key for NavigatorState
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

const String prgName = 'easysend';
const String progVersion = '0.4.260816';
const int buildNumber = 109;
const String progAuthor = 'Eugen';

const String langFile = 'assets/locales.json';
const String settFile = 'settings.json';

// Where Android puts the user's own storage. Every path the app shows or picks
// on a phone starts here, so it is also the prefix worth hiding when a path is
// too long for its line.
const String androidRoot = '/storage/emulated/0';

// UDP discovery is stable even when the user changes the HTTP transfer port.
const int defaultPort = 15353;
const int discoveryPort = 15353;
const String discoveryMulticastGroup = '239.255.53.53';
const String apiPrefix = '/api/v1';
// Announce every 5 s, forget a silent device after 20 s.
const int announceIntervalSec = 5;
const int deviceTimeoutSec = 20;
// How long a row keeps saying that this device left rather than went quiet.
// The same minute a discovered device is kept in the list after falling silent.
const int departedNoticeSec = 60;
// Manual devices send no announces, so they are polled over HTTP instead.
const int manualPollSec = 10;
const int manualPollTimeoutSec = 2;
// Seconds the receiver waits for the user to accept an unknown sender.
const int acceptTimeoutSec = 30;
// Valid protocol progress refreshes this receiver-side inactivity deadline.
const int receiveSessionTimeoutSec = 60;
// A camera folder holds thousands of files, and a folder is picked whole.
const int maxManifestFiles = 3000;
// The manifest travels inside this, so the two move together: a full manifest
// of real paths has to fit, with room for deeper ones than a phone produces.
const int maxPrepareBodyBytes = 4 * 1024 * 1024;
// What one entry of that manifest costs besides its own path: the id, the
// declared size, and the punctuation around them. Rounded up from the 83 bytes
// the widest real entry takes, so the sender refuses a shade earlier than the
// receiver would rather than a shade later.
const int manifestEntryOverheadBytes = 96;
// And everything in the body that is not the file list — the sender's id and
// name and the fields around them, each bounded in its own right.
const int manifestEnvelopeBytes = 1024;
const int maxProtocolIdBytes = 128;
const int maxSenderNameBytes = 256;
const int maxDeclaredFileBytes = 16 * 1024 * 1024 * 1024 * 1024;
const int maxDeclaredTransferBytes = 64 * 1024 * 1024 * 1024 * 1024;
const int maxInfoBodyBytes = 64 * 1024;
const int maxPlatformBytes = 32;
// An announce is a handful of short fields; anything larger is not one.
const int maxDiscoveryPacketBytes = 4 * 1024;
const int protocolBodyTimeoutSec = 5;
// Small control bodies have a wall-clock deadline too: periodic single bytes
// must not retain sender/receiver ownership forever.
const int protocolBodyTotalTimeoutSec = 15;
const int networkConnectTimeoutSec = 3;
const int networkHeaderTimeoutSec = 5;
const int networkIdleTimeoutSec = 10;
const int consentTransportMarginSec = 3;
// Automatic re-sends of a file that failed its checksum. The same allowance
// covers asking again for a confirmation whose answer never arrived: both are
// the protocol trying once more without troubling anyone.
const int maxResendAttempts = 2;
// What the receiver answers about a file it has already verified and published.
// Its own reason rather than a plain out-of-order refusal, because a sender
// that reads this counts the file as delivered instead of failing it and
// offering a retry that would publish a second copy of it.
const String reasonAlreadyVerified = 'already-verified';
// What the receiver answers to a request naming a session it does not have:
// stopped from that side, timed out, or already closed. Its own reason rather
// than a bare bad request, because the sender has to give the whole transfer up
// at once instead of offering every remaining file to a receiver that has
// nowhere to put any of them.
const String reasonNoSession = 'no-session';
// The one refusal of a verify that means the file arrived damaged, as against
// every other reason a verify can be refused. Named on both sides so the sender
// can tell the mismatch it retries for from the refusals it cannot mend.
const String reasonChecksum = 'crc';
// Speed and ETA are averaged over this window; the instant value is unreadable.
const int speedWindowSec = 5;
// Log lines one transfer keeps. A run of three thousand files writes one line
// each, and only the tail of that is ever read.
const int maxTransferEvents = 500;

enum DeviceNameProblem { empty, tooLong, controlCharacter }

DeviceNameProblem? validateDeviceName(String value, {bool allowEmpty = false}) {
  if (value.isEmpty) {
    return allowEmpty ? null : DeviceNameProblem.empty;
  }
  if (utf8.encode(value).length > maxSenderNameBytes) {
    return DeviceNameProblem.tooLong;
  }
  if (value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f]'))) {
    return DeviceNameProblem.controlCharacter;
  }
  return null;
}

bool isValidDeviceName(String value, {bool allowEmpty = false}) =>
    validateDeviceName(value, allowEmpty: allowEmpty) == null;

// Whether leaving the app has a question to ask first. A running transfer is
// always worth one; an idle app only when the user asked to be asked.
//
// The notification's Exit button needs the same answer before it is even built:
// a confirmation can only be answered when the app is on screen, so a button
// that leads to one has to open the app instead of exiting from the shade.
bool exitNeedsConfirmation({
  required bool transferRunning,
  required bool askBeforeExit,
}) => transferRunning || askBeforeExit;

// Whether ✕ closes the screen and leaves the receiver running.
//
// "Receive in background" promises that the device keeps receiving once the app
// is out of the way, and an exit that silently revoked it made the switch mean
// nothing. So ✕ closes the screen, the service and its notification stay, and
// the Exit button on that notification is the way out of the app.
//
// Not while background readiness is lost: with the service timed out there is
// nothing left to keep receiving with, and ✕ has to mean a full exit again.
bool exitKeepsReceiving({
  required bool android,
  required bool mayKeepReceiving,
  required bool receiveInBackground,
  required bool backgroundReady,
}) =>
    android && mayKeepReceiving && receiveInBackground && backgroundReady;

// Subdirectory created inside the system downloads folder.
const String recvDirName = 'EasySend';

// Languages and themes are both data, not code: add a locale to
// locales.json or a palette to colors.json and it shows up in settings.
const String colorsFile = 'assets/colors.json';

// Code -> name, read from the '_language_name' section of locales.json.
// A language name is written in its own language and never translated.
Map<String, String> langNames = {'en': 'English'};

List<String> get appLANGUAGES => langNames.keys.toList();

// Palettes read from colors.json, keyed by theme name.
Map<String, Map<String, String>> loadedThemes = {};

// 'System' is not a palette but a choice between the light and dark ones.
const String themeSystem = 'System';
const String themeLight = 'Light';
const String themeDark = 'Dark';

List<String> get appTHEMES => [themeSystem, ...loadedThemes.keys];

// Current theme colors, replaced wholesale by applyTheme().
Color clFon = const Color(0xFFFFF8E1);
// The surface a button sits on: a step off the background, so a control is a
// filled shape and not a rectangle of frame.
Color clButton = const Color(0xFFC8D2DC);
Color clSel = const Color(0x4DFFA500);
Color clUpBar = const Color(0xFFDAA520);
// What is legible on top of clUpBar: an accent bright enough to need dark text
// is exactly what a fixed foreground colour gets wrong.
Color clUpBarText = const Color(0xFF000000);
// The colour that has to be seen — Send, switches, checkboxes, dialog buttons,
// the drop target. Split off the app bar so the bar can be quiet without
// taking every control down with it; onColor() finds the ink for it.
Color clAccent = const Color(0xFF37698C);
Color clText = const Color(0xFF000000);
Color clFill = const Color(0xFFFFFFFF);
Color clFrame = const Color(0xFF9E9E9E);
// One step quieter than body text, for everything secondary: an offline device
// and its icon, the small remove buttons, a row's chevron, the bar of a
// cancelled transfer. Dimmed from the text colour and never drawn in clFrame —
// the frame is tuned to be the faintest thing on the screen and gives a mere
// 1.9:1 against the Light background, where readable content needs 4.5:1.
//
// The step is set by the worst surface it lands on, not the page: a device can
// be selected and then go offline, leaving this ink on the selection tint. That
// costs Dark about a point of contrast, so 0.6 reads 4.15:1 there while looking
// fine everywhere else. 0.65 is the lowest step that clears 4.5:1 on both
// surfaces in every palette; theme_contrast_test.dart holds the line for any
// palette added later.
Color get clTextMuted => clText.withValues(alpha: 0.65);
// Transfer progress: deliberately the loudest colour on the screen.
Color clProgress = const Color(0xFFFF9800);
// Everything arrived and the far end never confirmed it. Its own colour rather
// than a shade of warning: the bar has to say at a glance that this is neither
// the clean finish nor a failure, and every other outcome on that bar is warm —
// progress, warning and error all sit within a few degrees of orange and red,
// so a violet is the one hue nothing else on the row can be mistaken for.
Color clUnconfirmed = const Color(0xFF75579B);

// Meaning, not hue: every message colour comes from the palette, so a theme
// owns the whole screen instead of half of it.
Color clError = const Color(0xFFC62828);
Color clWarning = const Color(0xFFEF6C00);
Color clInfo = const Color(0xFF1565C0);
Color clSuccess = const Color(0xFF2E7D32);
// Reachable devices; read from the palette like everything else.
Color clGreen = const Color(0xFF43A047);
// A device that closed the app instead of merely going quiet. Filled badge, so
// the colour is light on purpose: the icon inside is painted by contrast with
// it (onColor) and is what carries the mark on a light palette.
Color clDeparted = const Color(0xFFF0A93C);

// Snack bars are painted from the Dark palette whatever theme is on: a strip
// floating over the page reads best in those tones, and a warning then looks
// the same wherever it pops up. Filled in by loadThemes().
Color clSnackError = const Color(0xFFE4695C);
Color clSnackWarning = const Color(0xFFE09A4E);
Color clSnackInfo = const Color(0xFF6FB0DA);
Color clSnackSuccess = const Color(0xFF56C08A);
Color clSnackAccent = const Color(0xFF37698C);

// One corner for every button and dialog. Halfway between the utilitarian 8
// and the stadium a 40 px button would need: soft, without becoming a capsule.
const double btnRadius = 14;

const double fsSmall = 13; // Small font size
const double fsNormal = 15; // Main font size
const double fsLarge = 18; // Font size for headers

const FontWeight fwBold = FontWeight.bold;
const FontWeight fwNormal = FontWeight.normal;

// Common text styles (non-const because colors change with theme)
TextStyle get tsSmall =>
    TextStyle(fontSize: fsSmall, fontWeight: fwNormal, color: clText);
TextStyle get tsNormal =>
    TextStyle(fontSize: fsNormal, fontWeight: fwNormal, color: clText);
TextStyle get tsLarge =>
    TextStyle(fontSize: fsLarge, fontWeight: fwNormal, color: clText);

// Global Map for settings, persisted to settings.json. Keys starting with a dot
// are internal and never shown in the settings screen.
Map<String, dynamic> defaultSettings() => {
  'Program language': 'en',
  'Color theme': 'System',
  'Device name': '',
  'Receive folder': '',
  'Port': '$defaultPort',
  'Receive in background': 'false',
  'Ask before exit': 'true',
  '.Device id': '',
  '.First start': 'true',
  '.Prog version': progVersion,
  '.Window bounds': '',
  '.External id fallback': 'false',
};

Map<String, dynamic> xdef = defaultSettings();

// Resolved at startup in initPaths()
String xvConfigDir = '';
String xvRecvDir = '';
// This device, filled in at startup
String xvDeviceId = '';
String xvDeviceName = '';
String xvPlatform = '';

bool xvDarkNow = false;

// Bumped whenever the whole app must rebuild: language or theme change.
final ValueNotifier<int> appRebuild = ValueNotifier<int>(0);
void rebuildApp() => appRebuild.value++;

// Bumped when the device list changes, so the screen can follow discovery.
final ValueNotifier<int> devicesTick = ValueNotifier<int>(0);
void devicesChanged() => devicesTick.value++;

// Bumped when a transfer starts, progresses or ends.
final ValueNotifier<int> transfersTick = ValueNotifier<int>(0);
void transfersChanged() => transfersTick.value++;

// Bumped when the receive server goes up or down, so the port-busy banner
// appears and disappears on its own.
final ValueNotifier<int> serverTick = ValueNotifier<int>(0);
void serverStateChanged() => serverTick.value++;

// Transfers in both directions. Finished ones stay until restart so the user
// can open what arrived; no history is kept between runs.
List<TransferSession> xvTransfers = [];

// This device is sending right now.
//
// One transfer at a time, whichever way it goes. The receiver and the sender
// are separate machines that knew nothing of each other, so a device could be
// sending to one peer while another peer sent to it — nothing this app ever
// promised, and it left a single Stop button acting on whichever of the two
// happened to be first in the list. An incoming request asks this and answers
// the same 'busy' a second peer gets.
bool outgoingTransferRunning() =>
    xvTransfers.any((TransferSession t) => t.isRunning && !t.incoming);

// An address learned over the wire is worth keeping only if we could dial it
// back. A loopback source means the sender runs on this very machine — a second
// copy of the app, or an emulator whose packets arrive through NAT — and
// dialling 127.0.0.1 would reach our own server instead of it.
bool isReachableAddress(String address) {
  final InternetAddress? ip = InternetAddress.tryParse(address);
  return ip != null && !ip.isLoopback;
}

// What a peer says about itself, from a UDP announce or from an /info answer.
// `name` is returned as it came, empty included: a discovered device falls back
// to its id, a remembered one keeps the name it already had.
typedef PeerInfo = ({String id, String name, String platform, int port});

// Both channels are equally unauthenticated, so both are held to the shape the
// transfer protocol holds a sender to. Deliberately not a UUID check: /prepare
// accepts any bounded id, a stricter rule here would only disagree with it, and
// an id is an identifier, not a credential.
PeerInfo? validatedPeerInfo(dynamic decoded, {required int fallbackPort}) {
  if (decoded is! Map) return null;
  final dynamic id = decoded['id'];
  final dynamic name = decoded['name'];
  final dynamic platform = decoded['platform'];
  final dynamic port = decoded['port'];
  if (id is! String ||
      id.isEmpty ||
      utf8.encode(id).length > maxProtocolIdBytes) {
    return null;
  }
  if (name != null &&
      (name is! String || !isValidDeviceName(name, allowEmpty: true))) {
    return null;
  }
  if (platform != null &&
      (platform is! String ||
          utf8.encode(platform).length > maxPlatformBytes)) {
    return null;
  }
  if (port != null && (port is! int || port < 1 || port > 65535)) return null;
  return (
    id: id,
    name: name is String ? name : '',
    platform: platform is String ? platform : '',
    port: port is int ? port : fallbackPort,
  );
}

bool isValidDeviceId(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
).hasMatch(value);

// '#RRGGBB' or '#AARRGGBB' -> Color. Missing alpha means fully opaque.
Color hexToColor(String hex) {
  String value = hex.replaceAll('#', '');
  if (value.length == 6) value = 'FF$value';
  return Color(int.tryParse(value, radix: 16) ?? 0xFF000000);
}

// Read every palette from colors.json. Without them the app still runs on the
// built-in defaults above, just with no way to switch.
Future<void> loadThemes() async {
  try {
    final String jsonString = await rootBundle.loadString(colorsFile);
    final Map<String, dynamic> data = json.decode(jsonString);
    loadedThemes = {};
    data.forEach((name, colors) {
      if (colors is Map) loadedThemes[name] = Map<String, String>.from(colors);
    });
    myPrint(
      'loaded ${loadedThemes.length} themes: ${loadedThemes.keys.join(', ')}',
    );
    // The snack bar tones live outside the current theme, so they are read once
    // here rather than in applyTheme().
    final Map<String, String>? dark = loadedThemes[themeDark];
    if (dark != null) {
      clSnackError = hexToColor(dark['error'] ?? '#E4695C');
      clSnackWarning = hexToColor(dark['warning'] ?? '#E09A4E');
      clSnackInfo = hexToColor(dark['info'] ?? '#6FB0DA');
      clSnackSuccess = hexToColor(dark['success'] ?? '#56C08A');
      clSnackAccent = hexToColor(dark['accent'] ?? dark['appBar'] ?? '#37698C');
    }
  } catch (e) {
    myPrint('loadThemes failed: $e');
    loadedThemes = {};
  }
}

// Read the language codes and their names from locales.json.
Future<void> loadLanguageNames() async {
  try {
    final String jsonString = await rootBundle.loadString(langFile);
    final Map<String, dynamic> data = json.decode(jsonString);
    final dynamic section = data['_language_name'];
    if (section is Map && section.isNotEmpty) {
      langNames = Map<String, String>.from(section);
      myPrint('languages: ${langNames.keys.join(', ')}');
    }
  } catch (e) {
    myPrint('loadLanguageNames failed: $e');
  }
}

// Which palette the stored setting resolves to right now.
String resolveThemeName(Brightness platformBrightness) {
  final String stored = xdef['Color theme'] as String? ?? themeSystem;
  if (stored != themeSystem && loadedThemes.containsKey(stored)) return stored;
  return platformBrightness == Brightness.dark ? themeDark : themeLight;
}

void applyTheme(String themeName) {
  final Map<String, String>? theme = loadedThemes[themeName];
  if (theme == null) {
    myPrint('theme $themeName not found, keeping current colors');
    return;
  }
  clFon = hexToColor(theme['background'] ?? '#FFFFFF');
  clButton = hexToColor(theme['button'] ?? '#C8D2DC');
  clSel = hexToColor(theme['selected'] ?? '#4DFFA500');
  clUpBar = hexToColor(theme['appBar'] ?? '#DAA520');
  // A palette without an accent of its own keeps the old behaviour: the bar
  // colour doubles as the accent.
  clAccent = hexToColor(theme['accent'] ?? theme['appBar'] ?? '#37698C');
  clText = hexToColor(theme['text'] ?? '#000000');
  clUpBarText = hexToColor(theme['appBarText'] ?? theme['text'] ?? '#000000');
  clFill = hexToColor(theme['fill'] ?? '#FFFFFF');
  clFrame = hexToColor(theme['frame'] ?? '#9E9E9E');
  clProgress = hexToColor(theme['progress'] ?? '#FF9800');
  clUnconfirmed = hexToColor(theme['unconfirmed'] ?? '#75579B');
  clGreen = hexToColor(theme['online'] ?? '#43A047');
  clDeparted = hexToColor(theme['departed'] ?? '#F0A93C');
  clError = hexToColor(theme['error'] ?? '#C62828');
  clWarning = hexToColor(theme['warning'] ?? '#EF6C00');
  clInfo = hexToColor(theme['info'] ?? '#1565C0');
  clSuccess = hexToColor(theme['success'] ?? '#2E7D32');
  // Read off the background rather than the name: a dark palette of any name
  // needs the same lighter dialog frame that 'Dark' does.
  xvDarkNow = clFon.computeLuminance() < 0.4;
}

// Function to initialize translations
Map<String, String> _translationCache = {};

// Load localizations for the current language from the JSON file
Future<void> initTranslations() async {
  // The code is used exactly as it appears in the '_language_name' section of
  // locales.json, which is what the translation entries are keyed by too.
  final String lang = xdef['Program language'] as String;
  // No cache needed for English: the keys are the English strings
  if (lang == 'en') {
    _translationCache.clear();
    return;
  }
  try {
    final String jsonString = await rootBundle.loadString(langFile);
    final Map<String, dynamic> allTranslations = json.decode(jsonString);
    _translationCache.clear();
    allTranslations.forEach((key, value) {
      if (key.startsWith('_')) return;
      if (value is Map && value.containsKey(lang)) {
        _translationCache[key] = value[lang];
      }
    });
    myPrint(
      'initTranslations finished, loaded ${_translationCache.length} translations',
    );
  } catch (e) {
    myPrint('Error initializing translations: $e');
    _translationCache.clear();
  }
}

// Function to translate a word
String lw(String wrd) {
  if (xdef['Program language'] == 'en') return wrd;
  // Marker on purpose, in release too: builds here are always release, and a
  // missing translation has to be visible rather than silently English.
  return _translationCache[wrd] ?? '(( $wrd ))';
}

// 1536 -> '1.5 KB'. Binary units, decimal-looking labels, as file managers show.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const List<String> units = ['KB', 'MB', 'GB', 'TB'];
  double value = bytes / 1024;
  int unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final String text = value >= 100
      ? value.toStringAsFixed(0)
      : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String _two(int v) => v.toString().padLeft(2, '0');

// 2026-08-07 14:30
String formatDateTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

// 14:30:07. Log lines happen seconds apart, so the date would only repeat.
String formatClock(DateTime t) =>
    '${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}';

String formatSpeed(double bytesPerSec) =>
    '${formatBytes(bytesPerSec.round())}/s';

// 95 -> '1:35'. Used for the remaining-time estimate.
String formatDuration(int seconds) {
  if (seconds < 0) seconds = 0;
  final int h = seconds ~/ 3600;
  final int m = (seconds % 3600) ~/ 60;
  final int s = seconds % 60;
  final String mm = m.toString().padLeft(h > 0 ? 2 : 1, '0');
  final String ss = s.toString().padLeft(2, '0');
  return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
}

// The log belongs to development: a release build is silent, and nothing has to
// rewrite this file during a build to make it so.
// One-at-a-time queue: work is chained onto the tail so two calls never
// overlap. A failure is logged and dropped rather than stored — a rejected tail
// makes every later `then` skip its callback and hand back the same old
// failure, which would silently stop the queue for the rest of the run.
class SerialQueue {
  final String name;
  Future<void> _tail = Future<void>.value();

  SerialQueue(this.name);

  Future<void> add(Future<void> Function() work) {
    _tail = _tail.then((_) async {
      try {
        await work();
      } catch (e, st) {
        myPrint('$name failed: $e\n$st');
      }
    });
    return _tail;
  }
}

void myPrint(String msg) {
  if (kDebugMode) debugPrint('>>> $msg');
}
