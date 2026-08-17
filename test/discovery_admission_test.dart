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
      xvNow = () => now;
      addTearDown(() => xvNow = DateTime.now);
      final DiscoveryService service = DiscoveryService(
        maxTransientDevices: 3,
        maxNewPeersPerWindow: 4,
        maxNewPeersPerSource: 2,
        admissionWindow: const Duration(seconds: 5),
        uiUpdateInterval: const Duration(milliseconds: 20),
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

  // An id is public — every announce carries it in clear text — so a packet is
  // not evidence about where a device lives. For a record the user typed by hand
  // it used to be exactly that, and rewriting its address is enough to send the
  // next transfer to whoever sent the packet.
  test('an announce never moves an address the user typed', () {
    final DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    final Device typed = Device(
      id: 'phone',
      name: 'A36',
      address: '192.168.204.250',
      port: 15353,
      manual: true,
      trusted: true,
    );
    xvDevices = [typed];
    final DiscoveryService service = DiscoveryService();
    addTearDown(service.stop);

    service.touchDeviceForTesting(
      id: 'phone',
      name: 'Impostor',
      address: '192.168.204.99',
      port: 15353,
    );

    // Nothing of the record moved, and the packet did not even mark it alive.
    expect(typed.address, '192.168.204.250');
    expect(typed.name, 'A36');
    expect(typed.lastSeen, isNull);

    // From the address it is listed at, the same announce is ordinary news.
    service.touchDeviceForTesting(
      id: 'phone',
      name: 'A36 renamed',
      address: '192.168.204.250',
      port: 15353,
    );
    expect(typed.name, 'A36 renamed');
    expect(typed.lastSeen, now);
  });

  // A discovered device has no other way of telling us its new address, so it
  // still follows announces; what protects a send to it is the identity check in
  // the sender (see ADD/tofix8.md finding 1).
  test('a discovered device still follows its announces', () {
    final DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    final Device found = Device(
      id: 'laptop',
      name: 'Laptop',
      address: '10.0.0.5',
      trusted: true,
    );
    xvDevices = [found];
    final DiscoveryService service = DiscoveryService();
    addTearDown(service.stop);

    service.touchDeviceForTesting(id: 'laptop', address: '10.0.0.9');

    expect(found.address, '10.0.0.9');
    expect(found.lastSeen, now);
  });

  test('only announce, query and bye are discovery protocol messages', () {
    expect(isSupportedDiscoveryMessage({'t': 'announce'}), isTrue);
    expect(isSupportedDiscoveryMessage({'t': 'query'}), isTrue);
    expect(isSupportedDiscoveryMessage({'t': 'bye'}), isTrue);
    expect(isSupportedDiscoveryMessage({'t': 'delete'}), isFalse);
    expect(isSupportedDiscoveryMessage({'id': 'peer'}), isFalse);
    expect(isSupportedDiscoveryMessage('announce'), isFalse);
  });

  test('bye marks the sender offline without dropping the row', () {
    // A stub, and the model reads the very same one: how long ago a device left
    // is judged by xvNow() on both sides of the record.
    DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    xvDevices = [
      Device(id: 'leaving', name: 'Leaving', address: '10.0.0.5'),
      Device(id: 'manual', name: 'Manual', address: '10.0.0.6', manual: true),
    ];
    for (final Device device in xvDevices) {
      device.lastSeen = now;
    }
    final DiscoveryService service = DiscoveryService();
    addTearDown(service.stop);

    final DateTime left = now;
    service.noteDepartureForTesting(id: 'leaving', address: '10.0.0.5');
    final Device leaving = xvDevices.singleWhere((d) => d.id == 'leaving');
    expect(leaving.lastSeen, lastSeenAfterBye(now));
    expect(
      now.difference(leaving.lastSeen!).inSeconds,
      greaterThan(deviceTimeoutSec),
    );
    // Still listed: it leaves on the ordinary schedule, not under the cursor.
    expect(xvDevices.any((d) => d.id == 'leaving'), isTrue);
    // Which of the two silences this is, for the row to say so.
    expect(leaving.departed, isTrue);
    // News for exactly the minute it is defined to last, and not a second more.
    now = left.add(const Duration(seconds: departedNoticeSec));
    expect(leaving.departed, isTrue);
    now = left.add(const Duration(seconds: departedNoticeSec + 1));
    expect(leaving.departed, isFalse);
    now = left;

    // An announce right after brings it straight back.
    service.touchDeviceForTesting(id: 'leaving', address: '10.0.0.5');
    expect(leaving.lastSeen, now);
    expect(leaving.departed, isFalse);
  });

  test('bye is ignored from a stranger and for a stranger', () {
    final DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    xvDevices = [
      Device(id: 'listed', name: 'Listed', address: '10.0.0.5', lastSeen: now),
    ];
    final DiscoveryService service = DiscoveryService();
    addTearDown(service.stop);

    // Somebody else's id from somebody else's address.
    service.noteDepartureForTesting(id: 'listed', address: '10.0.0.99');
    // A device nobody has heard of does not get a row out of leaving.
    service.noteDepartureForTesting(id: 'unknown', address: '10.0.0.7');

    expect(xvDevices.singleWhere((d) => d.id == 'listed').lastSeen, now);
    expect(xvDevices.singleWhere((d) => d.id == 'listed').departed, isFalse);
    expect(xvDevices.any((d) => d.id == 'unknown'), isFalse);
  });

  test('a manual device hears the goodbye too, and outlives the online window', () {
    // The case the feature exists for here: a phone on another subnet, added by
    // hand, which multicast never reaches. It is judged by the polling interval
    // rather than the announce one, so the record has to age past that.
    final DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    final Device phone = Device(
      id: 'phone',
      name: 'A36',
      address: '192.168.204.250',
      manual: true,
      trusted: true,
      lastSeen: now,
    );
    xvDevices = [phone];
    final DiscoveryService service = DiscoveryService();
    addTearDown(service.stop);

    service.noteDepartureForTesting(id: 'phone', address: '192.168.204.250');

    expect(phone.departed, isTrue);
    expect(phone.online, isFalse);
    // A trusted manual device is never dropped from the list, only greyed out.
    expect(xvDevices, hasLength(1));
  });

  // The row and the badge are two windows and they are related by arithmetic:
  // dropping happens deviceDropSec after the last announce, and a goodbye
  // backdates that stamp past both online windows. Written down as a test so the
  // constants cannot drift apart unnoticed.
  test('a row that said goodbye outlives the bye by the documented time', () async {
    DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    xvDevices = [];

    final DiscoveryService service = DiscoveryService(
      bindPort: 0,
      interfaceProvider: () async => const [],
      broadcastOverride: (_) {},
      unicastOverride: (_, _) {},
    );
    addTearDown(service.stop);
    expect(await service.start(), isTrue);

    service.touchDeviceForTesting(id: 'leaving', address: '10.0.0.5');
    final DateTime bye = now;
    service.noteDepartureForTesting(id: 'leaving', address: '10.0.0.5');

    // One second before the documented moment the row is still there, and it is
    // still saying how the device went away.
    now = bye.add(const Duration(seconds: departedNoticeSec - 1));
    await service.tickNow();
    expect(xvDevices.singleWhere((d) => d.id == 'leaving').departed, isTrue);

    // And one second later it is gone: deviceDropSec after a stamp the goodbye
    // had already pushed back.
    now = bye.add(const Duration(seconds: departedNoticeSec));
    await service.tickNow();
    expect(xvDevices.any((d) => d.id == 'leaving'), isFalse);
  });

  test('how a device left is news, and stops being news after a minute', () {
    // Otherwise a manual or trusted device — the kind that is never dropped from
    // the list — would wear the badge until it came back, which on a phone that
    // is switched off for the night means until morning.
    final DateTime now = DateTime.utc(2026, 8, 17, 12);
    xvNow = () => now;
    addTearDown(() => xvNow = DateTime.now);
    final Device device = Device(id: 'phone', name: 'A36', manual: true);

    device.departedAt = now.subtract(
      const Duration(seconds: departedNoticeSec - 1),
    );
    expect(device.departed, isTrue);

    device.departedAt = now.subtract(
      const Duration(seconds: departedNoticeSec + 1),
    );
    expect(device.departed, isFalse);

    // And it is never remembered across a restart: the file holds no trace of
    // it, so an app that starts up shows a plain offline row.
    expect(device.toJson().containsKey('departedAt'), isFalse);
    expect(Device.fromJson(device.toJson()).departedAt, isNull);
  });
}
