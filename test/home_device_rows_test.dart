import 'package:easysend/globals.dart';
import 'package:easysend/home_screen.dart';
import 'package:flutter_test/flutter_test.dart';

Device seen(
  String name, {
  bool online = true,
  bool trusted = false,
  bool manual = false,
}) => Device(
  id: name,
  name: name,
  trusted: trusted,
  manual: manual,
  // Out of the timeout window by a wide margin when it is meant to be away.
  lastSeen: online
      ? xvNow()
      : xvNow().subtract(const Duration(seconds: deviceDropSec * 10)),
);

void main() {
  test('a device in reach gets a row whatever it is', () {
    expect(
      homeDeviceRows([
        seen('plain'),
        seen('trusted', trusted: true),
        seen('manual', manual: true),
      ]).map((Device d) => d.name),
      ['manual', 'plain', 'trusted'],
    );
  });

  test('an unreachable trusted device is left to the settings screen', () {
    expect(homeDeviceRows([seen('away', online: false, trusted: true)]), isEmpty);
  });

  test('an unreachable device added by hand keeps its row', () {
    // Nothing else can reach it: the address was typed in, and the button that
    // removes it is on this list.
    expect(
      homeDeviceRows([
        seen('away', online: false, manual: true, trusted: true),
      ]).single.name,
      'away',
    );
  });

  test('the peer of a running transfer keeps its row while it runs', () {
    final Device peer = seen('peer', online: false, trusted: true);
    final TransferSession transfer = TransferSession(
      id: 't',
      incoming: false,
      peerName: peer.name,
      peerId: peer.id,
      files: [],
    );
    xvTransfers = [transfer];

    transfer.status = TransferStatus.active;
    expect(homeDeviceRows([peer]).single.name, 'peer');

    // Over, and the row goes back to being a copy of a settings row.
    transfer.status = TransferStatus.done;
    expect(homeDeviceRows([peer]), isEmpty);
  });

  test('reachable first, then by name, whatever order they arrive in', () {
    expect(
      homeDeviceRows([
        seen('Zoe'),
        seen('away', online: false, manual: true),
        seen('anna'),
      ]).map((Device d) => d.name),
      ['anna', 'Zoe', 'away'],
    );
  });

  test('the list it is given is left alone', () {
    final List<Device> devices = [
      seen('here'),
      seen('gone', online: false, trusted: true),
    ];
    homeDeviceRows(devices);
    expect(devices.map((Device d) => d.name), ['here', 'gone']);
  });
}
