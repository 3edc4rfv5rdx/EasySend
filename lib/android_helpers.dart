import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'globals.dart';

const MethodChannel _serviceChannel = MethodChannel('easysend/service');

class AndroidServiceStateTick extends ChangeNotifier {
  void changed() => notifyListeners();
}

final AndroidServiceStateTick androidServiceStateTick =
    AndroidServiceStateTick();

final FlutterLocalNotificationsPlugin _notifications =
    FlutterLocalNotificationsPlugin();

const String _askChannelId = 'easysend_ask';
const String _doneChannelId = 'easysend_done';
// Public because a launch has to be able to say which of the two it clears, and
// a test has to be able to check that it cleared that one.
const int askNotificationId = 100;
const int doneNotificationId = 101;
const String _acceptAction = 'accept';
const String _declineAction = 'decline';

// Answer to the accept prompt currently shown as a notification.
Completer<bool>? _askCompleter;

Future<void> initNotifications({
  bool? android,
  Future<void> Function()? initialize,
  Future<void> Function(int id)? cancel,
}) async {
  if (!(android ?? Platform.isAndroid)) return;
  await (initialize?.call() ??
      _notifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
        onDidReceiveNotificationResponse: _onNotificationResponse,
      ));
  // A consent question is answered by a completer that lives in this process, so
  // one left on the shade by a process Android killed mid-question answers
  // nothing at all: its buttons reach _onNotificationResponse, find no completer
  // and return, while the notification goes on saying files are waiting. It is
  // posted `ongoing`, so nothing sweeps it away either. Cleared here, before the
  // first screen can be drawn over it.
  //
  // Only that one. The finished-transfer notification is a record of something
  // that did happen, and the foreground service's own notification belongs to
  // the Kotlin side.
  try {
    await (cancel?.call(askNotificationId) ??
        _notifications.cancel(askNotificationId));
  } catch (e) {
    myPrint('cannot clear a leftover consent notification: $e');
  }
}

void _onNotificationResponse(NotificationResponse response) {
  final Completer<bool>? completer = _askCompleter;
  if (completer == null || completer.isCompleted) return;
  // Tapping the notification body opens the app and leaves the question open;
  // only the two buttons answer it.
  switch (response.actionId) {
    case _acceptAction:
      completer.complete(true);
    case _declineAction:
      completer.complete(false);
  }
}

bool get appInForeground =>
    WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

// The choice comes back as its own call rather than as the answer to the
// request, because the Activity that opened the picker is often destroyed while
// the user is still choosing — see MainActivity.pickFiles. Only the engine is
// certain to still be here, so the waiting completer lives with it.
Completer<List<String>>? _pickCompleter;

/// Picked paths, empty when the user backed out, null when nothing opened.
Future<List<String>?> pickFilesFromActivity() async {
  if (!Platform.isAndroid) return null;
  // A pick that is still waiting is answered as cancelled: whatever arrives
  // from now on belongs to this newer request.
  _completePick(const []);
  final Completer<List<String>> completer = Completer<List<String>>();
  _pickCompleter = completer;
  try {
    final bool opened =
        await _serviceChannel.invokeMethod<bool>('pickFiles') ?? false;
    if (!opened) {
      _pickCompleter = null;
      return null;
    }
  } on PlatformException catch (e) {
    myPrint('opening the file picker failed: ${e.message}');
    _pickCompleter = null;
    return null;
  } on MissingPluginException catch (e) {
    myPrint('the file picker is unavailable: ${e.message}');
    _pickCompleter = null;
    return null;
  }
  return completer.future;
}

/// Closes the screen and takes its Recents entry with it.
///
/// False when there is no Activity to close or the call did not arrive, and the
/// caller then falls back to `SystemNavigator.pop()`, which ends the screen but
/// leaves the task listed.
Future<bool> finishActivityAndTask({bool? android}) async {
  if (!(android ?? Platform.isAndroid)) return false;
  try {
    return await _serviceChannel.invokeMethod<bool>('exitApp') ?? false;
  } on PlatformException catch (e) {
    myPrint('closing the task failed: ${e.message}');
    return false;
  } on MissingPluginException catch (e) {
    myPrint('closing the task is unavailable: ${e.message}');
    return false;
  }
}

void _completePick(List<String> paths) {
  final Completer<List<String>>? completer = _pickCompleter;
  _pickCompleter = null;
  if (completer != null && !completer.isCompleted) completer.complete(paths);
}

