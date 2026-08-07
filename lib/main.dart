import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'android_helpers.dart';
import 'globals.dart';
import 'home_screen.dart';

// Portrait layout on every platform, desktop included: one narrow column keeps
// the UI identical everywhere (SPEC 4).
const Size _desktopSize = Size(420, 800);
const Size _desktopMinSize = Size(380, 640);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await initPaths();
  await loadSettings();
  await initIdentity();
  await initTranslations();
  await initNotifications();

  if (Platform.isAndroid) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } else {
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: _desktopSize,
        minimumSize: _desktopMinSize,
        title: 'EasySend',
        center: true,
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    );
  }

  runApp(const EasySendApp());
}

class EasySendApp extends StatefulWidget {
  const EasySendApp({super.key});

  @override
  State<EasySendApp> createState() => _EasySendAppState();
}

class _EasySendAppState extends State<EasySendApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The 'System' theme has to follow the platform, so react to its changes.
  @override
  void didChangePlatformBrightness() {
    if (xdef['Color theme'] == 'System') setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: appRebuild,
      builder: (context, tick, child) {
        final bool dark = isDarkTheme(
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
        );
        initThemeColors(dark);
        return MaterialApp(
          title: 'EasySend',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          theme: _buildTheme(dark),
          // Not const: an identical widget would let Flutter skip rebuilding
          // the subtree, and the screen would keep the previous language.
          home: HomeScreen(),
        );
      },
    );
  }
}

// Material theme built from the same color globals the screens use, so stock
// widgets match the hand-styled ones.
ThemeData _buildTheme(bool dark) {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: clUpBar,
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: clFon,
    ),
    scaffoldBackgroundColor: clFon,
    appBarTheme: AppBarTheme(
      backgroundColor: clUpBar,
      foregroundColor: clText,
      elevation: 2,
      centerTitle: false,
    ),
    dividerColor: clFrame,
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: clFrame, width: 2),
    ),
  );
}
