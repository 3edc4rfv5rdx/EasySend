import 'dart:io';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('discovery port is stable while payload advertises transfer port', () {
    expect(discoveryPort, 15353);
    final payload = buildDiscoveryPayload(
      type: 'announce',
      id: 'id',
      name: 'name',
      platform: 'linux',
      transferPort: 16000,
    );
    expect(payload['port'], 16000);
    expect(payload['port'], isNot(discoveryPort));
  });

  test('discovery uses a link-local multicast group', () {
    final group = InternetAddress(discoveryMulticastGroup);
    expect(group.isMulticast, isTrue);
    expect(discoveryMulticastGroup, isNot(endsWith('.255')));
  });
}
