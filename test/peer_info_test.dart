import 'dart:convert';

import 'package:easysend/globals.dart';
import 'package:easysend/net_discovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PeerInfo? parse(dynamic payload) =>
      validatedPeerInfo(payload, fallbackPort: defaultPort);

  test('a well-formed announce is taken as it came', () {
    final PeerInfo? peer = parse({
      'id': 'peer-id',
      'name': 'Laptop',
      'platform': 'linux',
      'port': 40000,
    });
    expect(peer, isNotNull);
    expect(peer!.id, 'peer-id');
    expect(peer.name, 'Laptop');
    expect(peer.platform, 'linux');
    expect(peer.port, 40000);
  });

  test('missing optional fields fall back without inventing a name', () {
    final PeerInfo? peer = parse({'id': 'bare'});
    expect(peer, isNotNull);
    expect(peer!.name, isEmpty);
    expect(peer.platform, isEmpty);
    expect(peer.port, defaultPort);
  });

  test('an unusable id is refused', () {
    expect(parse({'id': ''}), isNull);
    expect(parse({'id': 42}), isNull);
    expect(parse({'name': 'no id at all'}), isNull);
    expect(parse({'id': 'x' * (maxProtocolIdBytes + 1)}), isNull);
    // Bytes, not characters: two-byte letters count double.
    expect(parse({'id': 'ю' * maxProtocolIdBytes}), isNull);
    expect(
      parse({'id': 'ю' * (maxProtocolIdBytes ~/ 2)}),
      isNotNull,
      reason: 'exactly at the limit in bytes',
    );
  });

  test('an oversized name or platform is refused', () {
    expect(parse({'id': 'a', 'name': 'n' * (maxSenderNameBytes + 1)}), isNull);
    expect(parse({'id': 'a', 'name': 7}), isNull);
    expect(parse({'id': 'a', 'platform': 'p' * (maxPlatformBytes + 1)}), isNull);
    expect(parse({'id': 'a', 'platform': false}), isNull);
  });

  test('a port outside the range is refused, not silently replaced', () {
    expect(parse({'id': 'a', 'port': 0}), isNull);
    expect(parse({'id': 'a', 'port': 65536}), isNull);
    expect(parse({'id': 'a', 'port': -1}), isNull);
    expect(parse({'id': 'a', 'port': '15353'}), isNull);
    expect(parse({'id': 'a', 'port': 65535})!.port, 65535);
  });

  test('anything that is not an object is refused', () {
    expect(parse(null), isNull);
    expect(parse('announce'), isNull);
    expect(parse([1, 2, 3]), isNull);
  });

  test('what this app announces about itself passes its own check', () {
    final Map<String, dynamic> announce = buildDiscoveryPayload(
      type: 'announce',
      id: 'my-id',
      name: 'My Device',
      platform: 'android',
      transferPort: defaultPort,
    );
    final PeerInfo? peer = parse(json.decode(json.encode(announce)));
    expect(peer, isNotNull);
    expect(peer!.port, defaultPort);
  });
}
