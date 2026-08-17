import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// The settings screen renders global state that changes underneath it: an
// incoming transfer accepted with "always trust", and the switch that marks a
// peer trusted after a successful prepare, both fire while this screen can be
// sitting on top of the main one. Nothing here builds a widget — the project has
// no widget tests (ADD/tofix5.md finding 11, accepted) — so the wiring is pinned
// by reading the source, the way the Android contract test does.
void main() {
  late String settings;

  setUpAll(() async {
    settings = await File('lib/settings_screen.dart').readAsString();
  });

  test('the screen follows the device list instead of snapshotting it', () {
    expect(settings, contains('listenable: devicesTick'));

    // The list has to be read inside the subtree that rebuilds, not above it:
    // computing it in build() and rebuilding the body changes nothing.
    final int listener = settings.indexOf('listenable: devicesTick');
    final int reads = settings.indexOf("xvDevices.where((d) => d.trusted)");
    expect(reads, greaterThan(listener));
  });

  test('the addresses are not re-read by a device tick', () {
    // They are State, filled in initState and again only when the user opens the
    // "My IP" dialog. A tick that re-fetched them would hit the network every
    // time any device announced itself.
    final int listener = settings.indexOf('listenable: devicesTick');
    final int fetch = settings.indexOf('await localAddresses()');
    expect(fetch, lessThan(listener));
    expect('await localAddresses()'.allMatches(settings), hasLength(1));
  });
}
