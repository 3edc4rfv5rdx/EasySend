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

  // Doze cuts a background receiver's network on a long idle, so the exemption
  // is asked for when the switch goes on — and only then, and only once.
  group('the battery exemption is asked for, not described', () {
    test('an app that is already exempt is not asked', () async {
      int requests = 0;
      final bool exempt = await ensureBatteryExemption(
        android: true,
        status: () async => PermissionStatus.granted,
        request: () async {
          requests++;
          return PermissionStatus.denied;
        },
      );

      expect(exempt, isTrue);
      expect(requests, 0);
    });

    test('one that is not gets the system dialog', () async {
      final bool exempt = await ensureBatteryExemption(
        android: true,
        status: () async => PermissionStatus.denied,
        request: () async => PermissionStatus.granted,
      );

      expect(exempt, isTrue);
    });

    test('a refusal is answered, not thrown', () async {
      expect(
        await ensureBatteryExemption(
          android: true,
          status: () async => PermissionStatus.denied,
          request: () async => PermissionStatus.permanentlyDenied,
        ),
        isFalse,
      );
      // A platform that cannot answer at all is a refusal too, never a crash
      // on the way into the settings screen.
      expect(
        await ensureBatteryExemption(
          android: true,
          status: () async => throw PlatformException(code: 'unavailable'),
          request: () async => throw PlatformException(code: 'unavailable'),
        ),
        isFalse,
      );
    });

    test('off Android there is nothing to ask', () async {
      int asked = 0;
      final bool exempt = await ensureBatteryExemption(
        android: false,
        status: () async {
          asked++;
          return PermissionStatus.denied;
        },
      );

      expect(exempt, isTrue);
      expect(asked, 0);
    });
  });

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

  // The question is answered by a completer that dies with the process, so a
  // notification a killed process left behind has nothing to answer: its buttons
  // do nothing at all while it goes on saying files are waiting.
  group('a launch clears a consent question nobody is waiting on', () {
    test('the ask notification goes, the finished one stays', () async {
      final List<String> steps = [];
      final List<int> cancelled = [];

      await initNotifications(
        android: true,
        initialize: () async => steps.add('init'),
        cancel: (int id) async {
          steps.add('cancel');
          cancelled.add(id);
        },
      );

      // Cleared after the plugin is up, or there would be nothing to clear it
      // with.
      expect(steps, ['init', 'cancel']);
      expect(cancelled, [askNotificationId]);
      expect(cancelled, isNot(contains(doneNotificationId)));
    });

    test('a clearing that fails does not fail the launch', () async {
      await initNotifications(
        android: true,
        initialize: () async {},
        cancel: (int id) async => throw PlatformException(code: 'no-plugin'),
      );
    });

    test('off Android there is nothing to clear', () async {
      final List<int> cancelled = [];
      await initNotifications(
        android: false,
        initialize: () async => throw StateError('must not initialize'),
        cancel: (int id) async => cancelled.add(id),
      );
      expect(cancelled, isEmpty);
    });
  });
}
