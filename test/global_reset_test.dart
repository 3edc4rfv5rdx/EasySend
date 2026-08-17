import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

// The reset in flutter_test_config.dart is what these two tests are about: the
// first leaves every borrowed global in a state that would poison its neighbour,
// and the second asserts it did not. They have to run in this order — the test
// package runs them in declaration order — and the second one is the assertion.
void main() {
  test('a test may leave the globals in any state it likes', () {
    xdef['Port'] = '1';
    xdef['Trust after sending'] = 'false';
    xvDevices = [Device(id: 'leftover', name: 'Leftover')];
    xvTransfers = [
      TransferSession(
        id: 'leftover',
        incoming: false,
        peerName: 'Leftover',
        files: const [],
      ),
    ];
    xvNow = () => DateTime.utc(1999);
    xvConfigDir = '/tmp/leftover';
    xvRecvDir = '/tmp/leftover';
    xvDeviceId = 'leftover';
    xvDeviceName = 'Leftover';
    xvPlatform = 'leftover';

    expect(xvDevices, hasLength(1));
  });

  test('and the next one starts from defaults anyway', () {
    expect(xdef, defaultSettings());
    expect(xvDevices, isEmpty);
    expect(xvTransfers, isEmpty);
    expect(xvConfigDir, '');
    expect(xvRecvDir, '');
    expect(xvDeviceId, '');
    expect(xvDeviceName, '');
    expect(xvPlatform, '');
    // The clock is the one whose leak is silent: a device judged by a stubbed
    // 1999 would read as offline for ever.
    expect(xvNow().year, DateTime.now().year);
  });
}
