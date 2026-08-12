import 'package:easysend/android_helpers.dart';
import 'package:easysend/globals.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('easysend/service');
  final List<String> calls = [];
  Object? failWith;

  setUp(() {
    calls.clear();
    failWith = null;
    xvTransfers = [];
    xdef['Program language'] = 'en';
    xdef['Receive in background'] = 'true';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call.method);
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
}
