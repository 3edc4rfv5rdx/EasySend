import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// A phone that moves from one Wi-Fi to another keeps the app running while
// everything the sockets were bound through goes away underneath it. Nothing
// asks for a restart at that moment, so the services have to notice by
// themselves — otherwise the app sits there looking like it is receiving.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    xvDeviceId = 'test-device';
    xvDeviceName = 'Test device';
    xvPlatform = 'linux';
    xvDevices = [];
  });

  group('discovery', () {
    late List<NetworkInterface> available;

    setUpAll(() async {
      available = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: true,
        includeLinkLocal: true,
      );
      expect(available, isNotEmpty);
    });

    DiscoveryService serviceOver(
      List<NetworkInterface> Function() snapshot, {
      List<String>? broadcasts,
    }) {
      final DiscoveryService service = DiscoveryService(
        bindPort: 0,
        interfaceProvider: () async => snapshot(),
        joinOverride: (_) {},
        leaveOverride: (_) {},
        broadcastOverride: broadcasts == null ? (_) {} : broadcasts.add,
      );
      addTearDown(service.stop);
      return service;
    }

    test('a socket lost with the network is bound again by the next tick',
        () async {
      final DiscoveryService service = serviceOver(() => const []);
      expect(await service.start(), isTrue);
      expect(service.bindCount, 1);

      // Android closes the socket when the network it was opened on goes.
      service.loseSocketForTest();
      expect(service.running, isFalse);

      await service.tickNow();
      expect(service.running, isTrue, reason: 'nothing else would bind again');
      expect(service.bindCount, 2);
    });

    test('a stopped service is not brought back by a tick', () async {
      final DiscoveryService service = serviceOver(() => const []);
      expect(await service.start(), isTrue);
      await service.stop();

      await service.tickNow();
      expect(service.running, isFalse);
      expect(service.bindCount, 1);
    });

    test('losing the interface it worked through rebinds the socket', () async {
      List<NetworkInterface> snapshot = [available.first];
      final List<String> broadcasts = [];
      final DiscoveryService service = serviceOver(
        () => snapshot,
        broadcasts: broadcasts,
      );
      expect(await service.start(), isTrue);
      expect(service.bindCount, 1);
      broadcasts.clear();

      // The Wi-Fi network the socket was bound through is gone.
      snapshot = const [];
      await service.tickNow();
      expect(service.bindCount, 2, reason: 'the old socket cannot reach a new '
          'network on Android');
      expect(service.running, isTrue);
      // The new socket has to say who is here, or every peer waits out the
      // silence timeout before the app appears on the new network.
      expect(broadcasts, ['query', 'announce']);
    });

    test('an interface appearing beside the others keeps the socket', () async {
      List<NetworkInterface> snapshot = const [];
      final DiscoveryService service = serviceOver(() => snapshot);
      expect(await service.start(), isTrue);

      snapshot = [available.first];
      await service.tickNow();
      expect(service.bindCount, 1, reason: 'rejoining the groups is enough');
      expect(service.activeInterfaceKeys, hasLength(1));
    });
  });

  group('receive server', () {
    late Directory sandbox;
    late ReceiveServer server;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('easysend-netchange-');
      xvConfigDir = p.join(sandbox.path, 'config');
      xvRecvDir = p.join(sandbox.path, 'receive');
      xdef['Port'] = '0';
      server = ReceiveServer();
    });

    tearDown(() async {
      await server.stop();
      await sandbox.delete(recursive: true);
    });

    test('a listener closed by the system stops claiming to be running',
        () async {
      int lost = 0;
      server.onListenerLost = () => lost++;
      expect(await server.start(), isTrue);
      expect(server.running, isTrue);

      await server.loseListenerForTest();
      await pumpEventQueue();

      expect(server.running, isFalse, reason: 'the banner would lie otherwise');
      expect(lost, 1, reason: 'only the owner of the network state can restart');
      // A start that found a running listener on the wanted port used to
      // return early, which would leave the app deaf for good.
      expect(await server.start(), isTrue);
      expect(server.running, isTrue);
    });

    test('our own stop is not reported as a lost listener', () async {
      int lost = 0;
      server.onListenerLost = () => lost++;
      expect(await server.start(), isTrue);

      await server.stop();
      await pumpEventQueue();

      expect(lost, 0);
    });
  });
}
