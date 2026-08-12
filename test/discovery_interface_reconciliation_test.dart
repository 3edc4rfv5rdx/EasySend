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
}
