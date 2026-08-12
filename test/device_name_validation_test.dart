import 'dart:convert';

import 'package:easysend/globals.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('device names are measured in UTF-8 bytes across scripts', () {
    final List<String> accepted = [
      'Laptop',
      'Ноутбук',
      '设备',
      '😀',
      'a' * maxSenderNameBytes,
      '😀' * (maxSenderNameBytes ~/ 4),
    ];
    for (final String name in accepted) {
      expect(validateDeviceName(name), isNull, reason: name);
      expect(utf8.encode(name).length, lessThanOrEqualTo(maxSenderNameBytes));
      expect(
        validatedPeerInfo({
          'id': 'peer',
          'name': name,
        }, fallbackPort: defaultPort),
        isNotNull,
        reason: name,
      );
    }

    expect(
      validateDeviceName('a' * (maxSenderNameBytes + 1)),
      DeviceNameProblem.tooLong,
    );
    expect(
      validateDeviceName('😀' * (maxSenderNameBytes ~/ 4 + 1)),
      DeviceNameProblem.tooLong,
    );
  });

  test('empty and control-character names have specific failures', () {
    expect(validateDeviceName(''), DeviceNameProblem.empty);
    expect(validateDeviceName('', allowEmpty: true), isNull);
    for (final String name in ['line\nbreak', 'tab\tname', 'delete\u007f']) {
      expect(validateDeviceName(name), DeviceNameProblem.controlCharacter);
      expect(
        validatedPeerInfo({
          'id': 'peer',
          'name': name,
        }, fallbackPort: defaultPort),
        isNull,
      );
    }
  });

  test('an invalid edit cannot mutate the active or persisted identity', () {
    xdef['Device name'] = 'Before';
    xvDeviceName = 'Before';

    expect(updateDeviceName('bad\nname'), isFalse);
    expect(updateDeviceName('x' * (maxSenderNameBytes + 1)), isFalse);
    expect(xdef['Device name'], 'Before');
    expect(xvDeviceName, 'Before');

    expect(updateDeviceName('Після 😀'), isTrue);
    expect(xdef['Device name'], 'Після 😀');
    expect(xvDeviceName, 'Після 😀');
  });
}
