import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'android_helpers.dart';
import 'control_body.dart';
import 'globals.dart';

Map<String, dynamic> buildDiscoveryPayload({
  required String type,
  required String id,
  required String name,
  required String platform,
  required int transferPort,
}) => {
  't': type,
  'id': id,
  'name': name,
  'platform': platform,
  'port': transferPort,
};

const int maxTransientDiscoveryDevices = 128;
const int maxNewDiscoveryPeersPerWindow = 64;
const int maxNewDiscoveryPeersPerSource = 16;
const Duration discoveryAdmissionWindow = Duration(seconds: 5);
const Duration discoveryUiUpdateInterval = Duration(milliseconds: 100);

bool isSupportedDiscoveryMessage(dynamic message) =>
    message is Map &&
    (message['t'] == 'announce' ||
        message['t'] == 'query' ||
        message['t'] == 'bye');

// A departing device says so once, and the packet may well be lost, so a bye
// only ages the record out of the online window instead of dropping it: the
// device leaves the list on the ordinary schedule, and a single announce puts
// it back. The silence timeout stays the mechanism actually relied on.
//
// Past the longer of the two windows, because a manual device is judged by the
// polling interval rather than the announce one and has to fall out of both.
DateTime lastSeenAfterBye(DateTime now) => now.subtract(
  Duration(
    seconds:
        (deviceTimeoutSec > manualPollSec * 2
            ? deviceTimeoutSec
            : manualPollSec * 2) +
        1,
  ),
);

// Devices worth remembering stay in the list while offline; the rest are dropped
// a minute after going quiet (SPEC 5.2).
//
// Out of DiscoveryService on purpose. It used to live in the announce tick, which
// exists only while discovery is running — and discovery is stopped in exactly the
// cases where a row goes stale and stays: the receive folder became unwritable or
// the port is busy, so the advertisement was taken down; a port change is pending;
// a transition failed. The list would then keep rows nothing was keeping honest.
// So the rule belongs to the list, and every loop that runs while the list is on
// screen calls it.
//
// The peer of a running transfer is left alone whatever its clock says: with
// discovery down nothing refreshes its stamp, and dropping the row out from under
// a transfer in flight would take the target off the screen mid-send.
void forgetStaleDevices() {
  final DateTime now = xvNow();
  final int before = xvDevices.length;
  xvDevices.removeWhere((Device d) {
    if (d.manual || d.trusted) return false;
    if (xvTransfers.any(
      (TransferSession t) => t.isRunning && t.peerId == d.id,
    )) {
      return false;
    }
    final DateTime? seen = d.lastSeen;
    return seen == null || now.difference(seen).inSeconds > deviceDropSec;
  });
  if (xvDevices.length != before) devicesChanged();
}

// UDP presence on the local subnet. Broadcast never crosses a router, so
// devices behind one are added by hand instead (SPEC 5.2, 5.4).
class DiscoveryService {
  final int bindPort;
  final Future<List<NetworkInterface>> Function() _interfaceProvider;
  final void Function(NetworkInterface interface)? _joinOverride;
  final void Function(NetworkInterface interface)? _leaveOverride;
  final void Function(String type)? _broadcastOverride;
  final void Function(String type, String address)? _unicastOverride;
  final int maxTransientDevices;
  final int maxNewPeersPerWindow;
  final int maxNewPeersPerSource;
  final Duration admissionWindow;
  final Duration uiUpdateInterval;
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  int _port = 0;
  Map<String, NetworkInterface> _interfaces = const {};
  final Set<String> _joinedInterfaces = <String>{};
  bool _tickRunning = false;
  Timer? _deviceUpdateTimer;
  DateTime? _admissionWindowStarted;
  int _newPeersInWindow = 0;
  final Map<String, int> _newPeersBySource = <String, int>{};
  final InternetAddress _group = InternetAddress(discoveryMulticastGroup);

