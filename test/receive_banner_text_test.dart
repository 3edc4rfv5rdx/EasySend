import 'package:easysend/globals.dart';
import 'package:easysend/net_server.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => xdef['Program language'] = 'en');

  test('each reason for not receiving says its own thing', () {
    expect(
      receiveBannerText(ReceiveReadinessFailure.folder, 15352),
      'Folder unavailable, receiving is off',
    );
    expect(
      receiveBannerText(ReceiveReadinessFailure.port, 15352),
      'Port is busy, receiving is off: 15352',
    );
    // The transition case cannot promise the listener is down — it may be up
    // with the rest of the setup unfinished — so it says "may be off".
    expect(
      receiveBannerText(ReceiveReadinessFailure.transition, 15352),
      'Setup did not finish, receiving may be off',
    );
  });

  test('the port number belongs to the port failure alone', () {
    for (final ReceiveReadinessFailure failure in [
      ReceiveReadinessFailure.folder,
      ReceiveReadinessFailure.transition,
    ]) {
      expect(receiveBannerText(failure, 15352), isNot(contains('15352')));
    }
  });

  test('no failure, no banner text', () {
    expect(receiveBannerText(null, 15352), isEmpty);
  });
}