// With the app off screen there is no one to show a dialog to, so the question
// goes out as a notification with two buttons (SPEC 7).
Future<bool> askAcceptViaNotification({
  required String senderName,
  required int fileCount,
  required int totalBytes,
  Future<void>? cancelled,
  Future<bool> Function()? permissionCheck,
  Future<void> Function()? showNotification,
}) async {
  final bool permitted =
      await (permissionCheck?.call() ?? notificationPermissionGranted());
  if (!permitted) {
    myPrint('notification consent refused: permission is not granted');
    return false;
  }

  final Completer<bool> completer = Completer<bool>();
  _askCompleter = completer;
  // The receiver withdrawing the question counts as no, and takes the buttons
  // off the lock screen with it.
  cancelled?.then((_) {
    if (!completer.isCompleted) completer.complete(false);
  });

  try {
    if (showNotification != null) {
      await showNotification();
    } else {
      await _notifications.show(
        askNotificationId,
        lw('Incoming files'),
        '$senderName — $fileCount, ${formatBytes(totalBytes)}',
        NotificationDetails(
          android: AndroidNotificationDetails(
            _askChannelId,
            'Incoming requests',
            channelDescription: 'Asks whether to accept incoming files',
            importance: Importance.high,
            priority: Priority.high,
            ongoing: true,
            actions: <AndroidNotificationAction>[
              // The pending receive session and its completer live on the main
              // isolate. Opening the UI makes the plugin deliver both actions
              // to onDidReceiveNotificationResponse instead of a background
              // engine.
              AndroidNotificationAction(
                _declineAction,
                lw('Decline'),
                showsUserInterface: true,
              ),
              AndroidNotificationAction(
                _acceptAction,
                lw('Accept'),
                showsUserInterface: true,
              ),
            ],
          ),
        ),
      );
    }
  } catch (e) {
    _askCompleter = null;
    myPrint('notification consent failed: $e');
    return false;
  }

  // Same deadline as the dialog: an unanswered request must not hold the sender.
  final bool accepted = await completer.future.timeout(
    const Duration(seconds: acceptTimeoutSec),
    onTimeout: () => false,
  );
  _askCompleter = null;
  try {
    await _notifications.cancel(askNotificationId);
  } catch (e) {
    myPrint('notification consent cleanup failed: $e');
  }
  return accepted;
}

Future<void> notifyTransferFinished(String text) async {
  if (!Platform.isAndroid || appInForeground) return;
  await _notifications.show(
    doneNotificationId,
    'EasySend',
    text,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _doneChannelId,
        'Finished transfers',
        channelDescription: 'Tells you a transfer is over',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      ),
    ),
  );
}

// Received files go to the shared Download folder so any file manager can reach
// them. Since Android 11 that means all-files access; the alternative, SAF,
// would take away the plain File API the receiver is built on.
Future<bool> ensureStoragePermission() async {
  if (!Platform.isAndroid) return true;
  if (await Permission.manageExternalStorage.isGranted) return true;

  PermissionStatus status = await Permission.manageExternalStorage.request();
  if (status.isGranted) return true;

  // Before scoped storage the plain write permission was enough.
  status = await Permission.storage.request();
  return status.isGranted;
}

Future<bool> notificationPermissionGranted({
  bool? android,
  Future<PermissionStatus> Function()? status,
}) async {
  if (!(android ?? Platform.isAndroid)) return true;
  try {
    return (await (status?.call() ?? Permission.notification.status)).isGranted;
  } catch (e) {
    myPrint('notification permission check failed: $e');
    return false;
  }
}

Future<bool> ensureNotificationPermission({
  bool? android,
  Future<PermissionStatus> Function()? status,
  Future<PermissionStatus> Function()? request,
}) async {
  if (!(android ?? Platform.isAndroid)) return true;
  if (await notificationPermissionGranted(android: true, status: status)) {
    return true;
  }
  try {
    return (await (request?.call() ?? Permission.notification.request()))
        .isGranted;
  } catch (e) {
    myPrint('notification permission request failed: $e');
    return false;
  }
}

// Whether Android has been told to leave this app alone when it dozes.
//
// Background receiving is only as good as this: without the exemption Doze cuts
// the network of a backgrounded app on a long idle, which is exactly the wait a
// receiver spends. Asked rather than assumed, so an app that is already exempt
// is not nagged about it every time the switch goes on.
Future<bool> batteryExemptionGranted({
  bool? android,
  Future<PermissionStatus> Function()? status,
}) async {
  if (!(android ?? Platform.isAndroid)) return true;
  try {
    return (await (status?.call() ??
            Permission.ignoreBatteryOptimizations.status))
        .isGranted;
  } catch (e) {
    myPrint('battery exemption check failed: $e');
    return false;
  }
}

