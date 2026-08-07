import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import 'android_helpers.dart';
import 'globals.dart';
import 'net_discovery.dart';
import 'net_sender.dart';
import 'net_server.dart';
import 'settings_screen.dart';

// The whole application is this one screen: picking, devices, progress. No tabs
// and no bottom navigation (SPEC 4).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final List<FileItem> _selected = [];
  Device? _target;
  // True while something is being dragged over the drop zone.
  bool _dragOver = false;

  // One listenable for everything the screen mirrors.
  late final Listenable _netTicks = Listenable.merge([devicesTick, transfersTick, serverTick]);

  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    _startNetwork();
    _listenForShares();
  }

  // "Share -> EasySend" drops straight into the selection, so all that is left
  // is picking a device and pressing Send.
  void _listenForShares() {
    if (!Platform.isAndroid) return;
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _addShared(files);
      // Without this the same files come back every time the app resumes.
      ReceiveSharingIntent.instance.reset();
    });
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      _addShared,
      onError: (Object e) => myPrint('share stream failed: $e'),
    );
  }

  Future<void> _addShared(List<SharedMediaFile> shared) async {
    if (shared.isEmpty) return;
    await _addPaths(shared.map((f) => f.path).toList());
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    androidService.detach();
    receiveServer.stop();
    discovery.stop();
    manualPoller.stop();
    super.dispose();
  }

  Future<void> _startNetwork() async {
    // Ask before the first transfer rather than at the moment files arrive:
    // without storage access the receive folder cannot be written at all.
    await ensureStoragePermission();
    await ensureNotificationPermission();
    androidService.attach();
    await receiveServer.start();
    await discovery.start();
    manualPoller.start();
  }

  // Called after the port may have changed in settings.
  Future<void> _restartNetwork() async {
    await receiveServer.start();
    await discovery.start();
  }

  int get _totalBytes => _selected.fold(0, (sum, f) => sum + f.size);

  bool get _canSend => _selected.isNotEmpty && _target != null && !sender.busy;

  Future<void> _pickFiles() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
    if (result == null) return;
    final List<String> paths = result.files.map((f) => f.path).whereType<String>().toList();
    await _addPaths(paths);
  }

  Future<void> _pickFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;
    await _addPaths([dir]);
  }

  Future<void> _addPaths(List<String> paths) async {
    final List<FileItem> items = await collectFiles(paths);
    if (!mounted) return;
    // Same file picked twice adds nothing.
    final Set<String> known = _selected.map((f) => f.sourcePath ?? f.relativePath).toSet();
    setState(() {
      _selected.addAll(items.where((f) => known.add(f.sourcePath ?? f.relativePath)));
    });
  }

  void _clear() => setState(_selected.clear);

  void _remove(FileItem item) => setState(() => _selected.remove(item));

  Future<void> _addManualDevice() async {
    final String? input = await showInputDialog(
      title: lw('Add device'),
      hint: '192.168.1.10',
    );
    if (input == null || input.isEmpty) return;
    final bool ok = await manualPoller.addByAddress(input);
    if (!mounted) return;
    if (ok) {
      okInfoBarGreen(lw('Device added'));
    } else {
      okInfoBarRed(lw('Device did not answer'));
    }
    setState(() {});
  }

  Future<void> _send() async {
    final Device? target = _target;
    if (target == null || _selected.isEmpty) return;
    final List<FileItem> batch = List<FileItem>.of(_selected);
    setState(_selected.clear);
    await sender.send(peer: target, files: batch);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: clFon,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('EasySend', style: TextStyle(fontSize: fsLarge, fontWeight: fwBold)),
            Text(xvDeviceName, style: TextStyle(fontSize: fsSmall, color: clText)),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: lw('Settings'),
            onPressed: () async {
              final int portBefore = currentPort;
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              if (portBefore != currentPort) await _restartNetwork();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _netTicks,
        builder: (context, _) => CustomScrollView(
          slivers: [
            if (receiveServer.bindError != null)
              SliverToBoxAdapter(child: _buildPortBanner()),
            SliverToBoxAdapter(child: _buildPickRow()),
            SliverToBoxAdapter(child: _buildSelectedHeader()),
            _buildSelectedList(),
            SliverToBoxAdapter(child: _buildDevicesHeader()),
            _buildDeviceList(),
            if (xvTransfers.isNotEmpty)
              SliverToBoxAdapter(child: _sectionTitle(lw('Transfers'))),
            _buildTransferList(),
          ],
        ),
      ),
      bottomNavigationBar: ListenableBuilder(
        listenable: _netTicks,
        builder: (context, _) => _buildSendButton(),
      ),
    );
  }

  // Receiving is down while the port is taken; sending still works, so this is
  // a banner and not a blocking error.
  Widget _buildPortBanner() {
    return Container(
      width: double.infinity,
      color: clRed,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${lw('Port is busy, receiving is off')}: $currentPort',
              style: const TextStyle(color: Colors.white, fontSize: fsSmall),
            ),
          ),
          TextButton(
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
              await _restartNetwork();
              if (mounted) setState(() {});
            },
            child: Text(lw('Settings'), style: const TextStyle(color: Colors.white, fontSize: fsSmall)),
          ),
        ],
      ),
    );
  }

  Widget _buildPickRow() {
    final Widget buttons = Row(
      children: [
        Expanded(child: _pickButton(Icons.insert_drive_file_outlined, lw('File'), _pickFiles)),
        const SizedBox(width: 8),
        Expanded(child: _pickButton(Icons.folder_open, lw('Folder'), _pickFolder)),
      ],
    );

    // Android has no pointer to drag with; there the share menu does this job.
    if (Platform.isAndroid) {
      return Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 4), child: buttons);
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      child: DropTarget(
        // Dropped folders arrive as plain paths, and collectFiles walks them.
        onDragDone: (details) {
          setState(() => _dragOver = false);
          _addPaths(details.files.map((f) => f.path).toList());
        },
        onDragEntered: (_) => setState(() => _dragOver = true),
        onDragExited: (_) => setState(() => _dragOver = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _dragOver ? clSel : Colors.transparent,
            border: Border.all(
              color: _dragOver ? clUpBar : clFrame.withValues(alpha: 0.4),
              width: _dragOver ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              buttons,
              const SizedBox(height: 6),
              Text(lw('or drop files here'), style: tsSmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pickButton(IconData icon, String label, VoidCallback onPressed) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: clText,
        side: BorderSide(color: clFrame),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }

  Widget _buildSelectedHeader() {
    if (_selected.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Text(lw('Nothing selected'), style: tsSmall),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${lw('Selected')}: ${_selected.length} — ${formatBytes(_totalBytes)}',
              style: tsSmall,
            ),
          ),
          TextButton(
            onPressed: _clear,
            style: TextButton.styleFrom(foregroundColor: clText),
            child: Text(lw('Clear'), style: tsSmall),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedList() {
    return SliverList.builder(
      itemCount: _selected.length,
      itemBuilder: (context, index) {
        final FileItem item = _selected[index];
        return ListTile(
          dense: true,
          visualDensity: VisualDensity.compact,
          title: Text(item.relativePath, style: tsNormal, overflow: TextOverflow.ellipsis),
          subtitle: Text(formatBytes(item.size), style: tsSmall),
          trailing: IconButton(
            icon: Icon(Icons.close, color: clFrame, size: 20),
            onPressed: () => _remove(item),
          ),
        );
      },
    );
  }

  Widget _sectionTitle(String text, {Widget? trailing}) {
    return Container(
      width: double.infinity,
      color: clMenu,
      padding: EdgeInsets.fromLTRB(12, trailing == null ? 6 : 0, 4, trailing == null ? 6 : 0),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: TextStyle(fontSize: fsNormal, fontWeight: fwBold, color: clText)),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _buildDevicesHeader() {
    return _sectionTitle(
      lw('Devices'),
      trailing: IconButton(
        icon: Icon(Icons.add, color: clText),
        tooltip: lw('Add device'),
        onPressed: _addManualDevice,
      ),
    );
  }

  Widget _buildDeviceList() {
    // Reachable devices first, then the remembered ones that are away.
    final List<Device> devices = List<Device>.of(xvDevices)
      ..sort((a, b) {
        if (a.online != b.online) return a.online ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    if (devices.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(lw('No devices found'), style: tsSmall),
        ),
      );
    }
    return SliverList.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final Device device = devices[index];
        return ListTile(
          dense: true,
          selected: _target?.id == device.id,
          selectedTileColor: clSel,
          leading: Icon(
            device.platform == 'android' ? Icons.smartphone : Icons.computer,
            color: device.online ? clGreen : clFrame,
          ),
          title: Text(device.name, style: tsNormal),
          subtitle: Text(
            device.address.isEmpty ? lw('No devices found') : '${device.address}:${device.port}',
            style: tsSmall,
          ),
          trailing: device.manual
              ? IconButton(
                  icon: Icon(Icons.delete_outline, color: clFrame),
                  onPressed: () async {
                    xvDevices.remove(device);
                    if (_target?.id == device.id) _target = null;
                    await saveSettings();
                    devicesChanged();
                  },
                )
              : null,
          // A tap only selects: an accidental touch must not start a transfer.
          onTap: device.online ? () => setState(() => _target = device) : null,
        );
      },
    );
  }

  Widget _buildTransferList() {
    // Newest on top.
    final List<TransferSession> list = xvTransfers.reversed.toList();
    return SliverList.builder(
      itemCount: list.length,
      itemBuilder: (context, index) => _buildTransferTile(list[index]),
    );
  }

  Widget _buildTransferTile(TransferSession t) {
    final FileItem? currentFile =
        t.currentIndex < t.files.length ? t.files[t.currentIndex] : null;
    final int? eta = t.etaSeconds;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(t.incoming ? Icons.download : Icons.upload, size: 18, color: clText),
              const SizedBox(width: 6),
              Expanded(child: Text(t.peerName, style: tsNormal, overflow: TextOverflow.ellipsis)),
              if (t.isRunning)
                IconButton(
                  icon: Icon(Icons.close, color: clRed, size: 20),
                  tooltip: lw('Cancel'),
                  onPressed: () => sender.cancel(),
                ),
              // Only the files that did not make it are sent again.
              if (t.canRetry)
                TextButton.icon(
                  icon: Icon(Icons.refresh, size: 18, color: clText),
                  label: Text(lw('Retry'), style: tsSmall),
                  style: TextButton.styleFrom(foregroundColor: clText),
                  onPressed: () async {
                    if (!await sender.retryFailed(t)) {
                      okInfoBarRed(lw('Device is not reachable'));
                    }
                  },
                ),
            ],
          ),
          // One bar for the whole transfer, counted in bytes (SPEC 3.3).
          LinearProgressIndicator(
            value: t.progress,
            backgroundColor: clFrame.withValues(alpha: 0.3),
            color: t.status == TransferStatus.failed ? clRed : clUpBar,
          ),
          const SizedBox(height: 4),
          Text(_transferSubtitle(t, currentFile, eta), style: tsSmall),
        ],
      ),
    );
  }

  String _transferSubtitle(TransferSession t, FileItem? currentFile, int? eta) {
    switch (t.status) {
      case TransferStatus.done:
        return '${lw('Done')}: ${t.doneCount} — ${formatBytes(t.bytesTotal)}';
      case TransferStatus.partial:
        return '${lw('Received')} ${t.doneCount}/${t.files.length}, ${lw('failed')}: ${t.failedCount}';
      case TransferStatus.cancelled:
        return lw('Cancelled');
      case TransferStatus.failed:
        return '${lw('Error')}: ${t.error ?? ''}';
      case TransferStatus.pending:
      case TransferStatus.active:
        final String name = currentFile?.name ?? '';
        final String counter = '${t.currentIndex + 1}/${t.files.length}';
        final String speed = formatSpeed(t.speed);
        final String left = eta == null ? '' : ' — ${formatDuration(eta)}';
        return '$name  $counter  $speed$left';
    }
  }

  Widget _buildSendButton() {
    final String label = _selected.isEmpty
        ? lw('Send')
        : '${lw('Send')}  ${_selected.length} — ${formatBytes(_totalBytes)}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _canSend ? _send : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: clUpBar,
              foregroundColor: clText,
              disabledBackgroundColor: clFrame.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            child: Text(label, style: TextStyle(fontSize: fsLarge, color: clText)),
          ),
        ),
      ),
    );
  }
}
