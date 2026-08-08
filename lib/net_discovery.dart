import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'globals.dart';

// UDP presence on the local subnet. Broadcast never crosses a router, so
// devices behind one are added by hand instead (SPEC 5.2, 5.4).
class DiscoveryService {
  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  int _port = 0;

  bool get running => _socket != null;

  Future<bool> start() async {
    await stop();
    _port = currentPort;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        reuseAddress: true,
        reusePort: !Platform.isWindows,
      );
      _socket!.broadcastEnabled = true;
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
  }

  void _tick() {
    _broadcast('announce');
    _forgetStaleDevices();
    // Going offline is a silent event: nothing arrives to signal it. Without a
    // nudge here the list would keep showing a dead device as reachable.
    devicesChanged();
  }

  Map<String, dynamic> _payload(String type) => {
        't': type,
        'id': xvDeviceId,
        'name': xvDeviceName,
        'platform': xvPlatform,
        'port': currentPort,
      };

  void _broadcast(String type) {
    final RawDatagramSocket? socket = _socket;
    if (socket == null) return;
    final List<int> data = utf8.encode(json.encode(_payload(type)));
    _broadcastTargets().then((targets) {
      for (final InternetAddress target in targets) {
        try {
          socket.send(data, target, _port);
        } catch (e) {
          myPrint('send to ${target.address} failed: $e');
        }
      }
    });
  }

  void _sendTo(String type, InternetAddress address, int port) {
    try {
      _socket?.send(utf8.encode(json.encode(_payload(type))), address, port);
    } catch (e) {
      myPrint('unicast to ${address.address} failed: $e');
    }
  }

  // Every interface gets its own directed broadcast: with several interfaces up,
  // a lone 255.255.255.255 leaves by whichever route the OS picks, and the other
  // networks never hear us. Dart exposes no netmask, so /24 is assumed — true
  // for home and office networks, and the limited broadcast covers the rest.
  Future<List<InternetAddress>> _broadcastTargets() async {
    final Set<String> targets = {'255.255.255.255'};
    try {
      final List<NetworkInterface> interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
        includeLinkLocal: false,
      );
      for (final NetworkInterface iface in interfaces) {
        for (final InternetAddress addr in iface.addresses) {
          final List<String> parts = addr.address.split('.');
          if (parts.length == 4) targets.add('${parts[0]}.${parts[1]}.${parts[2]}.255');
        }
      }
    } catch (e) {
      myPrint('interface list failed: $e');
    }
    return targets.map(InternetAddress.new).toList();
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final Datagram? packet = _socket?.receive();
    if (packet == null) return;
    try {
      final Map<String, dynamic> msg = json.decode(utf8.decode(packet.data));
      final String id = msg['id'] as String? ?? '';
      // Our own broadcast comes back to us; ignore it.
      if (id.isEmpty || id == xvDeviceId) return;

      _touchDevice(
        id: id,
        name: msg['name'] as String? ?? id,
        platform: msg['platform'] as String? ?? '',
        address: packet.address.address,
        port: msg['port'] as int? ?? defaultPort,
      );

      // Answer a newcomer at once so it does not wait for the next cycle.
      if (msg['t'] == 'query') {
        _sendTo('announce', packet.address, msg['port'] as int? ?? _port);
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
      xvDevices.add(Device(
        id: id,
        name: name,
        platform: platform,
        address: address,
        port: port,
        lastSeen: DateTime.now(),
      ));
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
      return seen == null || now.difference(seen).inSeconds > deviceTimeoutSec + 60;
    });
    if (xvDevices.length != before) devicesChanged();
  }
}

final DiscoveryService discovery = DiscoveryService();

// Devices behind a router never hear our broadcast and never answer one, so
// their reachability is probed over HTTP instead — the very channel the files
// will take, firewalls included (SPEC 5.4).
class ManualPoller {
  Timer? _timer;
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(seconds: manualPollTimeoutSec);

  void start() {
    stop();
    _timer = Timer.periodic(const Duration(seconds: manualPollSec), (_) => _pollAll());
    _pollAll();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _pollAll() async {
    for (final Device device in xvDevices.where((d) => d.manual).toList()) {
      final Map<String, dynamic>? info = await _ask(device.address, device.port);
      if (info == null) continue;
      device.name = info['name'] as String? ?? device.name;
      device.platform = info['platform'] as String? ?? device.platform;
      device.lastSeen = DateTime.now();
      devicesChanged();
    }
  }

  // '192.168.1.10' or '192.168.1.10:15353'
  Future<bool> addByAddress(String input) async {
    final int colon = input.lastIndexOf(':');
    final String host = colon < 0 ? input : input.substring(0, colon);
    final int port = colon < 0 ? currentPort : int.tryParse(input.substring(colon + 1)) ?? currentPort;

    final Map<String, dynamic>? info = await _ask(host, port);
    if (info == null) return false;
    final String id = info['id'] as String? ?? '';
    if (id.isEmpty || id == xvDeviceId) return false;

    final int index = xvDevices.indexWhere((d) => d.id == id);
    if (index >= 0) {
      final Device device = xvDevices[index];
      device.address = host;
      device.port = port;
      device.manual = true;
      device.lastSeen = DateTime.now();
    } else {
      xvDevices.add(Device(
        id: id,
        name: info['name'] as String? ?? host,
        platform: info['platform'] as String? ?? '',
        address: host,
        port: port,
        manual: true,
        lastSeen: DateTime.now(),
      ));
    }
    await saveSettings();
    devicesChanged();
    return true;
  }

  Future<Map<String, dynamic>?> _ask(String host, int port) async {
    if (host.isEmpty) return null;
    try {
      final HttpClientRequest req = await _client
          .getUrl(Uri.http('$host:$port', '$apiPrefix/info'))
          .timeout(const Duration(seconds: manualPollTimeoutSec));
      final HttpClientResponse resp =
          await req.close().timeout(const Duration(seconds: manualPollTimeoutSec));
      if (resp.statusCode != HttpStatus.ok) {
        await resp.drain<void>();
        return null;
      }
      return json.decode(await utf8.decoder.bind(resp).join()) as Map<String, dynamic>;
    } catch (e) {
      myPrint('poll $host:$port failed: $e');
      return null;
    }
  }
}

final ManualPoller manualPoller = ManualPoller();
