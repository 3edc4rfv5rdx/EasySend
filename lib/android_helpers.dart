import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'globals.dart';

const MethodChannel _serviceChannel = MethodChannel('easysend/service');

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
}) async {
  final Completer<bool> completer = Completer<bool>();
  _askCompleter = completer;

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

// Mirrors transfer state into the Android foreground service, so a backgrounded
// or screen-off device keeps transferring (SPEC 7).
class AndroidService {
  bool _serviceUp = false;
  bool _screenHeld = false;
  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);
  String _lastText = '';

  void attach() {
    if (!Platform.isAndroid) return;
    transfersTick.addListener(sync);
    sync();
  }

  void detach() {
    if (!Platform.isAndroid) return;
    transfersTick.removeListener(sync);
  }

  Future<void> sync() async {
    if (!Platform.isAndroid) return;

    TransferSession? active;
    for (final TransferSession t in xvTransfers) {
      if (t.isRunning) {
        active = t;
        break;
      }
    }

    if (active != null) {
      await _keepScreenOn(true);
      final int percent = (active.progress * 100).round();
      final String title = active.incoming ? lw('Receiving') : lw('Sending');
      final String text = '${active.peerName} — $percent%';
      await _push(
        title: title,
        text: text,
        progress: percent,
        starting: !_serviceUp,
      );
      return;
    }

    await _keepScreenOn(false);

    // No transfer: keep listening only if the user asked for it.
    if (xdef['Receive in background'] == 'true') {
      await _push(
        title: 'EasySend',
        text: lw('Ready to receive'),
        progress: -1,
        starting: !_serviceUp,
      );
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
  }) async {
    final DateTime now = DateTime.now();
    if (!starting && text == _lastText) return;
    if (!starting && now.difference(_lastPush).inMilliseconds < 1000) return;
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
    }
  }

  Future<void> _stop() async {
    if (!_serviceUp) return;
    _serviceUp = false;
    _lastText = '';
    try {
      await _serviceChannel.invokeMethod('stop');
    } on PlatformException catch (e) {
      myPrint('stopping service failed: ${e.message}');
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