  DiscoveryService({
    this.bindPort = discoveryPort,
    Future<List<NetworkInterface>> Function()? interfaceProvider,
    void Function(NetworkInterface interface)? joinOverride,
    void Function(NetworkInterface interface)? leaveOverride,
    void Function(String type)? broadcastOverride,
    void Function(String type, String address)? unicastOverride,
    this.maxTransientDevices = maxTransientDiscoveryDevices,
    this.maxNewPeersPerWindow = maxNewDiscoveryPeersPerWindow,
    this.maxNewPeersPerSource = maxNewDiscoveryPeersPerSource,
    this.admissionWindow = discoveryAdmissionWindow,
    this.uiUpdateInterval = discoveryUiUpdateInterval,
  }) : _interfaceProvider = interfaceProvider ?? _activeIpv4Interfaces,
       _joinOverride = joinOverride,
       _leaveOverride = leaveOverride,
       _broadcastOverride = broadcastOverride,
       _unicastOverride = unicastOverride;

  bool get running => _socket != null;

  @visibleForTesting
  Set<String> get activeInterfaceKeys => Set.unmodifiable(_interfaces.keys);

  Future<bool> start() async {
    await stop();
    _port = bindPort;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _socket!.broadcastEnabled = true;
      _socket!.multicastHops = 1;
      _socket!.multicastLoopback = true;
      if (_port == 0) _port = _socket!.port;
      await _reconcileInterfaces();
      await setDiscoveryMulticastEnabled(true);
      _socket!.listen(_onEvent);
    } catch (e) {
      myPrint('discovery bind failed on $_port: $e');
      _socket = null;
      return false;
    }
    // Ask everyone to speak up, then keep announcing on a timer.
    unawaited(_broadcast('query'));
    unawaited(_broadcast('announce'));
    _announceTimer = Timer.periodic(
      const Duration(seconds: announceIntervalSec),
      (_) => unawaited(_tick()),
    );
    myPrint('discovery started on $_port');
    return true;
  }

  // announceLeaving belongs to a real exit only. A stop for a restart, a lost
  // network or a screen going away leaves a receiver that is still meant to be
  // found, and telling everyone otherwise would blank the app out of their
  // lists for no reason.
  Future<void> stop({bool announceLeaving = false}) async {
    _announceTimer?.cancel();
    _announceTimer = null;
    // The last packets before the socket goes, so peers switch the row to
    // offline now instead of waiting out the silence.
    if (announceLeaving) await _sayGoodbye();
    _socket?.close();
    _socket = null;
    _interfaces = const {};
    _joinedInterfaces.clear();
    final Timer? pendingDeviceUpdate = _deviceUpdateTimer;
    pendingDeviceUpdate?.cancel();
    _deviceUpdateTimer = null;
    if (pendingDeviceUpdate != null) devicesChanged();
    _admissionWindowStarted = null;
    _newPeersInWindow = 0;
    _newPeersBySource.clear();
    await setDiscoveryMulticastEnabled(false);
  }

  Future<void> _tick() async {
    if (_tickRunning) return;
    _tickRunning = true;
    final RawDatagramSocket? socket = _socket;
    try {
      final bool changed = await _reconcileInterfaces();
      // A stop/restart may finish while interface enumeration is in flight.
      // That obsolete tick must not broadcast through the replacement socket.
      if (socket == null || _socket != socket) return;
      if (changed) unawaited(_broadcast('query'));
      unawaited(_broadcast('announce'));
      forgetStaleDevices();
      // Going offline is a silent event: nothing arrives to signal it. Without
      // a nudge here the list would keep showing a dead device as reachable.
      devicesChanged();
    } finally {
      _tickRunning = false;
    }
  }

  @visibleForTesting
  Future<void> tickNow() => _tick();

  Map<String, dynamic> _payload(String type) => buildDiscoveryPayload(
    type: type,
    id: xvDeviceId,
    name: xvDeviceName,
    platform: xvPlatform,
    transferPort: currentPort,
  );

  // Awaitable so a farewell packet can be seen out before the socket closes.
  Future<void> _broadcast(String type) async {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;
    final void Function(String type)? override = _broadcastOverride;
    if (override != null) {
      override(type);
      return;
    }
    final List<int> data = utf8.encode(json.encode(_payload(type)));
    // Limited broadcast remains as a compatibility fallback. Multicast does
    // not depend on an assumed /24 netmask and is sent on every interface.
    socket.send(data, InternetAddress('255.255.255.255'), _port);
    await _sendMulticast(data);
  }

  void _sendTo(String type, InternetAddress address, int port) {
    final void Function(String type, String address)? override =
        _unicastOverride;
    if (override != null) {
      override(type, address.address);
      return;
    }
    try {
      _socket?.send(utf8.encode(json.encode(_payload(type))), address, port);
    } catch (e) {
      myPrint('unicast to ${address.address} failed: $e');
    }
  }

  // Everyone on the list who has an address at all. A peer that is already gone
  // costs one datagram nobody reads; a record without an address has nothing to
  // send to.
  Iterable<InternetAddress> _listedPeerAddresses() {
    return List.of(xvDevices)
        .map((Device device) => InternetAddress.tryParse(device.address))
        .nonNulls;
  }

  // Where a farewell is addressed: the discovery port every build listens on,
  // never a transfer port. The live socket's own port while there is one — the
  // two differ whenever the bind port was left to the system — and the port that
  // was asked for when discovery is already down.
  int get _farewellPort =>
      _port != 0 ? _port : (bindPort != 0 ? bindPort : discoveryPort);

  // Goodbye straight to everyone on the list. Multicast never leaves the subnet,
  // so a device added by hand — behind a router, on another subnet, over a VPN —
  // would otherwise never hear it.
  void _farewellUnicast() {
    for (final InternetAddress address in _listedPeerAddresses()) {
      _sendTo('bye', address, _farewellPort);
    }
  }

  // The farewell, whether or not discovery is still up.
  //
  // It is down in exactly the cases the goodbye matters most: the network went
  // away and came back on another interface, the receive folder became
  // unwritable and the advertisement was taken down, a port change is pending.
  // With no socket the packets used to be dropped in silence — myPrint is
  // compiled out of a release build — and every peer waited out the full
  // timeout, which is the wait this feature exists to remove.
  Future<void> _sayGoodbye() async {
    if (_socket != null) {
      _farewellUnicast();
      await _broadcast('bye');
      return;
    }
    // A test drives the sends through overrides; there is no socket to borrow
    // and none is needed.
    final void Function(String type)? broadcast = _broadcastOverride;
    if (_unicastOverride != null || broadcast != null) {
      _farewellUnicast();
      broadcast?.call('bye');
      return;
    }
    // An exit must not hang on a socket the OS will not give, and the silence
    // timeout on the other side remains the mechanism actually relied on. Only
    // the waiting is bounded: the attempt itself swallows its own failures, so a
    // bind that lands after the deadline cannot surface as an unhandled error in
    // a future nobody is holding any more.
    try {
      await _farewellFromBorrowedSocket().timeout(
        const Duration(seconds: farewellTimeoutSec),
      );
    } on TimeoutException {
      myPrint('goodbye without discovery took too long, leaving anyway');
    }
  }

  // One socket for one round of packets, then closed. Per-interface multicast is
  // not attempted: `_interfaces` was cleared when discovery stopped, so this
  // sends the group packet on the default route and the limited broadcast beside
  // it. The unicasts are the part that carries — they are what reaches the
  // devices no broadcast could have reached anyway.
  Future<void> _farewellFromBorrowedSocket() async {
    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      socket.multicastHops = 1;
      final List<int> data = utf8.encode(json.encode(_payload('bye')));
      final int port = _farewellPort;
      for (final InternetAddress address in _listedPeerAddresses()) {
        socket.send(data, address, port);
      }
      socket.send(data, InternetAddress('255.255.255.255'), port);
      socket.send(data, _group, port);
    } catch (e) {
      myPrint('cannot say goodbye with discovery down: $e');
    } finally {
      socket?.close();
    }
  }

  static Future<List<NetworkInterface>> _activeIpv4Interfaces() =>
      NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );

  String _interfaceKey(NetworkInterface interface) {
    final List<String> addresses =
        interface.addresses
            .where((address) => address.type == InternetAddressType.IPv4)
            .map((address) => address.address)
            .toList()
          ..sort();
    return '${interface.index}|${interface.name}|${addresses.join(',')}';
  }

  Future<bool> _reconcileInterfaces() async {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return false;
    late final List<NetworkInterface> listed;
    try {
      listed = await _interfaceProvider();
    } catch (error) {
      // A transient enumeration failure must not tear down memberships that
      // may still be the only route to peers.
      myPrint('interface list failed: $error');
      return false;
    }
    if (_socket != socket) return false;

    final Map<String, NetworkInterface> next = {
      for (final NetworkInterface interface in listed)
        _interfaceKey(interface): interface,
    };
    final bool changed =
        !next.keys.toSet().containsAll(_interfaces.keys) ||
        !_interfaces.keys.toSet().containsAll(next.keys);

    for (final MapEntry<String, NetworkInterface> old in _interfaces.entries) {
      if (next.containsKey(old.key)) continue;
      if (_joinedInterfaces.remove(old.key)) {
        try {
          final leave = _leaveOverride;
          if (leave != null) {
            leave(old.value);
          } else {
            socket.leaveMulticast(_group, old.value);
          }
        } catch (error) {
          myPrint('multicast leave ${old.value.name} failed: $error');
        }
      }
    }

    for (final MapEntry<String, NetworkInterface> current in next.entries) {
      if (_joinedInterfaces.contains(current.key)) continue;
      try {
        final join = _joinOverride;
        if (join != null) {
          join(current.value);
        } else {
          socket.joinMulticast(_group, current.value);
        }
        _joinedInterfaces.add(current.key);
      } catch (error) {
        // Keep it active for per-interface sends and retry membership on the
        // next tick: route setup can lag behind interface enumeration.
        myPrint('multicast join ${current.value.name} failed: $error');
      }
    }
    _interfaces = next;
    return changed;
  }

  Future<void> _sendMulticast(List<int> data) async {
    for (final NetworkInterface interface in List.of(_interfaces.values)) {
      for (final InternetAddress address in interface.addresses) {
        RawDatagramSocket? sender;
        try {
          // Binding the ephemeral sender to this interface selects the correct
          // route without Dart's deprecated multicastInterface property.
          sender = await RawDatagramSocket.bind(address, 0);
          sender.multicastHops = 1;
          sender.send(data, _group, _port);
        } catch (e) {
          myPrint('multicast send ${interface.name} failed: $e');
        } finally {
          sender?.close();
        }
      }
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final Datagram? packet = _socket?.receive();
    if (packet == null) return;
    // Nothing this app sends comes anywhere near that, and an oversized one is
    // not worth decoding to find out.
    if (packet.data.length > maxDiscoveryPacketBytes) return;
    try {
      final dynamic msg = json.decode(utf8.decode(packet.data));
      if (!isSupportedDiscoveryMessage(msg)) return;
      // A stranger's word about itself, held to the same limits the transfer
      // protocol holds a sender to.
      final PeerInfo? peer = validatedPeerInfo(msg, fallbackPort: defaultPort);
      // Our own broadcast comes back to us; ignore it.
      if (peer == null || peer.id == xvDeviceId) return;
      // A neighbour on this same machine would be listed at an address that
      // points back here, so there is nothing to remember about it.
      if (!isReachableAddress(packet.address.address)) return;

      if (msg is Map && msg['t'] == 'bye') {
        _noteDeparture(id: peer.id, address: packet.address.address);
        return;
      }

      _touchDevice(
        id: peer.id,
        name: peer.name.isEmpty ? peer.id : peer.name,
        platform: peer.platform,
        address: packet.address.address,
        port: peer.port,
      );

      // Answer a newcomer at once so it does not wait for the next cycle.
      if (msg is Map && msg['t'] == 'query') {
        // Reply to the UDP source port. The port inside the payload is HTTP.
        _sendTo('announce', packet.address, packet.port);
      }
    } catch (e) {
      myPrint('bad discovery packet from ${packet.address.address}: $e');
    }
  }

  void _touchDevice({
    required String id,
    required String name,
    required String platform,
    required String address,
    required int port,
  }) {
    final int index = xvDevices.indexWhere((d) => d.id == id);
    if (index < 0) {
      if (maxTransientDevices <= 0) return;
      final DateTime now = xvNow();
      if (!_admitNewPeer(address, now)) return;
      final List<Device> transient = xvDevices
          .where((device) => !device.manual && !device.trusted)
          .toList();
      if (transient.length >= maxTransientDevices) {
        transient.sort(
          (a, b) => (a.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0))
              .compareTo(b.lastSeen ?? DateTime.fromMillisecondsSinceEpoch(0)),
        );
        xvDevices.remove(transient.first);
      }
      xvDevices.add(
        Device(
          id: id,
          name: name,
          platform: platform,
          address: address,
          port: port,
          lastSeen: now,
        ),
      );
    } else {
      final Device device = xvDevices[index];
      // A record the user typed themselves is believed only from the address it
      // is listed at — the same rule a bye is held to two functions down.
      //
      // An id travels in clear text in every announce, five seconds apart, so
      // anybody on the subnet can put a listed id in a packet of their own. For a
      // manual device that packet used to rewrite the address the user entered by
      // hand (SPEC 5.4 says only they change it) and mark the row alive on the
      // strength of it, which is enough to send the next transfer somewhere else
      // entirely. The HTTP poll keeps such a row honest anyway, so nothing is
      // lost by ignoring the packet outright.
      if (device.manual && device.address != address) {
        myPrint(
          'announce for ${device.name} from $address, '
          'listed by hand at ${device.address}',
        );
        return;
      }
      device.name = name;
      device.platform = platform;
      device.address = address;
      device.port = port;
      device.lastSeen = xvNow();
      // It is back, whatever it said last time.
      device.departedAt = null;
    }
    _scheduleDevicesChanged();
  }

  // A device saying it is leaving. It never creates a record — an unknown
  // device leaving is nothing to show — and it is only believed from the
  // address the device is already listed at, so a stranger cannot blank out a
  // row by putting somebody else's id in a packet.
  //
  // Manual devices are included: the poller would find out within ten seconds
  // anyway, and it puts the row back on the next answer, so the worst a forged
  // packet buys is one polling interval of a row that says offline early.
  void _noteDeparture({required String id, required String address}) {
    final int index = xvDevices.indexWhere((d) => d.id == id);
    if (index < 0) return;
    final Device device = xvDevices[index];
    if (device.address != address) {
      // Worth a line: a device with two interfaces can leave from an address
      // its record has never seen, and the row then quietly waits out the
      // timeout instead of turning grey at once.
      myPrint(
        'bye for ${device.name} from $address, listed at ${device.address}',
      );
      return;
    }
    device.lastSeen = lastSeenAfterBye(xvNow());
    device.departedAt = xvNow();
    _scheduleDevicesChanged();
  }

  bool _admitNewPeer(String source, DateTime now) {
    final DateTime? started = _admissionWindowStarted;
    if (started == null || now.difference(started) >= admissionWindow) {
      _admissionWindowStarted = now;
      _newPeersInWindow = 0;
      _newPeersBySource.clear();
    }
    final int fromSource = _newPeersBySource[source] ?? 0;
    if (_newPeersInWindow >= maxNewPeersPerWindow ||
        fromSource >= maxNewPeersPerSource) {
      return false;
    }
    _newPeersInWindow++;
    _newPeersBySource[source] = fromSource + 1;
    return true;
  }

  void _scheduleDevicesChanged() {
    if (_deviceUpdateTimer != null) return;
    _deviceUpdateTimer = Timer(uiUpdateInterval, () {
      _deviceUpdateTimer = null;
      devicesChanged();
    });
  }

  @visibleForTesting
  void touchDeviceForTesting({
    required String id,
    required String address,
    String name = '',
    String platform = '',
    int port = defaultPort,
  }) => _touchDevice(
    id: id,
    name: name.isEmpty ? id : name,
    platform: platform,
    address: address,
    port: port,
  );

  @visibleForTesting
  void noteDepartureForTesting({required String id, required String address}) =>
      _noteDeparture(id: id, address: address);

}

