import 'package:easysend/android_helpers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('granted notification capability needs no second request', () async {
    int requests = 0;
    final bool granted = await ensureNotificationPermission(
      android: true,
      status: () async => PermissionStatus.granted,
      request: () async {
        requests++;
        return PermissionStatus.denied;
      },
    );

    expect(granted, isTrue);
    expect(requests, 0);
  });

  test('a granted permission request enables the capability', () async {
    final bool granted = await ensureNotificationPermission(
      android: true,
      status: () async => PermissionStatus.denied,
      request: () async => PermissionStatus.granted,
    );

    expect(granted, isTrue);
  });

  for (final PermissionStatus refusal in <PermissionStatus>[
    PermissionStatus.denied,
    PermissionStatus.permanentlyDenied,
    PermissionStatus.restricted,
  ]) {
    test('$refusal cannot enable background receiving', () async {
      final bool granted = await ensureNotificationPermission(
        android: true,
        status: () async => refusal,
        request: () async => refusal,
      );

      expect(granted, isFalse);
    });
  }

  test(
    'missing permission declines consent without showing anything',
    () async {
      bool shown = false;
      final bool accepted = await askAcceptViaNotification(
        senderName: 'Unknown',
        fileCount: 1,
        totalBytes: 1,
        permissionCheck: () async => false,
        showNotification: () async {
          shown = true;
        },
      );

      expect(accepted, isFalse);
      expect(shown, isFalse);
    },
  );

  test('notification failure declines consent instead of throwing', () async {
    final bool accepted = await askAcceptViaNotification(
      senderName: 'Unknown',
      fileCount: 1,
      totalBytes: 1,
      permissionCheck: () async => true,
      showNotification: () async => throw PlatformException(code: 'denied'),
    );

    expect(accepted, isFalse);
  });
}
