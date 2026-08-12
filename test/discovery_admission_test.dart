import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'discovery bounds untrusted identities and preserves saved peers',
    () async {
      DateTime now = DateTime.utc(2026);
      xvDevices = [
        Device(id: 'manual', name: 'Manual', manual: true),
        Device(id: 'trusted', name: 'Trusted', trusted: true),
      ];
      final int notificationsBefore = devicesTick.value;
      final DiscoveryService service = DiscoveryService(
        maxTransientDevices: 3,
        maxNewPeersPerWindow: 4,
        maxNewPeersPerSource: 2,
        admissionWindow: const Duration(seconds: 5),
        uiUpdateInterval: const Duration(milliseconds: 20),
        now: () => now,
      );
      addTearDown(service.stop);

      service.touchDeviceForTesting(id: 'stable', address: '10.0.0.1');
      now = now.add(const Duration(milliseconds: 1));
      service.touchDeviceForTesting(id: 'burst-1', address: '10.0.0.9');
      service.touchDeviceForTesting(id: 'burst-2', address: '10.0.0.9');
      service.touchDeviceForTesting(id: 'burst-denied', address: '10.0.0.9');

      expect(xvDevices.any((device) => device.id == 'burst-denied'), isFalse);
      expect(
        xvDevices.where((device) => !device.manual && !device.trusted),
        hasLength(3),
      );
      expect(devicesTick.value, notificationsBefore);

      // Refreshing an admitted legitimate peer makes it newer than the burst.
      now = now.add(const Duration(seconds: 1));
      service.touchDeviceForTesting(id: 'stable', address: '10.0.0.1');
      now = now.add(const Duration(seconds: 5));
      service.touchDeviceForTesting(id: 'new-peer', address: '10.0.0.8');

      expect(xvDevices.any((device) => device.id == 'stable'), isTrue);
      expect(xvDevices.any((device) => device.id == 'burst-1'), isFalse);
      expect(
        xvDevices.singleWhere((device) => device.id == 'manual').manual,
        isTrue,
      );
      expect(
        xvDevices.singleWhere((device) => device.id == 'trusted').trusted,
        isTrue,
      );
      expect(
        xvDevices.where((device) => !device.manual && !device.trusted),
        hasLength(3),
      );

      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(devicesTick.value, notificationsBefore + 1);
    },
  );

  test('only announce and query are discovery protocol messages', () {
    expect(isSupportedDiscoveryMessage({'t': 'announce'}), isTrue);
    expect(isSupportedDiscoveryMessage({'t': 'query'}), isTrue);
    expect(isSupportedDiscoveryMessage({'t': 'delete'}), isFalse);
    expect(isSupportedDiscoveryMessage({'id': 'peer'}), isFalse);
    expect(isSupportedDiscoveryMessage('announce'), isFalse);
  });
}
