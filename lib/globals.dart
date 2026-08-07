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
const String progVersion = '0.1.260807';
const int buildNumber = 5;
const String progAuthor = 'Eugen';

const String langFile = 'assets/locales.json';
const String settFile = 'settings.json';

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

// All program languages. English is the key language of locales.json itself.
const List<String> appLANGUAGES = ['EN', 'RU', 'UA'];

String getLocaleCode(String language) {
  // Dictionary only for exceptions where the country code differs
  const Map<String, String> exceptions = {
    'UA': 'uk', // ukraine
  };
  final String langCode = language.toUpperCase();
  return exceptions[langCode] ?? langCode.toLowerCase();
}

// Theme names as shown in settings. 'System' follows the platform brightness.
const List<String> appTHEMES = ['System', 'Light', 'Dark'];

// Theme colors, ARGB. Order: fon, menu, select, upBar, text, fill, frame.
const List<List<Color>> curTHEME = [
  // Light theme
  [
    Color(0xFFFFF8E1), // fon - screen background
    Color(0xFFB3E5FC), // menu
    Color(0x4DFFA500), // select - 30% orange
    Color(0xFFDAA520), // upBar - mustard
    Colors.black,      // text
    Colors.white,      // fill
    Colors.grey,       // frame
  ],
  // Dark theme
  [
    Color(0xFF121212), // fon - almost black
    Color(0xFF5C5C5C), // menu - medium-dark grey
    Color(0x4D6C6C6C), // select - grey with transparency
    Color(0xFF404040), // upBar - dark grey
    Color(0xFFE0E0E0), // text - light grey
    Color(0xFF4D4D4D), // fill
    Color(0xFF808080), // frame
  ],
];

// Define colors with names
Color clFon = curTHEME[0][0];
Color clMenu = curTHEME[0][1];
Color clSel = curTHEME[0][2];
Color clUpBar = curTHEME[0][3];
Color clText = curTHEME[0][4];
Color clFill = curTHEME[0][5];
Color clFrame = curTHEME[0][6];

Color clRed = Colors.red;
Color clGreen = Colors.green;

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
  'Program language': 'EN',
  'Color theme': 'System',
  'Device name': '',
  'Receive folder': '',
  'Port': '$defaultPort',
  'Receive in background': 'false',
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

void initThemeColors(bool dark) {
  final int i = dark ? 1 : 0;
  clFon = curTHEME[i][0];
  clMenu = curTHEME[i][1];
  clSel = curTHEME[i][2];
  clUpBar = curTHEME[i][3];
  clText = curTHEME[i][4];
  clFill = curTHEME[i][5];
  clFrame = curTHEME[i][6];
  xvDarkNow = dark;
}

// Resolve the stored theme name against the current platform brightness.
bool isDarkTheme(Brightness platformBrightness) {
  switch (xdef['Color theme']) {
    case 'Light':
      return false;
    case 'Dark':
      return true;
    default:
      return platformBrightness == Brightness.dark;
  }
}

// Function to initialize translations
Map<String, String> _translationCache = {};

// Load localizations for the current language from the JSON file
Future<void> initTranslations() async {
  final String lang = getLocaleCode(xdef['Program language']);
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
  if (xdef['Program language'] == 'EN') return wrd;
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
