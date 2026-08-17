import 'dart:async';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loaded by `flutter test` for every file in this directory, before that file's
/// own `main()` declares anything. One `setUp` registered here therefore runs
/// before every test in the suite, whatever the file.
///
/// It exists because the app's state is global — the settings map, the device
/// list, the transfer list, the clock — and a test that borrows one of them used
/// to have to remember to put it back. Most did; the ones that did not were
/// harmless by luck, and `xvNow` made the luck worse: a stubbed clock left
/// behind does not fail loudly, it quietly makes another test's device
/// permanently online or permanently stale.
///
/// A file's own `setUp` runs after this one, so anything it arranges still wins.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(resetGlobalsForTest);
  await testMain();
}

/// Everything a test can borrow, back to what a fresh process would hold.
///
/// Deliberately not the data loaded from assets — `loadedThemes`, `langNames`.
/// Those are read once per file in `setUpAll` by the tests that need them, and
/// clearing them before each test would take away what that file just arranged.
void resetGlobalsForTest() {
  xdef = defaultSettings();
  xvDevices = [];
  xvTransfers = [];
  xvNow = DateTime.now;
  xvConfigDir = '';
  xvRecvDir = '';
  xvDeviceId = '';
  xvDeviceName = '';
  xvPlatform = '';
}
