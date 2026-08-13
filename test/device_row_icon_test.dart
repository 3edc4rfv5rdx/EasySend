import 'package:easysend/home_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a reachable device shows its plain platform icon', () {
    expect(deviceRowIcon(phone: true, online: true), Icons.smartphone);
    expect(deviceRowIcon(phone: false, online: true), Icons.computer);
  });

  test('an unreachable device is struck through, and still says which it is', () {
    // The struck-through icon replaced the word "offline" in the row, so it has
    // to carry both facts on its own: unreachable, and what kind of device.
    expect(deviceRowIcon(phone: true, online: false), Icons.phonelink_off);
    expect(
      deviceRowIcon(phone: false, online: false),
      Icons.desktop_access_disabled,
    );
  });

  test('every combination gives a different icon', () {
    final Set<IconData> icons = <IconData>{
      for (final bool phone in <bool>[true, false])
        for (final bool online in <bool>[true, false])
          deviceRowIcon(phone: phone, online: online),
    };
    expect(icons.length, 4);
  });
}
