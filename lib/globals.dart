import 'dart:convert';
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
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
// Global key for NavigatorState
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

const String prgName = 'easysend';
const String progVersion = '0.1.260810';
const int buildNumber = 51;
const String progAuthor = 'Eugen';

const String langFile = 'assets/locales.json';
const String settFile = 'settings.json';

// Where Android puts the user's own storage. Every path the app shows or picks
// on a phone starts here, so it is also the prefix worth hiding when a path is
// too long for its line.
const String androidRoot = '/storage/emulated/0';

// Network defaults. One number serves both the TCP receive server and UDP
// discovery: TCP and UDP are separate port spaces, so they never collide.
const int defaultPort = 15353;
const String apiPrefix = '/api/v1';
// Announce every 5 s, forget a silent device after 20 s.
const int announceIntervalSec = 5;
const int deviceTimeoutSec = 20;
// Manual devices send no announces, so they are polled over HTTP instead.
const int manualPollSec = 10;
const int manualPollTimeoutSec = 2;
// Incoming files carry this suffix until their checksum is verified.
const String partSuffix = '.easysend-part';
// Seconds the receiver waits for the user to accept an unknown sender.
const int acceptTimeoutSec = 30;
// Automatic re-sends of a file that failed its checksum.
const int maxResendAttempts = 2;
// Speed and ETA are averaged over this window; the instant value is unreadable.
const int speedWindowSec = 5;

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
// Transfer progress: deliberately the loudest colour on the screen.
Color clProgress = const Color(0xFFFF9800);

// Meaning, not hue: every message colour comes from the palette, so a theme
// owns the whole screen instead of half of it.
Color clError = const Color(0xFFC62828);
Color clWarning = const Color(0xFFEF6C00);
Color clInfo = const Color(0xFF1565C0);
Color clSuccess = const Color(0xFF2E7D32);
// Reachable devices; read from the palette like everything else.
Color clGreen = const Color(0xFF43A047);

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

const double fsSmall = 13;  // Small font size
const double fsNormal = 15; // Main font size
const double fsLarge = 18;  // Font size for headers

const FontWeight fwBold = FontWeight.bold;
const FontWeight fwNormal = FontWeight.normal;

// Common text styles (non-const because colors change with theme)
TextStyle get tsSmall => TextStyle(fontSize: fsSmall, fontWeight: fwNormal, color: clText);
TextStyle get tsNormal => TextStyle(fontSize: fsNormal, fontWeight: fwNormal, color: clText);
TextStyle get tsLarge => TextStyle(fontSize: fsLarge, fontWeight: fwNormal, color: clText);

// Global Map for settings, persisted to settings.json. Keys starting with a dot
// are internal and never shown in the settings screen.
Map<String, dynamic> xdef = {
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
};

bool xvDebug = true;
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
    myPrint('loaded ${loadedThemes.length} themes: ${loadedThemes.keys.join(', ')}');
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
  clGreen = hexToColor(theme['online'] ?? '#43A047');
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
    myPrint('initTranslations finished, loaded ${_translationCache.length} translations');
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
  final String text = value >= 100 ? value.toStringAsFixed(0) : value.toStringAsFixed(1);
  return '$text ${units[unit]}';
}

String _two(int v) => v.toString().padLeft(2, '0');

// 2026-08-07 14:30
String formatDateTime(DateTime t) =>
    '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

String formatSpeed(double bytesPerSec) => '${formatBytes(bytesPerSec.round())}/s';

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

void myPrint(String msg) {
  if (xvDebug) debugPrint('>>> $msg');
}
