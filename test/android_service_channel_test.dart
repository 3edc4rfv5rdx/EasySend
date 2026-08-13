import 'package:easysend/android_helpers.dart';
import 'package:easysend/globals.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('easysend/service');
  final List<String> calls = [];
  final List<MethodCall> invocations = [];
  Object? failWith;

  setUp(() {
    calls.clear();
    invocations.clear();
    failWith = null;
    xvTransfers = [];
    xdef['Program language'] = 'en';
    xdef['Receive in background'] = 'true';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
          invocations.add(call);
          final Object? failure = failWith;
          if (failure != null) throw failure;
          return true;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('a refused start leaves the service known to be down', () async {
    final AndroidService service = AndroidService(android: true);

    // What Android answers when it will not let the service start.
    failWith = PlatformException(code: 'ForegroundServiceStartNotAllowed');
    await service.sync();
    expect(calls, ['start']);

    // The next attempt starts it again rather than updating one that is not
    // there — a failed call must not be remembered as a running service.
    failWith = null;
    await service.sync();
    expect(calls, ['start', 'start']);
  });

  test('a channel that is not there is survived too', () async {
    final AndroidService service = AndroidService(android: true);

    failWith = MissingPluginException('no implementation');
    await service.sync();
    expect(calls, ['start']);

    failWith = null;
    await service.sync();
    expect(calls, ['start', 'start']);
  });

  test('an update follows a start that worked', () async {
    final AndroidService service = AndroidService(android: true);
    await service.sync();
    expect(calls, ['start']);

    // A transfer appearing forces a push past the rate limit.
    xvTransfers = [
      TransferSession(
        id: 'x',
        incoming: true,
        peerName: 'Peer',
        files: [FileItem(id: 'f', relativePath: 'f.bin', size: 1)],
      )..status = TransferStatus.active,
    ];
    await service.sync();
    expect(calls, ['start', 'update']);
  });

  test('a timeout preserves intent and idle specialUse can recover', () async {
    final AndroidService service = AndroidService(android: true);

    await service.noteServiceTimeout();
    expect(service.backgroundReady, isFalse);
    expect(xdef['Receive in background'], 'true');

    // With no data transfer running, Android can immediately use the unbounded
    // specialUse listener instead of retrying the exhausted dataSync type.
    await service.sync();
    expect(calls, ['start']);
    expect(service.backgroundReady, isTrue);
    expect(xdef['Receive in background'], 'true');
  });

  group('the ongoing notification carries its buttons', () {
    Map<Object?, Object?> lastArguments() =>
        invocations.last.arguments as Map<Object?, Object?>;

    test('an idle listener offers a localized exit that acts by itself', () async {
      xdef['Ask before exit'] = 'false';
      await AndroidService(android: true).sync();

      expect(lastArguments()['stopLabel'], lw('Stop'));
      expect(lastArguments()['exitLabel'], lw('Exit'));
      // Nothing to ask, so the button does not have to open the app first.
      expect(lastArguments()['exitNeedsApp'], isFalse);
    });

    test('a running transfer makes the exit go through the app', () async {
      xvTransfers = [
        TransferSession(
          id: 'x',
          incoming: true,
          peerName: 'Peer',
          files: [FileItem(id: 'f', relativePath: 'f.bin', size: 1)],
        )..status = TransferStatus.active,
      ];
      xdef['Ask before exit'] = 'false';
      await AndroidService(android: true).sync();

      // A transfer is always worth a question, and a question needs a screen.
      expect(lastArguments()['exitNeedsApp'], isTrue);
    });

    test('asking before exit makes an idle exit go through the app too', () async {
      xdef['Ask before exit'] = 'true';
      await AndroidService(android: true).sync();

      expect(lastArguments()['exitNeedsApp'], isTrue);
    });

    test('the labels follow the interface language', () async {
      xdef['Program language'] = 'ru';
      addTearDown(() => xdef['Program language'] = 'en');
      await AndroidService(android: true).sync();

      expect(lastArguments()['stopLabel'], lw('Stop'));
      expect(lastArguments()['exitLabel'], lw('Exit'));
      expect(lastArguments()['stopLabel'], isNot('Stop'));
    });
  });

  group('a press on a notification button reaches the screen', () {
    Future<void> press(String method) async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'easysend/service',
            const StandardMethodCodec().encodeMethodCall(MethodCall(method)),
            (_) {},
          );
    }

    test('stop and exit each reach their own handler', () async {
      final AndroidService service = AndroidService(android: true);
      int stops = 0;
      int exits = 0;
      service.onNotificationStop = () async => stops++;
      service.onNotificationExit = () async => exits++;
      service.attach();
      addTearDown(service.detach);

      await press('notificationStop');
      expect([stops, exits], [1, 0]);

      await press('notificationExit');
      expect([stops, exits], [1, 1]);
    });

    // The screen is gone but the process and its notification are not, and a
    // press must not bring the engine down with an unhandled exception.
    test('a press with no screen listening is survived', () async {
      final AndroidService service = AndroidService(android: true);
      service.attach();
      addTearDown(service.detach);

      await press('notificationStop');
      await press('notificationExit');
      // The service reporting its own death arrives on the same channel.
      await press('serviceGone');
    });
  });

  group('a service Android took away is put back', () {
    test('an identical idle notification is posted again on reassert', () async {
      final AndroidService service = AndroidService(android: true);

      await service.sync();
      expect(calls, ['start']);

      // The rate limit refuses this: the idle text never changes.
      await service.sync();
      expect(calls, ['start']);

      // Leaving the screen, or coming back to it, has to post it regardless —
      // the service may be gone without Dart having been told.
      await service.reassert();
      expect(calls, ['start', 'start']);
    });

    test('a destroyed service is remembered as down', () async {
      final AndroidService service = AndroidService(android: true);

      await service.sync();
      expect(calls, ['start']);

      service.noteServiceGone();

      // Not an update of something that is no longer there: a start.
      await service.sync();
      expect(calls, ['start', 'start']);
    });
  });

  group('closing the task', () {
    test('an Activity that closed its task answers true', () async {
      expect(await finishActivityAndTask(android: true), isTrue);
      expect(calls, ['exitApp']);
    });

    // Both mean the same to the caller: nothing closed the task, so the exit
    // has to fall back to ending the screen on its own.
    test('a refused or missing channel answers false', () async {
      failWith = PlatformException(code: 'easysend');
      expect(await finishActivityAndTask(android: true), isFalse);

      failWith = MissingPluginException('no implementation');
      expect(await finishActivityAndTask(android: true), isFalse);
      expect(calls, ['exitApp', 'exitApp']);
    });
  });
}
