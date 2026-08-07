import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'android_helpers.dart';
import 'globals.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
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

  Future<void> _editRecvFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    await _apply(() {
      xdef['Receive folder'] = dir;
      xvRecvDir = dir;
    });
  }

  Future<void> _editPort() async {
    final String? value = await showInputDialog(
      title: lw('Port'),
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
    final String? picked = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: clFon,
        shape: dialogShape,
        title: Text(title, style: tsLarge),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (v) => Navigator.pop(context, v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options
                .map((o) => RadioListTile<String>(
                      value: o,
                      activeColor: clUpBar,
                      title: Text(labelOf?.call(o) ?? lw(o), style: tsNormal),
                    ))
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
      appBar: AppBar(title: Text(lw('Settings'), style: const TextStyle(fontSize: fsLarge))),
      body: ListView(
        children: [
          _tile(
            icon: Icons.badge_outlined,
            title: lw('Device name'),
            value: xdef['Device name'],
            onTap: _editDeviceName,
          ),
          _tile(
            icon: Icons.folder_outlined,
            title: lw('Receive folder'),
            value: xdef['Receive folder'],
            // Android hands out folder access through the system picker only,
            // and the default Download/EasySend is what people expect anyway.
            onTap: Platform.isAndroid ? null : _editRecvFolder,
          ),
          _tile(
            icon: Icons.lan_outlined,
            title: lw('Port'),
            value: xdef['Port'],
            onTap: _editPort,
          ),
          _tile(
            icon: Icons.language,
            title: lw('Language'),
            value: xdef['Program language'],
            onTap: () => _pickFromList(
              title: lw('Language'),
              options: appLANGUAGES,
              current: xdef['Program language'],
              // Language codes are shown as-is: they are not words to translate.
              labelOf: (code) => code,
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
          if (Platform.isAndroid)
            SwitchListTile(
              secondary: Icon(Icons.notifications_active_outlined, color: clText),
              activeThumbColor: clUpBar,
              value: xdef['Receive in background'] == 'true',
              title: Text(lw('Receive in background'), style: tsNormal),
              subtitle: Text(lw('Keeps a notification and receives with the screen off'), style: tsSmall),
              onChanged: (v) async {
                await _apply(() => xdef['Receive in background'] = '$v');
                await androidService.sync();
                // Doze still cuts connections on a long idle unless the app is
                // exempt, so point the user at that setting once.
                if (v) okInfoBarBlue(lw('Also exclude EasySend from battery optimisation'));
              },
            ),
          const Divider(),
          _sectionTitle('${lw('Trusted devices')} (${trusted.length})'),
          ...trusted.map((d) => ListTile(
                dense: true,
                leading: Icon(
                  d.platform == 'android' ? Icons.smartphone : Icons.computer,
                  color: clText,
                ),
                title: Text(d.name, style: tsNormal),
                subtitle: Text(d.address, style: tsSmall),
                trailing: IconButton(
                  icon: Icon(Icons.delete_outline, color: clRed),
                  tooltip: lw('Revoke trust'),
                  onPressed: () => _apply(() => d.trusted = false),
                ),
              )),
          const Divider(),
          _tile(
            icon: Icons.info_outline,
            title: lw('About'),
            value: 'EasySend $progVersion+$buildNumber',
            onTap: () => okInfo('EasySend $progVersion+$buildNumber\n$progAuthor'),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String text) => Container(
        width: double.infinity,
        color: clMenu,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(text, style: TextStyle(fontSize: fsNormal, fontWeight: fwBold, color: clText)),
      );

  Widget _tile({
    required IconData icon,
    required String title,
    required String value,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: clText),
      title: Text(title, style: tsNormal),
      subtitle: Text(value, style: tsSmall, overflow: TextOverflow.ellipsis),
      onTap: onTap,
      trailing: onTap == null ? null : Icon(Icons.chevron_right, color: clFrame),
    );
  }
}
