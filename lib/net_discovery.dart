import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'android_helpers.dart';
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

// UDP presence on the local subnet. Broadcast never crosses a router, so
// devices behind one are added by hand instead (SPEC 5.2, 5.4).
class DiscoveryService {
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  int _port = 0;
  List<NetworkInterface> _interfaces = const [];
  final InternetAddress _group = InternetAddress(discoveryMulticastGroup);

  bool get running => _socket != null;

  Future<bool> start() async {
    await stop();
    _port = discoveryPort;
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
      _interfaces = await _activeIpv4Interfaces();
      for (final NetworkInterface interface in _interfaces) {
        try {
          _socket!.joinMulticast(_group, interface);
        } catch (e) {
          myPrint('multicast join ${interface.name} failed: $e');
        }
      }
      await setDiscoveryMulticastEnabled(true);
      _socket!.listen(_onEvent);
    } catch (e) {
      myPrint('discovery bind failed on $_port: $e');
      _socket = null;
      return false;
    }
    // Ask everyone to speak up, then keep announcing on a timer.
    _broadcast('query');
    _broadcast('announce');
    _announceTimer = Timer.periodic(
      const Duration(seconds: announceIntervalSec),
      (_) => _tick(),
    );
    myPrint('discovery started on $_port');
    return true;
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _socket?.close();
    _socket = null;
    _interfaces = const [];
    await setDiscoveryMulticastEnabled(false);
  }

  void _tick() {
    _broadcast('announce');
    _forgetStaleDevices();
    // Going offline is a silent event: nothing arrives to signal it. Without a
    // nudge here the list would keep showing a dead device as reachable.
    devicesChanged();
  }

  Map<String, dynamic> _payload(String type) => buildDiscoveryPayload(
    type: type,
    id: xvDeviceId,
    name: xvDeviceName,
    platform: xvPlatform,
    transferPort: currentPort,
  );

  void _broadcast(String type) {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;
    final List<int> data = utf8.encode(json.encode(_payload(type)));
    // Limited broadcast remains as a compatibility fallback. Multicast does
    // not depend on an assumed /24 netmask and is sent on every interface.
    socket.send(data, InternetAddress('255.255.255.255'), _port);
    _sendMulticast(data);
  }

  void _sendTo(String type, InternetAddress address, int port) {
    try {
      _socket?.send(utf8.encode(json.encode(_payload(type))), address, port);
    } catch (e) {
      myPrint('unicast to ${address.address} failed: $e');
    }
  }

  Future<List<NetworkInterface>> _activeIpv4Interfaces() async {
    try {
      return await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
    } catch (e) {
      myPrint('interface list failed: $e');
      return const [];
    }
  }

  Future<void> _sendMulticast(List<int> data) async {
    for (final NetworkInterface interface in _interfaces) {
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
      // A stranger's word about itself, held to the same limits the transfer
      // protocol holds a sender to.
      final PeerInfo? peer = validatedPeerInfo(msg, fallbackPort: defaultPort);
      // Our own broadcast comes back to us; ignore it.
      if (peer == null || peer.id == xvDeviceId) return;
      // A neighbour on this same machine would be listed at an address that
      // points back here, so there is nothing to remember about it.
      if (!isReachableAddress(packet.address.address)) return;

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
      xvDevices.add(
        Device(
          id: id,
          name: name,
          platform: platform,
          address: address,
          port: port,
          lastSeen: DateTime.now(),
        ),
      );
    } else {
      final Device device = xvDevices[index];
      device.name = name;
      device.platform = platform;
      device.address = address;
      device.port = port;
      device.lastSeen = DateTime.now();
    }
    devicesChanged();
  }

  // Devices worth remembering stay in the list while offline; the rest are
  // dropped a minute after going quiet.
  void _forgetStaleDevices() {
    final DateTime now = DateTime.now();
    final int before = xvDevices.length;
    xvDevices.removeWhere((d) {
      if (d.manual || d.trusted) return false;
      final DateTime? seen = d.lastSeen;
      return seen == null ||
          now.difference(seen).inSeconds > deviceTimeoutSec + 60;
    });
    if (xvDevices.length != before) devicesChanged();
  }
}

final DiscoveryService discovery = DiscoveryService();

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

  bool get polling => _polling;

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
      for (final Device device in xvDevices.where((d) => d.manual).toList()) {
        final Map<String, dynamic>? info = await _ask(
          device.address,
          device.port,
        );
        if (info == null) continue;
        final PeerInfo? peer = validatedPeerInfo(info, fallbackPort: device.port);
        if (peer == null || peer.id != device.id) {
          // DHCP may have handed the saved address to somebody else, or the
          // answer is not one this protocol can use. Keep the original
          // identity/trust record but never mark it reachable.
          device.lastSeen = null;
          devicesChanged();
          continue;
        }
        if (peer.name.isNotEmpty) device.name = peer.name;
        if (peer.platform.isNotEmpty) device.platform = peer.platform;
        device.lastSeen = DateTime.now();
        devicesChanged();
      }
    } finally {
      _polling = false;
    }
  }

  Future<void> pollNow() => _pollAll();

  Future<bool> verifyIdentity(Device device) async {
    final Map<String, dynamic>? info = await _ask(device.address, device.port);
    final PeerInfo? peer = validatedPeerInfo(info, fallbackPort: device.port);
    if (peer == null || peer.id != device.id) {
      device.lastSeen = null;
      devicesChanged();
      return false;
    }
    device.lastSeen = DateTime.now();
    return true;
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
      device.lastSeen = DateTime.now();
    } else {
      xvDevices.add(
        Device(
          id: peer.id,
          name: peer.name.isEmpty ? host : peer.name,
          platform: peer.platform,
          address: host,
          port: port,
          manual: true,
          lastSeen: DateTime.now(),
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
      final List<int> bytes = [];
      await for (final List<int> chunk in resp.timeout(timeout)) {
        if (bytes.length + chunk.length > maxInfoBodyBytes) return null;
        bytes.addAll(chunk);
      }
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
