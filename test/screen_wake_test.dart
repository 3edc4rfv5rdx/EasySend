import 'dart:io';

import 'package:easysend/android_helpers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// One lock, three owners. What has to hold: any reason alone keeps the screen
// awake, the one that lets go does not take it from the others, and only the
// last of them releases it. There is no plugin behind it here — an absent one
// answers with a channel-error, which the class reads as a lock that did not
// move — so the tests about the rule hand it a toggle that works, and the two
// about a refusal hand it one that does not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // A lock that does what it is told, so these tests are about the rule and not
  // about what an absent plugin happens to throw.
  ScreenWake working() =>
      ScreenWake()..toggle = ({required bool enable}) async {};

  test('a transfer alone holds the screen', () async {
    final ScreenWake wake = working();
    expect(wake.held, isFalse);
    await wake.forTransfer(true);
    expect(wake.held, isTrue);
    await wake.forTransfer(false);
    expect(wake.held, isFalse);
  });

  test('the open app alone holds the screen', () async {
    final ScreenWake wake = working();
    await wake.forOpenApp(true);
    expect(wake.held, isTrue);
    await wake.forOpenApp(false);
    expect(wake.held, isFalse);
  });

  // The share dialog serves a browser while it stands open, and a screen going
  // dark backgrounds the app: with background receiving off that takes the
  // listener down mid-download.
  test('the share dialog alone holds the screen', () async {
    final ScreenWake wake = working();
    await wake.forWebShare(true);
    expect(wake.held, isTrue);
    await wake.forWebShare(false);
    expect(wake.held, isFalse);
  });

  test('closing the share dialog does not take it from a transfer', () async {
    final ScreenWake wake = working();
    await wake.forWebShare(true);
    await wake.forTransfer(true);

    await wake.forWebShare(false);

    expect(wake.held, isTrue);
    await wake.forTransfer(false);
    expect(wake.held, isFalse);
  });

  test('closing the app does not take the screen from a transfer', () async {
    final ScreenWake wake = working();
    await wake.forOpenApp(true);
    await wake.forTransfer(true);

    await wake.forOpenApp(false);

    expect(wake.held, isTrue);
    await wake.forTransfer(false);
    expect(wake.held, isFalse);
  });

  test(
    'a transfer ending does not take the screen from the open app',
    () async {
      final ScreenWake wake = working();
      await wake.forTransfer(true);
      await wake.forOpenApp(true);

      await wake.forTransfer(false);

      expect(wake.held, isTrue);
    },
  );

  // The fuse: the setting says not to let the screen sleep while the app is
  // open, and an app left open all night would mean exactly that. Blowing it
  // does not darken anything — it hands the decision back to Android's own
  // inactivity timeout, which a finger on the screen resets.
  test('the open app gives the screen back when the fuse blows', () async {
    final ScreenWake wake = working()
      ..openAppLimit = const Duration(milliseconds: 20);
    await wake.forOpenApp(true);
    expect(wake.held, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(wake.held, isFalse);
  });

  test('the fuse does not take the screen from a transfer', () async {
    final ScreenWake wake = working()
      ..openAppLimit = const Duration(milliseconds: 20);
    await wake.forOpenApp(true);
    await wake.forTransfer(true);

    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(wake.held, isTrue);
    await wake.forTransfer(false);
    expect(wake.held, isFalse);
  });

  // Coming back to the app asks for the lock again, and that is the re-arming.
  test('returning to the app arms the fuse anew', () async {
    final ScreenWake wake = working()
      ..openAppLimit = const Duration(milliseconds: 20);
    await wake.forOpenApp(true);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(wake.held, isFalse);

    await wake.forOpenApp(true);
    expect(wake.held, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(wake.held, isFalse);
  });

  // A fuse left burning after the lock was given up would fire into a state
  // nobody is in any more.
  test('letting the screen go puts the fuse out with it', () async {
    final ScreenWake wake = ScreenWake()
      ..openAppLimit = const Duration(milliseconds: 20);
    final List<bool> asked = [];
    wake.toggle = ({required bool enable}) async => asked.add(enable);

    await wake.forOpenApp(true);
    await wake.forOpenApp(false);
    await Future<void>.delayed(const Duration(milliseconds: 60));

    expect(asked, [true, false]);
  });

  // A platform that has a lock and refuses to move it is not a platform that
  // has none. Remembering the state that was asked for would answer every later
  // call from a cache that was never true, and nothing would try again.
  test(
    'a refused lock is not remembered, and the next call tries again',
    () async {
      final ScreenWake wake = ScreenWake();
      final List<bool> asked = [];
      wake.toggle = ({required bool enable}) async {
        asked.add(enable);
        throw PlatformException(code: 'no', message: 'refused');
      };

      await wake.forTransfer(true);
      expect(wake.held, isFalse);
      expect(asked, [true]);

      // The same request again reaches the platform instead of being answered
      // from the state the first one failed to reach.
      await wake.forTransfer(true);
      expect(asked, [true, true]);

      // And once it works, the state is what actually happened.
      wake.toggle = ({required bool enable}) async => asked.add(enable);
      await wake.forTransfer(true);
      expect(wake.held, isTrue);
      expect(asked, [true, true, true]);
    },
  );

  // Two owners changing their minds in the same turn: the work reads what is
  // wanted when it runs, so the last word decides and neither call is answered
  // from a state the other had not reached yet.
  test('the last word decides when both owners speak at once', () async {
    final ScreenWake wake = ScreenWake();
    final List<bool> asked = [];
    wake.toggle = ({required bool enable}) async => asked.add(enable);

    final Future<void> first = wake.forOpenApp(true);
    final Future<void> second = wake.forOpenApp(false);
    await Future.wait([first, second]);

    expect(wake.held, isFalse);
    // Nobody wanted it by the time either of them ran, so it was never taken.
    expect(asked, isEmpty);
  });

  // Nothing builds HomeScreen in a test (ADD/tofix5.md finding 11, accepted),
  // so the half of the lock the screen owns is pinned by reading the source.
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
