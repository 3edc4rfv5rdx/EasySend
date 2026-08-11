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
  await loadThemes();
  await loadLanguageNames();
  await loadSettings();
  await initIdentity();
  // A palette dropped from colors.json must not linger in the settings as a
  // name nothing answers to.
  if (xdef['Color theme'] != themeSystem &&
      !loadedThemes.containsKey(xdef['Color theme'])) {
    xdef['Color theme'] = themeSystem;
  }
  await initTranslations();
  await initNotifications();

  if (Platform.isAndroid) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } else {
    final bounds = parseWindowBounds(xdef['.Window bounds'] as String? ?? '');
    await windowManager.ensureInitialized();
    await windowManager.waitUntilReadyToShow(
      WindowOptions(
        size: bounds == null ? _desktopSize : Size(bounds.width, bounds.height),
        minimumSize: _desktopMinSize,
        title: 'EasySend',
        center: bounds == null,
      ),
      () async {
        if (bounds != null) {
          await windowManager.setPosition(Offset(bounds.x, bounds.y));
        }
        await windowManager.show();
        await windowManager.focus();
      },
    );
    // The frame's close button must ask about a running transfer like the one
    // in the bar does; the home screen listens for it and exits from there.
    await windowManager.setPreventClose(true);
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
    if (xdef['Color theme'] == themeSystem) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: appRebuild,
      builder: (context, tick, child) {
        final String themeName = resolveThemeName(
          WidgetsBinding.instance.platformDispatcher.platformBrightness,
        );
        applyTheme(themeName);
        // Taken from the palette's own background, so a dark palette under any
        // name gets dark stock widgets too.
        final bool dark = xvDarkNow;
        return MaterialApp(
          title: 'EasySend',
          debugShowCheckedModeBanner: false,
          navigatorKey: navigatorKey,
          scaffoldMessengerKey: scaffoldMessengerKey,
          theme: _buildTheme(dark),
          scrollBehavior: const _PlainScroll(),
          // A palette change is a repaint, not a show.
          themeAnimationDuration: Duration.zero,
          // Not const: an identical widget would let Flutter skip rebuilding
          // the subtree, and the screen would keep the previous language.
          home: HomeScreen(),
        );
      },
    );
  }
}

// A list stops at its end and stays there: no stretch, no glow, no bounce, on
// any platform. Applied to the whole app, not to one list.
class _PlainScroll extends MaterialScrollBehavior {
  const _PlainScroll();

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const ClampingScrollPhysics();
}

// Screens replace each other outright: no slide, no fade, on any platform.
class _NoPageTransition extends PageTransitionsBuilder {
  const _NoPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

// Material theme built from the same color globals the screens use, so stock
// widgets match the hand-styled ones.
ThemeData _buildTheme(bool dark) {
  return ThemeData(
    useMaterial3: true,
    // SPEC 4 asks for one layout on every platform, and these two are the
    // reason it was not one: ThemeData takes both from the running platform,
    // giving desktop a compact density and no minimum tap target, so the same
    // widget came out 4 to 7 px shorter on Linux than on the phone. Said
    // outright, a control is the size it was drawn at wherever it runs.
    visualDensity: VisualDensity.standard,
    materialTapTargetSize: MaterialTapTargetSize.padded,
    pageTransitionsTheme: PageTransitionsTheme(
      builders: <TargetPlatform, PageTransitionsBuilder>{
        for (final TargetPlatform platform in TargetPlatform.values)
          platform: const _NoPageTransition(),
      },
    ),
    // No ink spreading out of a tap either.
    splashFactory: NoSplash.splashFactory,
    splashColor: Colors.transparent,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    colorScheme: ColorScheme.fromSeed(
      seedColor: clAccent,
      brightness: dark ? Brightness.dark : Brightness.light,
      surface: clFon,
      error: clError,
    ),
    scaffoldBackgroundColor: clFon,
    appBarTheme: AppBarTheme(
      backgroundColor: clUpBar,
      foregroundColor: clUpBarText,
      elevation: 2,
      centerTitle: false,
    ),
    dividerColor: clFrame,
    // An empty box drawn in the frame colour is the quietest thing on the
    // screen, and this one asks whether to delete the user's files. The accent
    // is what the eye is meant to find.
    checkboxTheme: CheckboxThemeData(
      side: BorderSide(color: clAccent, width: 2.5),
    ),
  );
}
