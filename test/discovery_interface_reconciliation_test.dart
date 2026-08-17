import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('discovery reconciles interfaces and announces every change', () async {
    final List<NetworkInterface> available = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: true,
      includeLinkLocal: true,
    );
    expect(available, isNotEmpty);
    final NetworkInterface interface = available.first;
    List<NetworkInterface> snapshot = const [];
    bool enumerationFails = false;
    int joins = 0;
    int leaves = 0;
    final List<String> broadcasts = [];
    xvDeviceId = 'test-device';
    xvDeviceName = 'Test device';
    xvPlatform = 'linux';

    final DiscoveryService service = DiscoveryService(
      bindPort: 0,
      interfaceProvider: () async {
        if (enumerationFails) throw const SocketException('not ready');
        return snapshot;
      },
      joinOverride: (_) => joins++,
      leaveOverride: (_) => leaves++,
      broadcastOverride: broadcasts.add,
    );
    addTearDown(service.stop);

    expect(await service.start(), isTrue);
    expect(service.activeInterfaceKeys, isEmpty);
    expect(broadcasts, ['query', 'announce']);

    snapshot = [interface];
    await service.tickNow();
    expect(service.activeInterfaceKeys, hasLength(1));
    expect(joins, 1);
    expect(broadcasts, ['query', 'announce', 'query', 'announce']);

    // An unchanged tick sends the regular announce but neither duplicates the
    // membership nor sends another topology query.
    await service.tickNow();
    expect(joins, 1);
    expect(broadcasts.last, 'announce');
    expect(broadcasts.where((type) => type == 'query'), hasLength(2));

    enumerationFails = true;
    await service.tickNow();
    expect(service.activeInterfaceKeys, hasLength(1));
    expect(leaves, 0);

    enumerationFails = false;
    snapshot = const [];
    await service.tickNow();
    expect(service.activeInterfaceKeys, isEmpty);
    expect(leaves, 1);
    expect(broadcasts.sublist(broadcasts.length - 2), ['query', 'announce']);
  });

  test('only a real exit says goodbye, and it says it to the list', () async {
    final List<String> broadcasts = [];
    final List<String> unicasts = [];
    xvDeviceId = 'test-device';
    xvDeviceName = 'Test device';
    xvPlatform = 'linux';
    // What this machine actually has in front of it: two devices added by hand
    // on other subnets, which no multicast of ours will ever reach.
    xvDevices = [
      Device(
        id: 'phone',
        name: 'A36',
        address: '192.168.204.250',
        manual: true,
      ),
      Device(
        id: 'emu',
        name: 'Emulator',
        address: '192.168.54.250',
        port: 15352,
        manual: true,
      ),
      Device(id: 'nowhere', name: 'Never seen', address: ''),
    ];

    final DiscoveryService service = DiscoveryService(
      bindPort: 0,
      interfaceProvider: () async => const [],
      broadcastOverride: broadcasts.add,
      unicastOverride: (String type, String address) =>
          unicasts.add('$type $address'),
    );
    addTearDown(service.stop);

    expect(await service.start(), isTrue);
    // A restart, a lost network or a screen going away stops the same service.
    await service.stop();
    expect(broadcasts.contains('bye'), isFalse);
    expect(unicasts, isEmpty);

    expect(await service.start(), isTrue);
    await service.stop(announceLeaving: true);
    expect(broadcasts.last, 'bye');
    // Straight to every address on the list, and nothing sent into the void.
    expect(unicasts, ['bye 192.168.204.250', 'bye 192.168.54.250']);
    expect(service.running, isFalse);
  });

  // The goodbye matters most exactly when discovery is already down: the network
  // moved, the receive folder went away and the advertisement was stopped, a port
  // change is pending. Sending it through the live socket alone meant those exits
  // said nothing at all and every peer waited out the twenty-second silence.
  test('an exit says goodbye even with discovery already down', () async {
    final List<String> broadcasts = [];
    final List<String> unicasts = [];
    xvDevices = [
      Device(id: 'phone', name: 'A36', address: '192.168.204.250', manual: true),
      Device(id: 'nowhere', name: 'Never seen', address: ''),
    ];

    final DiscoveryService service = DiscoveryService(
      bindPort: 0,
      interfaceProvider: () async => const [],
      broadcastOverride: broadcasts.add,
      unicastOverride: (String type, String address) =>
          unicasts.add('$type $address'),
    );

    // Never started, so there is no socket to send through.
    expect(service.running, isFalse);
    await service.stop(announceLeaving: true);

    expect(unicasts, ['bye 192.168.204.250']);
    expect(broadcasts, ['bye']);
  });

  test('a stop that is not an exit still says nothing with no socket', () async {
    final List<String> broadcasts = [];
    final List<String> unicasts = [];
    xvDevices = [
      Device(id: 'phone', name: 'A36', address: '192.168.204.250', manual: true),
    ];

    final DiscoveryService service = DiscoveryService(
      bindPort: 0,
      interfaceProvider: () async => const [],
      broadcastOverride: broadcasts.add,
      unicastOverride: (String type, String address) =>
          unicasts.add('$type $address'),
    );

    await service.stop();

    expect(unicasts, isEmpty);
    expect(broadcasts, isEmpty);
  });
}
