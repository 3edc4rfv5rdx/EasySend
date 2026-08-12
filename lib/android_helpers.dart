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
const int _askNotificationId = 100;
const int _doneNotificationId = 101;
const String _acceptAction = 'accept';
const String _declineAction = 'decline';

// Answer to the accept prompt currently shown as a notification.
Completer<bool>? _askCompleter;

Future<void> initNotifications() async {
  if (!Platform.isAndroid) return;
  await _notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: _onNotificationResponse,
  );
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

// With the app off screen there is no one to show a dialog to, so the question
// goes out as a notification with two buttons (SPEC 7).
Future<bool> askAcceptViaNotification({
  required String senderName,
  required int fileCount,
  required int totalBytes,
  Future<void>? cancelled,
}) async {
  final Completer<bool> completer = Completer<bool>();
  _askCompleter = completer;
  // The receiver withdrawing the question counts as no, and takes the buttons
  // off the lock screen with it.
  cancelled?.then((_) {
    if (!completer.isCompleted) completer.complete(false);
  });

  await _notifications.show(
    _askNotificationId,
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
          // isolate. Opening the UI makes the plugin deliver both actions to
          // onDidReceiveNotificationResponse instead of a background engine.
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

  // Same deadline as the dialog: an unanswered request must not hold the sender.
  final bool accepted = await completer.future.timeout(
    const Duration(seconds: acceptTimeoutSec),
    onTimeout: () => false,
  );
  _askCompleter = null;
  await _notifications.cancel(_askNotificationId);
  return accepted;
}

Future<void> notifyTransferFinished(String text) async {
  if (!Platform.isAndroid || appInForeground) return;
  await _notifications.show(
    _doneNotificationId,
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

Future<void> ensureNotificationPermission() async {
  if (!Platform.isAndroid) return;
  if (await Permission.notification.isGranted) return;
  await Permission.notification.request();
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
    if (call.method != 'serviceTimeout') {
      throw MissingPluginException(
        'Unknown native service call: ${call.method}',
      );
    }
    await noteServiceTimeout();
  }

  Future<void> noteServiceTimeout() async {
    if (_dataSyncTimedOut) return;
    _dataSyncTimedOut = true;
    _serviceUp = false;
    _transferMode = false;
    _lastText = '';
    await _keepScreenOn(false);
    final String message = lw(
      'Background receiving is temporarily unavailable',
    );
    myPrint(message);
    okInfoBarOrange(message);
    androidServiceStateTick.changed();
  }

  Future<void> sync() => _syncQueue.add(_syncNow);

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
      _dataSyncTimedOut = false;
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
      _transferMode = true;
      return;
    }

    await _keepScreenOn(false);

    // No transfer: keep listening only if the user asked for it.
    if (xdef['Receive in background'] == 'true') {
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
