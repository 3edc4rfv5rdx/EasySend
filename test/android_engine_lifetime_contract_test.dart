import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'Android Application owns exactly one Flutter engine, started by the Activity',
    () async {
      final String application = await File(
        'android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt',
      ).readAsString();
      final String activity = await File(
        'android/app/src/main/kotlin/a/a/easysend/MainActivity.kt',
      ).readAsString();

      expect(application, contains('flutterEngine = FlutterEngine(this)'));
      // Built by the Application, started by the first Activity. main() calls
      // into the platform before runApp, and those calls answer only once an
      // Activity is attached and the plugins are registered; starting the
      // entrypoint here raced that and could hang the app on its splash screen.
      // The delegate runs the entrypoint on first attach instead.
      expect(application, isNot(contains('executeDartEntrypoint')));
      expect(application, contains('setMethodCallHandler'));
      expect(activity, contains('override fun provideFlutterEngine'));
      expect(activity, contains('.flutterEngine'));
      expect(
        activity,
        contains('shouldDestroyEngineWithHost(): Boolean = false'),
      );
      expect(RegExp(r'=\s*FlutterEngine\(').hasMatch(activity), isFalse);
      expect(activity, isNot(contains('setMethodCallHandler')));
    },
  );

  test(
    'Activity-only operations are detached with the destroyed host',
    () async {
      final String application = await File(
        'android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt',
      ).readAsString();
      final String activity = await File(
        'android/app/src/main/kotlin/a/a/easysend/MainActivity.kt',
      ).readAsString();

      expect(application, contains('if (activity === value) activity = null'));
      expect(activity, contains('attachActivity(this)'));
      expect(activity, contains('detachActivity(this)'));
    },
  );

  test('foreground-only networking waits for the first Activity', () async {
    final String home = await File('lib/home_screen.dart').readAsString();

    expect(home, contains('lifecycleState ?? AppLifecycleState.detached'));
    expect(home, contains("xdef['Receive in background'] == 'true'"));
  });

  // Both phones here destroy the Activity while the document picker is on
  // screen, and a plugin holding the pending result in Activity-scoped state
  // loses it silently. The result must therefore be taken by the Activity and
  // handed on through the process-owned channel, which survives that.
  test('picking files survives the Activity that opened the picker', () async {
    final String activity = await File(
      'android/app/src/main/kotlin/a/a/easysend/MainActivity.kt',
    ).readAsString();
    final String application = await File(
      'android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt',
    ).readAsString();
    final String helpers = await File('lib/android_helpers.dart').readAsString();
    final String home = await File('lib/home_screen.dart').readAsString();

    expect(activity, contains('override fun onActivityResult'));
    // Other request codes still belong to the plugins, the folder picker among
    // them, so the delegate has to be called as well.
    expect(activity, contains('super.onActivityResult'));
    expect(activity, contains('ACTION_OPEN_DOCUMENT'));
    expect(activity, contains('deliverPickedFiles'));
    expect(application, contains('serviceChannel.invokeMethod("filesPicked"'));
    expect(helpers, contains("case 'filesPicked':"));
    expect(helpers, contains('pickFilesFromActivity'));
    expect(home, contains('pickFilesFromActivity'));
  });
}
