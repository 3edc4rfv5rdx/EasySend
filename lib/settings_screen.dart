import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'android_helpers.dart';
import 'globals.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<String> _addresses = [];

  @override
  void initState() {
    super.initState();
    _loadAddresses();
  }

  Future<void> _loadAddresses() async {
    final List<String> found = await localAddresses();
    if (mounted) setState(() => _addresses = found);
  }

  // What to type on the other device under "Add device". Tapping an entry
  // copies it, which beats reading digits off one screen onto another.
  Future<void> _showMyAddresses() async {
    await _loadAddresses();
    if (!mounted) return;
    if (_addresses.isEmpty) {
      okInfoBarRed(lw('No network connection'));
      return;
    }
    await showFlatDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: clFill,
        shape: dialogShape,
        title: Text(lw('My IP'), style: tsLarge),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: _addresses.map((a) {
            final String full = '$a:$currentPort';
            return ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(full, style: tsNormal),
              trailing: Icon(Icons.copy, size: 18, color: clFrame),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: full));
                if (context.mounted) Navigator.pop(context);
                okInfoBarGreen(lw('Copied'));
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: dialogButtonStyle,
            child: Text(lw('Ok')),
          ),
        ],
      ),
    );
  }

  // One line per fact instead of a single run-on string: the version, the
  // build and the device id are what gets quoted when something goes wrong.
  Future<void> _showAbout() async {
    await showFlatDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: clFill,
        shape: dialogShape,
        title: Row(
          children: [
            Icon(Icons.info_outline, color: clAccent),
            const SizedBox(width: 8),
            Text('EasySend', style: tsLarge),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _aboutRow(lw('Version'), progVersion),
            _aboutRow(lw('Build'), '$buildNumber'),
            _aboutRow(lw('Author'), progAuthor),
            _aboutRow(lw('Platform'), xvPlatform),
            _aboutRow(lw('Device id'), xvDeviceId),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            style: dialogButtonStyle,
            child: Text(lw('Ok')),
          ),
        ],
      ),
    );
  }

  Widget _aboutRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 110, child: Text('$label:', style: tsSmall)),
        Expanded(child: Text(value, style: tsNormal)),
      ],
    ),
  );

  Future<void> _apply(VoidCallback change) async {
    setState(change);
    await saveSettings();
  }

  Future<void> _editDeviceName() async {
    final String? name = await showInputDialog(
      title: lw('Device name'),
      initial: xdef['Device name'],
    );
    if (name == null || name.isEmpty) return;
    await _apply(() {
      xdef['Device name'] = name;
      xvDeviceName = name;
    });
  }

  // A receive in flight has already planned where every one of its files goes.
  // Moving the folder under it is a question nobody asked the transfer.
  bool get _receiving => xvTransfers.any((t) => t.incoming && t.isRunning);

  Future<void> _editRecvFolder() async {
    if (_receiving) {
      okInfoBarOrange(lw('Cannot change the receive folder during a transfer'));
      return;
    }
    final String? dir = await pickFolder(initialPath: xvRecvDir);
    if (dir == null) return;
    // Asked again: the picker was open long enough for a transfer to arrive.
    if (_receiving) {
      okInfoBarOrange(lw('Cannot change the receive folder during a transfer'));
      return;
    }
    if (!await canWriteInto(dir)) {
      okInfoBarRed(lw('Cannot write into that folder'));
      return;
    }
    await _apply(() {
      xdef['Receive folder'] = dir;
      xvRecvDir = dir;
    });
  }

  Future<void> _editPort() async {
    final String? value = await showInputDialog(
      title: lw('Transfer port'),
      initial: xdef['Port'],
      keyboardType: TextInputType.number,
    );
    if (value == null || value.isEmpty) return;
    final int? port = int.tryParse(value);
    // Below 1024 needs root on Linux; the ephemeral range gets taken at random.
    if (port == null || port < 1024 || port > 65535) {
      okInfoBarRed(lw('Port must be between 1024 and 65535'));
      return;
    }
    await _apply(() => xdef['Port'] = '$port');
  }

  Future<void> _pickFromList({
    required String title,
    required List<String> options,
    required String current,
    required Future<void> Function(String) onPick,
    String Function(String)? labelOf,
  }) async {
    final String? picked = await showFlatDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: clFill,
        shape: dialogShape,
        title: Text(title, style: tsLarge),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(context, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options
                .map(
                  (o) => RadioListTile<String>(
                    value: o,
                    fillColor: WidgetStatePropertyAll<Color>(clText),
                    title: Text(labelOf?.call(o) ?? lw(o), style: tsNormal),
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
    if (picked != null) await onPick(picked);
  }

  @override
  Widget build(BuildContext context) {
    final List<Device> trusted = xvDevices.where((d) => d.trusted).toList();
    return Scaffold(
      backgroundColor: clFon,
      appBar: AppBar(
        title: Text(lw('Settings'), style: const TextStyle(fontSize: fsLarge)),
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: lw('About'),
            onPressed: _showAbout,
          ),
        ],
      ),
      body: ListView(
        children: [
          // Four groups under the same rule-heading the home screen uses: the
          // flat list gave a port and a colour theme the same weight.
          sectionTitle(lw('Device')),
          _tile(
            icon: Icons.badge_outlined,
            title: lw('Device name'),
            value: xdef['Device name'],
            onTap: _editDeviceName,
          ),
          // The folder is a place on this disk, not an address: it belongs with
          // the device rather than with the port it is reached on.
          _tile(
            icon: Icons.folder_outlined,
            title: lw('Receive folder'),
            value: shortPath(xdef['Receive folder']),
            keepTail: true,
            onTap: _editRecvFolder,
          ),
          sectionTitle(lw('Network')),
          _tile(
            icon: Icons.lan_outlined,
            title: lw('Transfer port'),
            value: xdef['Port'],
            onTap: _editPort,
          ),
          _tile(
            icon: Icons.wifi_tethering,
            title: lw('My IP'),
            value: _addresses.isEmpty
                ? lw('No network connection')
                : '${_addresses.first}:$currentPort',
            onTap: _showMyAddresses,
          ),
          _tile(
            icon: Icons.security_outlined,
            title: lw('Network safety'),
            value: lw('Unencrypted local transfer'),
            onTap: () => showNetworkSafetyWarning(context: context),
          ),
          if (Platform.isAndroid)
            SwitchListTile(
              dense: true,
              visualDensity: const VisualDensity(vertical: -2),
              secondary: Icon(
                Icons.notifications_active_outlined,
                color: clText,
              ),
              activeThumbColor: clAccent,
              value: xdef['Receive in background'] == 'true',
              title: Text(lw('Receive in background'), style: tsNormal),
              subtitle: Text(
                lw('Keeps a notification and receives with the screen off'),
                style: tsSmall,
              ),
              onChanged: (v) async {
                if (v && !await ensureNotificationPermission()) {
                  okInfoBarRed(
                    lw(
                      'Notification permission is required for background receiving',
                    ),
                  );
                  return;
                }
                await _apply(() => xdef['Receive in background'] = '$v');
                await androidService.sync();
                // Doze still cuts connections on a long idle unless the app is
                // exempt, so point the user at that setting once.
                if (v) {
                  okInfoBarBlue(
                    lw('Also exclude EasySend from battery optimisation'),
                  );
                }
              },
            ),
          sectionTitle(lw('Application')),
          _tile(
            icon: Icons.language,
            title: lw('Language'),
            value:
                langNames[xdef['Program language']] ?? xdef['Program language'],
            onTap: () => _pickFromList(
              title: lw('Language'),
              options: appLANGUAGES,
              current: xdef['Program language'],
              // Names come from locales.json and are never translated.
              labelOf: (code) => langNames[code] ?? code,
              onPick: (v) async {
                xdef['Program language'] = v;
                await saveSettings();
                await initTranslations();
                rebuildApp();
                if (mounted) setState(() {});
              },
            ),
          ),
          _tile(
            icon: Icons.brightness_6_outlined,
            title: lw('Theme'),
            value: lw(xdef['Color theme']),
            onTap: () => _pickFromList(
              title: lw('Theme'),
              options: appTHEMES,
              current: xdef['Color theme'],
              onPick: (v) async {
                xdef['Color theme'] = v;
                await saveSettings();
                rebuildApp();
                if (mounted) setState(() {});
              },
            ),
          ),
          SwitchListTile(
            dense: true,
            visualDensity: const VisualDensity(vertical: -2),
            secondary: Icon(Icons.exit_to_app, color: clText),
            activeThumbColor: clAccent,
            value: xdef['Ask before exit'] == 'true',
            title: Text(lw('Ask before exit'), style: tsNormal),
            subtitle: Text(
              lw('A running transfer is always asked about'),
              style: tsSmall,
            ),
            onChanged: (v) => _apply(() => xdef['Ask before exit'] = '$v'),
          ),
          sectionTitle('${lw('Trusted devices')} (${trusted.length})'),
          // Nobody trusted yet is a state worth spelling out: the heading alone
          // looks like a list that failed to appear.
          if (trusted.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Text(lw('No trusted devices'), style: tsSmall),
            ),
          ...trusted.map(
            (d) => ListTile(
              dense: true,
              leading: Icon(
                d.platform == 'android' ? Icons.smartphone : Icons.computer,
                color: clText,
              ),
              title: Text(d.name, style: tsNormal),
              // Trust is bound to the id, not to the address, so a device can
              // be trusted with nowhere to reach it — say that instead of
              // leaving the line blank. The port is only worth the room when
              // it is not the one every device is assumed to listen on.
              subtitle: Text(
                d.address.isEmpty
                    ? lw('Address unknown')
                    : d.port == defaultPort
                    ? d.address
                    : '${d.address}:${d.port}',
                style: tsSmall,
              ),
              trailing: IconButton(
                icon: Icon(Icons.close, color: clFrame, size: 20),
                tooltip: lw('Revoke trust'),
                onPressed: () async {
                  final bool yes = await okConfirm(
                    title: lw('Revoke trust'),
                    message:
                        '${lw('Ask again before accepting from this device')}?\n${d.name}',
                  );
                  if (yes) await _apply(() => d.trusted = false);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
    // A path is read from its end; a name, a port or a theme from its start.
    bool keepTail = false,
  }) {
    return ListTile(
      // Tighter than stock: every row here is two short lines, and the default
      // spacing turns a handful of settings into a page of scrolling.
      dense: true,
      visualDensity: const VisualDensity(vertical: -2),
      leading: Icon(icon, color: clText),
      title: Text(title, style: tsNormal),
      subtitle: keepTail
          ? tailText(value)
          : Text(value, style: tsSmall, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: onTap == null
          ? null
          : Icon(Icons.chevron_right, color: clFrame),
    );
  }
}