final DiscoveryService discovery = DiscoveryService();

// What asking a manual device who it is came back with. Three answers rather
// than a yes and a no, because a device that is switched off and a device that
// has become somebody else are different news and deserve different sentences:
// one boolean told the user their trust relationship had broken every time a
// laptop was merely closed.
enum IdentityCheck { confirmed, changed, unreachable }

// Devices behind a router never hear our broadcast and never answer one, so
// their reachability is probed over HTTP instead — the very channel the files
// will take, firewalls included (SPEC 5.4).
class ManualPoller {
  final Duration timeout;
  Timer? _timer;
  late final HttpClient _client;
  bool _polling = false;

  ManualPoller({this.timeout = const Duration(seconds: manualPollTimeoutSec)}) {
    _client = HttpClient()..connectionTimeout = timeout;
  }

  // A pass is in flight right now.
  bool get polling => _polling;

  // The periodic pass is scheduled. Asked before starting, so a caller driven by
  // lifecycle events does not restart the timer — and fire an immediate pass —
  // every time one arrives.
  bool get running => _timer != null;

  void start() {
    stop();
    _timer = Timer.periodic(
      const Duration(seconds: manualPollSec),
      (_) => _pollAll(),
    );
    _pollAll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _pollAll() async {
    if (_polling) return;
    _polling = true;
    try {
      // This pass runs whenever the list is on screen, discovery up or down, so
      // it is also where a row nothing keeps honest is let go of.
      forgetStaleDevices();
      // All of them at once. Asked one after another, a pass costs one timeout
      // per silent device — and a device that is switched off is silent, not
      // refusing — so a handful of them stretches the pass past the window
      // every device is judged by, and live ones start blinking offline.
      await Future.wait(
        xvDevices.where((d) => d.manual).map(_pollOne).toList(),
      );
    } finally {
      _polling = false;
    }
  }

  Future<void> _pollOne(Device device) async {
    final Map<String, dynamic>? info = await _ask(device.address, device.port);
    if (info == null) return;
    final PeerInfo? peer = validatedPeerInfo(info, fallbackPort: device.port);
    if (peer == null || peer.id != device.id) {
      // DHCP may have handed the saved address to somebody else, or the answer
      // is not one this protocol can use. Keep the original identity/trust
      // record but never mark it reachable.
      device.lastSeen = null;
      devicesChanged();
      return;
    }
    if (peer.name.isNotEmpty) device.name = peer.name;
    if (peer.platform.isNotEmpty) device.platform = peer.platform;
    device.lastSeen = xvNow();
    // It answers, so whatever it said on the way out is history.
    device.departedAt = null;
    devicesChanged();
  }

  Future<void> pollNow() => _pollAll();

  // Who answered at a manual device's address, before anything is sent to it.
  //
  // The identity is only ever called changed when a valid identity was read and
  // it differs — DHCP handing the saved address to somebody else, which is the
  // case this check exists for. Everything else is a device we could not reach:
  // a closed port, a timeout, and an answer that is not a usable /info too,
  // because unreadable bytes are no evidence about who lives there. Claiming a
  // broken trust relationship on that would be the same overreach in reverse.
  Future<IdentityCheck> verifyIdentity(Device device) async {
    final PeerInfo? peer = validatedPeerInfo(
      await _ask(device.address, device.port),
      fallbackPort: device.port,
    );
    if (peer == null || peer.id != device.id) {
      // Neither outcome proves the device is there, so neither leaves it
      // looking reachable.
      device.lastSeen = null;
      devicesChanged();
      return peer == null ? IdentityCheck.unreachable : IdentityCheck.changed;
    }
    device.lastSeen = xvNow();
    device.departedAt = null;
    return IdentityCheck.confirmed;
  }

  // '192.168.1.10' or '192.168.1.10:15353'
  Future<bool> addByAddress(String input) async {
    final String value = input.trim();
    final int colon = value.lastIndexOf(':');
    final String host = (colon < 0 ? value : value.substring(0, colon)).trim();
    final int? explicitPort = colon < 0
        ? null
        : int.tryParse(value.substring(colon + 1));
    if (host.isEmpty ||
        InternetAddress.tryParse(host) == null ||
        (explicitPort != null && (explicitPort < 1 || explicitPort > 65535)) ||
        (colon >= 0 && explicitPort == null)) {
      return false;
    }
    final int port = explicitPort ?? currentPort;

    final Map<String, dynamic>? info = await _ask(host, port);
    final PeerInfo? peer = validatedPeerInfo(info, fallbackPort: port);
    if (peer == null || peer.id == xvDeviceId) return false;

    final int index = xvDevices.indexWhere((d) => d.id == peer.id);
    if (index >= 0) {
      final Device device = xvDevices[index];
      device.address = host;
      device.port = port;
      device.manual = true;
      device.lastSeen = xvNow();
      device.departedAt = null;
    } else {
      xvDevices.add(
        Device(
          id: peer.id,
          name: peer.name.isEmpty ? host : peer.name,
          platform: peer.platform,
          address: host,
          port: port,
          manual: true,
          lastSeen: xvNow(),
        ),
      );
    }
    await saveSettings();
    devicesChanged();
    return true;
  }

  // One deadline over the whole exchange on top of the per-phase ones: a slow
  // connect, slow headers and a slow body must not add up into a wait no poll
  // is worth. Whatever it is doing, it has failed by then.
  Future<Map<String, dynamic>?> _ask(String host, int port) =>
      _askWithin(host, port).timeout(timeout * 3, onTimeout: () => null);

  Future<Map<String, dynamic>?> _askWithin(String host, int port) async {
    if (host.isEmpty) return null;
    try {
      final HttpClientRequest req = await _client
          .getUrl(Uri.http('$host:$port', '$apiPrefix/info'))
          .timeout(timeout);
      final HttpClientResponse resp = await req.close().timeout(timeout);
      if (resp.statusCode != HttpStatus.ok) {
        // An error body holds nothing worth having, and reading one that never
        // ends is what used to stop the poller for the rest of the run.
        await _discard(resp);
        return null;
      }
      final List<int> bytes = await readBoundedControlBytes(
        resp,
        limit: maxInfoBodyBytes,
        inactivityTimeout: timeout,
        totalTimeout: timeout,
        tooLarge: () => const FormatException('info body too large'),
        inactivityExpired: () => TimeoutException('info body stopped', timeout),
        totalExpired: () => TimeoutException('info body deadline', timeout),
      );
      final dynamic decoded = json.decode(
        utf8.decode(bytes, allowMalformed: false),
      );
      return decoded is Map ? decoded.cast<String, dynamic>() : null;
    } catch (e) {
      myPrint('poll $host:$port failed: $e');
      return null;
    }
  }

  // Drop the connection instead of reading a body nobody wants: detaching the
  // socket ends it whether or not the peer ever intended to finish sending.
  Future<void> _discard(HttpClientResponse response) async {
    try {
      final Socket socket = await response.detachSocket().timeout(timeout);
      socket.destroy();
    } catch (e) {
      myPrint('cannot drop the response socket: $e');
    }
  }
}

final ManualPoller manualPoller = ManualPoller();