// Ask for it, once, at the moment it starts to matter. The request opens the
// system's own dialog for this one app — one tap — rather than the list of
// every installed app, where the user would have to find EasySend by hand.
Future<bool> ensureBatteryExemption({
  bool? android,
  Future<PermissionStatus> Function()? status,
  Future<PermissionStatus> Function()? request,
}) async {
  if (!(android ?? Platform.isAndroid)) return true;
  if (await batteryExemptionGranted(android: true, status: status)) return true;
  try {
    return (await (request?.call() ??
            Permission.ignoreBatteryOptimizations.request()))
        .isGranted;
  } catch (e) {
    myPrint('battery exemption request failed: $e');
    return false;
  }
}

Future<void> setDiscoveryMulticastEnabled(bool enabled) async {
  if (!Platform.isAndroid) return;
  try {
    await _serviceChannel.invokeMethod<void>(
      enabled ? 'acquireMulticast' : 'releaseMulticast',
    );
  } on PlatformException catch (e) {
    myPrint('multicast lock failed: ${e.message}');
  }
}

// Mirrors transfer state into the Android foreground service, so a backgrounded
// or screen-off device keeps transferring (SPEC 7).
class AndroidService {
  // Nothing here is Android-specific on the Dart side — it is one method
  // channel — so a test can say it is on Android and drive the whole state
  // machine against a mocked channel.
  final bool android;
  bool _serviceUp = false;
  bool _screenHeld = false;
  bool _attached = false;
  bool _transferMode = false;
  bool _dataSyncTimedOut = false;
  final SerialQueue _syncQueue = SerialQueue('service sync');
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastText = '';

  AndroidService({bool? android}) : android = android ?? Platform.isAndroid;

  bool get attached => _attached;
  bool get backgroundReady => !_dataSyncTimedOut;

  /// Pressed "Stop" on the notification: end the transfer, keep receiving.
  Future<void> Function()? onNotificationStop;

  /// Pressed "Exit" on the notification: leave the app exactly as ✕ does.
  Future<void> Function()? onNotificationExit;

  void attach() {
    if (_attached) return;
    _attached = true;
    if (!android) return;
    _serviceChannel.setMethodCallHandler(_handleNativeCall);
    transfersTick.addListener(sync);
    unawaited(_restoreTimeoutAndSync());
  }

  void detach() {
    if (!_attached) return;
    _attached = false;
    if (!android) return;
    transfersTick.removeListener(sync);
    _serviceChannel.setMethodCallHandler(null);
  }

