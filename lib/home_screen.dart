import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:window_manager/window_manager.dart';

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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final List<FileItem> _selected = [];
  // Paths of the last batch handed to the sender, so the list can be brought
  // back after it emptied itself. Only paths: the files are re-read on restore,
  // so sizes and dates are current and vanished ones simply drop out.
  List<String> _lastSentPaths = [];
  Device? _target;
  // True while something is being dragged over the drop zone.
  bool _dragOver = false;
  // The selection has its own scroll area, so it needs its own controller for
  // the scrollbar to attach to.
  final ScrollController _selectedScroll = ScrollController();

  // One listenable for everything the screen mirrors.
  late final Listenable _netTicks = Listenable.merge([devicesTick, transfersTick, serverTick]);

  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    devicesTick.addListener(_dropOfflineTarget);
    transfersTick.addListener(_pruneSentFiles);
    _startNetwork();
    _listenForShares();
  }

  // The picked list doubles as the queue: a file that arrived and passed its
  // checksum leaves it, so whatever remains is exactly what did not get there.
  void _pruneSentFiles() {
    if (_selected.isEmpty || !mounted) return;
    final int before = _selected.length;
    _selected.removeWhere((f) => f.done);
    if (_selected.length != before) setState(() {});
  }

  // A device that went away must not stay highlighted as the chosen target,
  // and Send must not stay enabled for it.
  void _dropOfflineTarget() {
    final Device? target = _target;
    if (target == null || !mounted) return;
    final int index = xvDevices.indexWhere((d) => d.id == target.id);
    if (index < 0 || !xvDevices[index].online) {
      setState(() => _target = null);
    }
  }

  // With background receiving off, a backgrounded app must stop announcing and
  // stop listening: otherwise it keeps advertising itself as reachable while
  // the user believes it is closed (SPEC 7).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Platform.isAndroid) return;
    if (xdef['Receive in background'] == 'true') return;

    switch (state) {
      case AppLifecycleState.resumed:
        _startNetwork();
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        // A transfer in flight is not interrupted by leaving the screen.
        if (sender.busy || xvTransfers.any((t) => t.isRunning)) return;
        discovery.stop();
        manualPoller.stop();
        receiveServer.stop();
      case AppLifecycleState.inactive:
        break;
    }
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
    WidgetsBinding.instance.removeObserver(this);
    devicesTick.removeListener(_dropOfflineTarget);
    transfersTick.removeListener(_pruneSentFiles);
    _shareSub?.cancel();
    _selectedScroll.dispose();
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
    await ensureRecvDir();
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

  // Pressable with a piece missing too, so the button can say which one it is
  // instead of sitting there grey and mute.
  bool get _armed => !sender.busy;

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
    // Two ways of picking the same thing twice: the same file on disk, and two
    // files that would land on the same place at the far end. The second one
    // catches a file added on its own and again inside its folder, which the
    // receiver would otherwise unpack as 'photo (1).jpg'.
    final Set<String> knownSources =
        _selected.map((f) => f.sourcePath).whereType<String>().toSet();
    final Set<String> knownTargets = _selected.map(_targetKey).toSet();
    final List<FileItem> fresh = items.where((f) {
      final String? source = f.sourcePath;
      // Both sets are asked before the verdict: && would skip the second add.
      final bool newSource = source == null || knownSources.add(source);
      final bool newTarget = knownTargets.add(_targetKey(f));
      return newSource && newTarget;
    }).toList();

    setState(() => _selected.addAll(fresh));
    final int skipped = items.length - fresh.length;
    if (skipped > 0) okInfoBarOrange('${lw('Duplicates skipped')}: $skipped');
  }

  // What the receiver will see: same place, same size means the same file.
  static String _targetKey(FileItem f) => '${f.relativePath}|${f.size}';

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

  // Closing the app has to release the port and stop announcing, otherwise
  // peers keep seeing this device for another twenty seconds.
  Future<void> _exitApp() async {
    final bool running = xvTransfers.any((t) => t.isRunning);
    // An interrupted transfer is always worth a question; an idle app is only
    // worth one if the user asked to be asked.
    if (running || xdef['Ask before exit'] == 'true') {
      final bool yes = await okConfirm(
        title: lw('Exit'),
        message: running
            ? '${lw('A transfer is running')}. ${lw('Exit the application')}?'
            : '${lw('Exit the application')}?',
      );
      if (!yes) return;
    }

    await receiveServer.stop();
    await discovery.stop();
    manualPoller.stop();

    if (Platform.isAndroid) {
      await SystemNavigator.pop();
    } else {
      await windowManager.close();
    }
  }

  // Send with nothing chosen: one reachable device is no choice at all, so it
  // becomes the target and the transfer starts; with several, ask. An empty
  // selection is asked about first, being the earlier of the two steps.
  Future<void> _sendOrPickTarget() async {
    if (_selected.isEmpty) {
      // With neither piece in place, naming only the files would leave the
      // second step to be discovered on the next press.
      okInfoBarOrange(lw(_target == null
          ? 'Add files and pick a device'
          : 'Add files or folders to send'));
      return;
    }
    if (_target == null) {
      final List<Device> reachable = xvDevices.where((d) => d.online).toList();
      if (reachable.length != 1) {
        okInfoBarOrange(lw('Select a target device'));
        return;
      }
      setState(() => _target = reachable.first);
    }
    await _send();
  }

  Future<void> _send() async {
    final Device? target = _target;
    if (target == null || _selected.isEmpty) return;
    final List<FileItem> batch = List<FileItem>.of(_selected);
    setState(() {
      _lastSentPaths = batch.map((f) => f.sourcePath).whereType<String>().toList();
    });
    // Files leave the list one by one as they land, via _pruneSentFiles.
    final TransferStatus status = await sender.send(peer: target, files: batch);
    if (!mounted) return;
    // Everything arrived: drop the target too, so the next send starts clean.
    // After a partial or failed one it stays selected, together with the files
    // still in the list, ready for another attempt.
    if (status == TransferStatus.done) setState(() => _target = null);
  }

  // Bring the last batch back into the list, re-reading it from disk.
  Future<void> _restoreLastBatch() async {
    if (_lastSentPaths.isEmpty) return;
    final List<FileItem> items = await collectFiles(_lastSentPaths);
    if (!mounted) return;
    if (items.isEmpty) {
      okInfoBarRed(lw('Files are no longer there'));
      return;
    }
    setState(() {
      _selected
        ..clear()
        ..addAll(items);
    });
    if (items.length != _lastSentPaths.length) {
      okInfoBarOrange(lw('Some files are no longer there'));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: clFon,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: lw('Exit'),
          onPressed: _exitApp,
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('EasySend', style: TextStyle(fontSize: fsLarge, fontWeight: fwBold)),
            Text(xvDeviceName, style: TextStyle(fontSize: fsSmall, color: clUpBarText)),
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
            SliverToBoxAdapter(child: _buildTransfersHeader()),
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
      color: clError,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.error_outline, color: onColor(clError), size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${lw('Port is busy, receiving is off')}: $currentPort',
              style: TextStyle(color: onColor(clError), fontSize: fsSmall),
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
            child: Text(lw('Settings'), style: TextStyle(color: onColor(clError), fontSize: fsSmall)),
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
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: _dragOver ? clSel : Colors.transparent,
            border: Border.all(
              color: _dragOver ? clAccent : clFrame.withValues(alpha: 0.4),
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
        backgroundColor: clButton,
        side: BorderSide(color: clFrame),
        // Material 3 would make this a stadium; every button in the app is the
        // same rounded rectangle instead.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(btnRadius)),
        padding: const EdgeInsets.symmetric(vertical: 6),
      ),
    );
  }

  Widget _buildSelectedHeader() {
    final bool empty = _selected.isEmpty;
    // The same heading as Devices and Transfers, so the screen has one kind of
    // section and not two; the count and the size ride in the heading itself.
    final String title = empty
        ? lw('Nothing selected')
        : '${lw('Selected')}: ${_selected.length} — ${formatBytes(_totalBytes)}';

    Widget? trailing;
    if (empty && _lastSentPaths.isNotEmpty) {
      trailing = TextButton.icon(
        onPressed: _restoreLastBatch,
        icon: Icon(Icons.restore, size: 16, color: clText),
        label: Text(lw('Restore'), style: tsSmall),
        style: _headerButtonStyle,
      );
    } else if (!empty) {
      trailing = TextButton(
        onPressed: _clear,
        style: _headerButtonStyle,
        child: Text(lw('Clear'), style: tsSmall),
      );
    }

    return sectionTitle(title, trailing: trailing, trailingToEdge: true);
  }

  ButtonStyle get _headerButtonStyle => TextButton.styleFrom(
        foregroundColor: clText,
        backgroundColor: clButton,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(btnRadius),
          side: BorderSide(color: clFrame),
        ),
      );

  Widget _buildSelectedList() {
    if (_selected.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());

    // A folder full of files must not push the devices and the transfers off
    // the screen: the selection keeps to a third of the height and scrolls
    // inside itself.
    final double maxHeight = MediaQuery.sizeOf(context).height / 3;
    return SliverToBoxAdapter(
      child: Container(
        // The bottom margin keeps the frame off the Devices strip below it.
        margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
        constraints: BoxConstraints(maxHeight: maxHeight),
        decoration: BoxDecoration(
          border: Border.all(color: clFrame.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Scrollbar(
          controller: _selectedScroll,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _selectedScroll,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
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
                      : '${formatDateTime(item.modified!)}   ${formatBytes(item.size)}',
                  style: tsSmall,
                ),
                // Checking what is about to be sent should not mean leaving
                // the app and finding the file by hand.
                onTap: () => _openItem(item),
                trailing: IconButton(
                  icon: Icon(Icons.close, color: clFrame, size: 20),
                  onPressed: () => _remove(item),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _openItem(FileItem item) async {
    final String? path = item.sourcePath;
    if (path == null) return;
    if (!await openExternally(path)) okInfoBarRed(lw('Nothing can open this'));
  }

  Future<void> _openRecvFolder() async {
    if (!await openRecvFolder()) okInfoBarRed(lw('Nothing can open this'));
  }

  Widget _buildDevicesHeader() {
    return sectionTitle(
      lw('Devices'),
      trailing: Tooltip(
        message: lw('Add device'),
        child: InkWell(
          onTap: _addManualDevice,
          customBorder: const CircleBorder(),
          child: CircleAvatar(
            radius: 12,
            backgroundColor: clText,
            // Drawn rather than taken from the icon font: the icon's stroke is
            // too thin to read on a circle this small.
            child: Text(
              '+',
              style: TextStyle(
                color: clFill,
                fontSize: 22,
                height: 1,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
        ),
      ),
    );
  }

  // The receive folder is one tap away wherever the transfers are listed, so
  // the section header stays on screen even with nothing in it yet.
  Widget _buildTransfersHeader() {
    return sectionTitle(
      lw('Transfers'),
      trailing: Tooltip(
        message: lw('Open the receive folder'),
        child: InkWell(
          onTap: _openRecvFolder,
          customBorder: const CircleBorder(),
          child: Icon(Icons.folder_open, color: clText, size: 22),
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
          leading: _deviceIcon(device, isTarget),
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

  Widget _deviceIcon(Device device, bool isTarget) {
    final IconData icon =
        device.platform == 'android' ? Icons.smartphone : Icons.computer;
    if (!device.online) {
      return Icon(icon, color: clFrame);
    }
    // The chosen device turns into an arrow pointing at its row: the platform
    // icon would not fit inside a triangle, and the highlight alone was easy
    // to miss.
    if (isTarget) {
      // Scaled rather than sized: the arrow reads bigger than the circle it
      // replaces while the row keeps the same 32 px slot, so the names below
      // do not shift sideways.
      return SizedBox(
        width: 32,
        height: 32,
        child: Transform.scale(
          scale: 1.4,
          child: Icon(Icons.play_arrow, color: clGreen, size: 32),
        ),
      );
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
    // Said outright, the way the device list says it: a heading with nothing
    // under it looks like something failed to load.
    if (list.isEmpty) {
      return SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(lw('No transfers yet'), style: tsSmall),
        ),
      );
    }
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
        return clError;
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
                : _armed
                    ? _sendOrPickTarget
                    : null,
            style: ElevatedButton.styleFrom(
              // Grey while a target is still missing: pressing it then only
              // asks for one.
              backgroundColor: stopping
                  ? clError
                  : _canSend
                      ? clAccent
                      : clFrame.withValues(alpha: 0.3),
              disabledBackgroundColor: clFrame.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(btnRadius)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: fsLarge,
                // Whatever the button is painted with decides the lettering:
                // an accent light enough for dark text is a valid palette.
                color: stopping
                    ? onColor(clError)
                    : _canSend
                        ? onColor(clAccent)
                        : clText,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
