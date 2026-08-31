import 'dart:io';

import 'package:easysend/android_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

// One lock, two owners. What has to hold: either reason alone keeps the screen
// awake, the one that lets go does not take it from the other, and only the
// last of them releases it. The plugin behind it is not here — the toggle
// throws MissingPluginException and is swallowed, which is exactly what happens
// on a platform without a wakelock.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a transfer alone holds the screen', () async {
    final ScreenWake wake = ScreenWake();
    expect(wake.held, isFalse);
    await wake.forTransfer(true);
    expect(wake.held, isTrue);
    await wake.forTransfer(false);
    expect(wake.held, isFalse);
  });

  test('the open app alone holds the screen', () async {
    final ScreenWake wake = ScreenWake();
    await wake.forOpenApp(true);
    expect(wake.held, isTrue);
    await wake.forOpenApp(false);
    expect(wake.held, isFalse);
  });

  test('closing the app does not take the screen from a transfer', () async {
    final ScreenWake wake = ScreenWake();
    await wake.forOpenApp(true);
    await wake.forTransfer(true);

    await wake.forOpenApp(false);

    expect(wake.held, isTrue);
    await wake.forTransfer(false);
    expect(wake.held, isFalse);
  });

  test('a transfer ending does not take the screen from the open app', () async {
    final ScreenWake wake = ScreenWake();
    await wake.forTransfer(true);
    await wake.forOpenApp(true);

    await wake.forTransfer(false);

    expect(wake.held, isTrue);
  });

  // No widget tests in this project (ADD/tofix5.md finding 11, accepted), so
  // the half of the lock the screen owns is pinned by reading the source.
  test('the main screen takes and releases its half of the lock', () async {
    final String home = await File('lib/home_screen.dart').readAsString();
    // Taken at startup outright: the binding may not have been told the
    // lifecycle state yet when this screen is built, and a lock that waits for
    // that message is a lock that may never be taken at all.
    expect(home, contains('_syncScreenWake(resumed: true);'));
    expect(
      home,
      contains('_syncScreenWake(resumed: state == AppLifecycleState.resumed)'),
    );
    // And given up with the screen itself, whatever the setting says.
    expect(home, contains('screenWake.forOpenApp(false)'));
    // The setting is what it asks about, and only while the app is in front.
    expect(home, contains("xdef['Keep the screen on'] == 'true'"));
  });
}