  Future<void> _restoreTimeoutAndSync() async {
    try {
      final bool timedOut =
          await _serviceChannel.invokeMethod<bool>('takeServiceTimeout') ??
          false;
      if (timedOut) await noteServiceTimeout();
    } on PlatformException catch (e) {
      myPrint('foreground service status failed: ${e.message}');
    } on MissingPluginException catch (e) {
      myPrint('foreground service status unavailable: ${e.message}');
    }
    await sync();
  }

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'serviceTimeout':
        await noteServiceTimeout();
      case 'filesPicked':
        _completePick(
          (call.arguments as List<Object?>? ?? const <Object?>[])
              .whereType<String>()
              .toList(),
        );
      // The buttons on the ongoing notification. Answered by the screen that
      // owns the transfers and the exit, not here.
      case 'serviceGone':
        noteServiceGone();
      case 'notificationStop':
        await onNotificationStop?.call();
      case 'notificationExit':
        await onNotificationExit?.call();
      default:
        throw MissingPluginException(
          'Unknown native service call: ${call.method}',
        );
    }
  }

  Future<void> noteServiceTimeout() async {
    if (_dataSyncTimedOut) return;
    _dataSyncTimedOut = true;
    _serviceUp = false;
    _transferMode = false;
    _lastText = '';
    await _keepScreenOn(false);
    final String message = lw(
      'Background receiving is unavailable',
    );
    myPrint(message);
    okInfoBarOrange(message);
    androidServiceStateTick.changed();
  }

  Future<void> sync() => _syncQueue.add(_syncNow);

  /// Posts the notification again as though the service were not up.
  ///
  /// Dart never sees the service die: Android takes it with a removed task or a
  /// low-memory kill without telling anyone, `_serviceUp` stays true, and the
  /// idle text never changes, so the rate limit in `_push` refuses to post it
  /// again. The receiver then runs with nothing on screen to say so. Call this
  /// while the app is still in the foreground, where starting a foreground
  /// service is allowed.
  Future<void> reassert() {
    _serviceUp = false;
    _lastText = '';
    return sync();
  }

  /// Android destroyed the service, whoever asked for it.
  ///
  /// Nothing is restarted here: from the background that is not allowed, and
  /// the stop may well be our own. Recording the truth is enough — the next
  /// reassert from the foreground puts it back.
  void noteServiceGone() {
    _serviceUp = false;
    _transferMode = false;
    _lastText = '';
  }

  // Leaving the app has to take the service with it. The engine outlives the
  // Activity now, so `SystemNavigator.pop()` ends the screen and nothing else
  // ever stops the service: its "Ready to receive" notification would go on
  // promising a receiver whose sockets the exit has already closed.
  Future<void> stopService() => _syncQueue.add(_stop);

  Future<void> _syncNow() async {
    if (!android) return;

    TransferSession? active;
    for (final TransferSession t in xvTransfers) {
      if (t.isRunning) {
        active = t;
        break;
      }
    }

    if (active != null) {
      // Starting another dataSync service while its rolling quota is exhausted
      // throws. The quota resets when the app returns to the foreground; until
      // then the transfer may continue without falsely restoring the service.
      if (_dataSyncTimedOut && !appInForeground) {
        await _keepScreenOn(false);
        return;
      }
      final bool enteringTransfer = !_transferMode;
      await _keepScreenOn(true);
      final int percent = (active.progress * 100).round();
      final String title = active.incoming ? lw('Receiving') : lw('Sending');
      final String text = '${active.peerName} — $percent%';
      await _push(
        title: title,
        text: text,
        progress: percent,
        starting: !_serviceUp,
        force: enteringTransfer,
      );
      // On evidence, and only on evidence — the same rule the idle branch below
      // follows. _push swallows a refusal from Android, so clearing this before
      // it left background readiness claiming to be back with no service behind
      // it, and ✕ then closed the screen promising a receiver that nothing was
      // holding up.
      if (_serviceUp) _dataSyncTimedOut = false;
      _transferMode = true;
      return;
    }

    await _keepScreenOn(false);

    // No transfer: keep listening only if the user asked for it.
    if (xdef['Receive in background'] == 'true') {
      if (!await notificationPermissionGranted()) {
        await _stop();
        return;
      }
      final bool leavingTransfer = _transferMode;
      await _push(
        title: 'EasySend',
        text: lw('Ready to receive'),
        progress: -1,
        starting: !_serviceUp,
        force: leavingTransfer,
      );
      // specialUse has no dataSync quota. Once the idle listener is really up,
      // background readiness has recovered without changing the user's switch.
      if (_serviceUp) _dataSyncTimedOut = false;
      _transferMode = false;
    } else {
      await _stop();
    }
  }

  // The notification is rate-limited: progress ticks ten times a second and
  // Android throttles callers that post that often.
  Future<void> _push({
    required String title,
    required String text,
    required int progress,
    required bool starting,
    bool force = false,
  }) async {
    final DateTime now = DateTime.now();
    if (!force && !starting && text == _lastText) return;
    // Rebuilt with every post rather than cached: the labels follow the
    // interface language, and whether Exit can act from the shade follows both
    // the running transfer and the confirmation setting.
    if (!force &&
        !starting &&
        now.difference(_lastPush).inMilliseconds < 1000) {
      return;
    }
    _lastPush = now;
    _lastText = text;

    try {
      await _serviceChannel.invokeMethod(starting ? 'start' : 'update', {
        'title': title,
        'text': text,
        'progress': progress,
        'stopLabel': lw('Stop'),
        'exitLabel': lw('Exit'),
        'exitNeedsApp': exitNeedsConfirmation(
          transferRunning: progress >= 0,
          askBeforeExit: xdef['Ask before exit'] == 'true',
        ),
      });
      _serviceUp = true;
    } on PlatformException catch (e) {
      myPrint('foreground service failed: ${e.message}');
    } on MissingPluginException catch (e) {
      // The engine is being torn down, or the channel is not wired yet. Leaving
      // _serviceUp false makes the next call start the service rather than
      // update one that is not there.
      myPrint('foreground service unavailable: ${e.message}');
    }
  }

  Future<void> _stop() async {
    if (!_serviceUp) return;
    _serviceUp = false;
    _transferMode = false;
    _lastText = '';
    try {
      await _serviceChannel.invokeMethod('stop');
    } on PlatformException catch (e) {
      myPrint('stopping service failed: ${e.message}');
    } on MissingPluginException catch (e) {
      myPrint('stopping service unavailable: ${e.message}');
    }
  }

  // The lock screen timeout must not fire in the middle of a transfer.
  Future<void> _keepScreenOn(bool on) async {
    if (_screenHeld == on) return;
    _screenHeld = on;
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      myPrint('wakelock failed: $e');
    }
  }
}

final AndroidService androidService = AndroidService();
