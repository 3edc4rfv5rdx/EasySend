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
    final String? dir = await pickFolder();
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

  // Clear resets the whole choice, files and target alike.
  void _clear() => setState(() {
        _selected.clear();
        _target = null;
      });

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
        backgroundColor: clFill,
        side: BorderSide(color: clFrame),
        padding: const EdgeInsets.symmetric(vertical: 6),
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
            style: TextButton.styleFrom(
              foregroundColor: clText,
              backgroundColor: clFill,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: clFrame),
              ),
            ),
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
          subtitle: Text(
            item.modified == null
                ? formatBytes(item.size)
                : '${formatBytes(item.size)}   ${formatDateTime(item.modified!)}',
            style: tsSmall,
          ),
          trailing: IconButton(
            icon: Icon(Icons.close, color: clFrame, size: 20),
            onPressed: () => _remove(item),
          ),
        );
      },
    );
  }

  // Same strip for every section: a trailing button must not make one of them
  // taller than the rest.
  Widget _sectionTitle(String text, {Widget? trailing}) {
    return Container(
      width: double.infinity,
      color: clMenu,
      padding: const EdgeInsets.fromLTRB(12, 4, 24, 4),
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
      trailing: Tooltip(
        message: lw('Add device'),
        child: InkWell(
          onTap: _addManualDevice,
          customBorder: const CircleBorder(),
          child: CircleAvatar(
            radius: 12,
            backgroundColor: clText,
            child: Icon(Icons.add, color: clFill, size: 18),
          ),
        ),
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
        final bool isTarget = _target?.id == device.id;
        return ListTile(
          dense: true,
          selected: isTarget,
          selectedTileColor: clSel,
          // Reachable devices get an inverted badge: a filled circle with the
          // icon punched out in the background colour. Two shades of the same
          // icon were impossible to tell apart at a glance.
          leading: _deviceIcon(device),
          title: Text(device.name, style: tsNormal),
          // Spelled out as well as coloured: an unreachable device cannot be
          // picked, and that should not look like an unexplained dead row.
          subtitle: Text(
            [
              if (device.address.isNotEmpty) '${device.address}:${device.port}',
              if (!device.online) lw('offline'),
            ].join('   '),
            style: TextStyle(
              fontSize: fsSmall,
              color: device.online ? clText : clFrame,
            ),
          ),
          trailing: device.manual
              ? IconButton(
                  icon: Icon(Icons.close, color: clFrame, size: 20),
                  tooltip: lw('Remove'),
                  onPressed: () async {
                    // Getting it back means typing the address again.
                    final bool yes = await okConfirm(
                      title: lw('Remove'),
                      message: '${lw('Remove this device')}?\n${device.name}',
                    );
                    if (!yes) return;
                    xvDevices.remove(device);
                    if (_target?.id == device.id) _target = null;
                    await saveSettings();
                    devicesChanged();
                  },
                )
              : null,
          // A tap only selects, never sends: an accidental touch must not start
          // a transfer. Tapping the selected device again clears the choice.
          onTap: device.online
              ? () => setState(() => _target = _target?.id == device.id ? null : device)
              : null,
        );
      },
    );
  }

  Widget _deviceIcon(Device device) {
    final IconData icon =
        device.platform == 'android' ? Icons.smartphone : Icons.computer;
    if (!device.online) {
      return Icon(icon, color: clFrame);
    }
    return CircleAvatar(
      radius: 16,
      backgroundColor: clGreen,
      child: Icon(icon, color: clFon, size: 18),
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
          Row(
            children: [
              // One bar for the whole transfer, counted in bytes (SPEC 3.3).
              // Thick and bright on purpose: readable across the room.
              Expanded(
                child: LinearProgressIndicator(
                  value: t.progress,
                  minHeight: 12,
                  borderRadius: BorderRadius.circular(6),
                  backgroundColor: clFrame.withValues(alpha: 0.3),
                  color: _progressColor(t),
                ),
              ),
              // The slot is always there, empty while the transfer runs, so the
              // bar keeps its width and nothing jumps when it finishes.
              SizedBox(
                width: 32,
                height: 24,
                child: t.isRunning
                    ? null
                    : IconButton(
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints.tightFor(width: 32, height: 24),
                        icon: Icon(Icons.close, color: clFrame, size: 20),
                        tooltip: lw('Remove'),
                        onPressed: () {
                          xvTransfers.remove(t);
                          transfersChanged();
                        },
                      ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(_transferSubtitle(t, currentFile, eta), style: tsSmall),
        ],
      ),
    );
  }

  // The bar carries the outcome at a glance: red went wrong, grey was stopped
  // on purpose, green finished.
  Color _progressColor(TransferSession t) {
    switch (t.status) {
      case TransferStatus.failed:
        return clRed;
      case TransferStatus.cancelled:
        return clFrame;
      case TransferStatus.done:
        return clGreen;
      case TransferStatus.partial:
      case TransferStatus.pending:
      case TransferStatus.active:
        return clProgress;
    }
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

  TransferSession? get _running {
    for (final TransferSession t in xvTransfers) {
      if (t.isRunning) return t;
    }
    return null;
  }

  // While a transfer runs, the main button turns into Stop: one obvious place
  // to interrupt it, in either direction.
  Future<void> _stop() async {
    final TransferSession? active = _running;
    if (active == null) return;
    if (active.incoming) {
      await receiveServer.cancelCurrent();
    } else {
      await sender.cancel();
    }
  }

  Widget _buildSendButton() {
    final TransferSession? active = _running;
    final bool stopping = active != null;
    final String label = stopping
        ? lw('Stop')
        : _selected.isEmpty
            ? lw('Send')
            : '${lw('Send')}  ${_selected.length} — ${formatBytes(_totalBytes)}';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(48, 6, 48, 10),
        child: SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: stopping
                ? _stop
                : _canSend
                    ? _send
                    : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: stopping ? clRed : clUpBar,
              foregroundColor: clText,
              disabledBackgroundColor: clFrame.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: fsLarge,
                color: stopping ? Colors.white : clText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
