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

  // SystemNavigator.pop() is finish(): the screen goes but the task card stays
  // in Recents, showing a snapshot of an app the user has just closed. Only the
  // Activity can remove its own task, so the exit has to reach one.
  test('the exit takes the Recents entry with it', () async {
    final String application = await File(
      'android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt',
    ).readAsString();
    final String helpers = await File('lib/android_helpers.dart').readAsString();
    final String home = await File('lib/home_screen.dart').readAsString();

    expect(application, contains('"exitApp"'));
    expect(application, contains('finishAndRemoveTask()'));
    expect(helpers, contains("invokeMethod<bool>('exitApp')"));
    expect(home, contains('finishActivityAndTask()'));
    // Without an Activity there is nothing to finish, and the screen still has
    // to close.
    expect(home, contains('SystemNavigator.pop()'));
    // Exiting from the notification can happen with no Activity at all, and the
    // task card still has to go.
    expect(application, contains('manager.appTasks'));
  });

  // Since Android 12 a notification may not start an Activity by way of a
  // service or a broadcast. The Exit button therefore has to reach the Activity
  // directly whenever the exit has a question to ask, and only a button with
  // nothing to confirm may act through the service.
  test('notification buttons reach the right component', () async {
    final String service = await File(
      'android/app/src/main/kotlin/a/a/easysend/TransferService.kt',
    ).readAsString();
    final String activity = await File(
      'android/app/src/main/kotlin/a/a/easysend/MainActivity.kt',
    ).readAsString();
    final String helpers = await File('lib/android_helpers.dart').readAsString();
    final String home = await File('lib/home_screen.dart').readAsString();

    expect(service, contains('ACTION_NOTIFY_STOP'));
    expect(service, contains('ACTION_NOTIFY_EXIT'));
    expect(service, contains('openAppIntent(REQUEST_EXIT, exitOnOpen = true)'));
    expect(service, contains('PendingIntent.getService'));
    // Two buttons, two request codes: one PendingIntent for both would hand the
    // second button the first one's extras.
    expect(service, contains('REQUEST_STOP'));
    expect(service, contains('REQUEST_EXIT'));
    expect(activity, contains('override fun onNewIntent'));
    expect(activity, contains('removeExtra(EXTRA_EXIT_REQUESTED)'));
    expect(helpers, contains("case 'notificationStop':"));
    expect(helpers, contains("case 'notificationExit':"));
    // A service Android destroyed on its own has to reach Dart, or the app goes
    // on believing a notification is up that nobody can see.
    expect(service, contains('notifyDart("serviceGone")'));
    expect(helpers, contains("case 'serviceGone':"));
    expect(home, contains('onNotificationStop = _stop'));
    // The one exit that never keeps the receiver running: ✕ may close only the
    // screen, this button is what ends the app afterwards.
    expect(home, contains('_exitApp(mayKeepReceiving: false)'));
    expect(home, contains('exitKeepsReceiving('));

    // Closing the screen over a running receiver must leave the Recents card:
    // the app is still there, and the card is how the user gets back to it.
    final String? keeping = RegExp(
      r'if \(exitKeepsReceiving\((.*?)\n      return;',
      dotAll: true,
    ).firstMatch(home)?.group(1);
    expect(keeping, isNotNull, reason: 'the keep-receiving exit changed shape');
    expect(keeping, contains('SystemNavigator.pop()'));
    // The last foreground moment: if Android has taken the service, only here
    // may it be started again.
    expect(keeping, contains('androidService.reassert()'));
    // The call, not the word: the comment above it names the function to say
    // why it is deliberately not used here.
    expect(keeping, isNot(contains('await finishActivityAndTask')));
  });

  // The channel call and the Intent are two hops, and the service reads the
  // Intent. An argument added to the call but not carried across arrives as
  // null, which is exactly how the buttons went missing once: labels were sent
  // from Dart, never put into the Intent, and a label-less button is not drawn.
  test('every argument of the notification call reaches the service', () async {
    final String helpers = await File('lib/android_helpers.dart').readAsString();
    final String application = await File(
      'android/app/src/main/kotlin/a/a/easysend/EasySendApplication.kt',
    ).readAsString();
    final String service = await File(
      'android/app/src/main/kotlin/a/a/easysend/TransferService.kt',
    ).readAsString();

    final RegExp call = RegExp(
      r"invokeMethod\(starting \? 'start' : 'update', \{(.*?)\n      \}\)",
      dotAll: true,
    );
    final String? arguments = call.firstMatch(helpers)?.group(1);
    expect(arguments, isNotNull, reason: 'the notification call changed shape');

    final List<String> keys = RegExp(r"'([A-Za-z]+)':")
        .allMatches(arguments!)
        .map((RegExpMatch m) => m.group(1)!)
        .toList();
    // A guard on the guard: an empty match list would assert nothing at all.
    expect(keys, containsAll(<String>['title', 'stopLabel', 'exitNeedsApp']));

    for (final String key in keys) {
      expect(application, contains('"$key"'), reason: '$key is never put into the Intent');
      expect(service, contains('"$key"'), reason: '$key is never read by the service');
    }
  });
}
