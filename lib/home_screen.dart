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
import 'log_screen.dart';
import 'net_discovery.dart';
import 'net_sender.dart';
import 'net_server.dart';
import 'settings_screen.dart';

// Which way the network should go for a lifecycle change, or null when the
// change is no reason to touch it. With background receiving off, a
// backgrounded app must stop announcing and stop listening: otherwise it keeps
// advertising itself as reachable while the user believes it is closed
// (SPEC 7). 'inactive' is nobody's answer — a notification shade or a
// permission dialog passes through it, and rebinding the server there would
// drop a transfer that is running perfectly well.
bool? networkDesiredFor(
  AppLifecycleState state, {
  required bool receiveInBackground,
}) {
  if (state == AppLifecycleState.inactive) return null;
  if (receiveInBackground) return true;
  switch (state) {
    case AppLifecycleState.resumed:
      return true;
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
    case AppLifecycleState.hidden:
      return false;
    case AppLifecycleState.inactive:
      return null;
  }
}

// What one lifecycle event means once the exit button has already run.
class LifecycleNetworkDecision {
  const LifecycleNetworkDecision(this.desired, this.stillExiting);

  /// The state the network should be in, null when this event decides nothing.
  final bool? desired;

  /// Whether the exit is still waiting for the app to become visible again.
  final bool stillExiting;
}

// The exit stops the network itself, but on Android the engine outlives the
// Activity, so this observer is still alive for the paused/detached events that
// the teardown delivers afterwards. With background receiving on,
// networkDesiredFor answers true for those states, which would reopen the very
// sockets the exit just closed and leave the device announcing itself while the
// user believes the app is closed (SPEC 7). Worse, the flag left at true then
// makes the next resumed a no-op in _setNetworkDesired, so the app starts with
// no network at all. An exit therefore swallows every event until the app is
// genuinely visible again, and that resumed is what ends it.
LifecycleNetworkDecision lifecycleNetworkDecision(
  AppLifecycleState state, {
  required bool receiveInBackground,
  required bool exiting,
}) {
  if (exiting && state != AppLifecycleState.resumed) {
    return const LifecycleNetworkDecision(null, true);
  }
  return LifecycleNetworkDecision(
    networkDesiredFor(state, receiveInBackground: receiveInBackground),
    false,
  );
}

// Whether manual devices should be polled right now.
//
// Deliberately not the network state. A manual device announces nothing, so an
// HTTP poll is the only thing that keeps its row honest — and a row nobody is
// looking at is not worth waking the network for every ten seconds (SPEC 5.4).
// Tying it to the network instead was wrong in exactly one case, which is also
// the expensive one: with background receiving on, the desired network state is
// true in every lifecycle state, so putting the app away changed nothing and the
// poller kept running with the screen off, against Doze.
//
// 'inactive' still counts as looking: on desktop it is merely an unfocused
// window, and on Android it is the shade coming down over a visible app.
bool manualPollingWanted({
  required AppLifecycleState state,
  required bool networkUp,
}) {
  if (!networkUp) return false;
  switch (state) {
    case AppLifecycleState.resumed:
    case AppLifecycleState.inactive:
      return true;
    case AppLifecycleState.paused:
    case AppLifecycleState.detached:
    case AppLifecycleState.hidden:
      return false;
  }
}

Future<bool> updateReceiverAdvertisement({
  required bool receiverReady,
  required Future<bool> Function() startAdvertisement,
  required Future<void> Function() stopAdvertisement,
}) async {
  if (!receiverReady) {
    await stopAdvertisement();
    return false;
  }
  return startAdvertisement();
}

// Everything an exit does once the user has agreed to it, in the order it has
// to happen in. Out here rather than inside the button handler because it is
// the part that can be wrong: an outgoing send is cancelled first, while the
// network it has to say so over is still up; the receiver goes next so the
// goodbye is not advertising a listener that is still up; discovery is the one
// stop that announces itself; the foreground service goes before the screen,
// since its notification claims a receiver that has just stopped; and whatever
// is only meant to last one run is let go at the end, because on Android the
// process stays alive and the next launch would inherit it.
//
// The send is cancelled rather than left running because on Android nothing
// carries it once the screen is gone: the service that kept the process alive is
// stopped two lines below, there is no notification left to show progress, and
// no way to stop it short of killing the app from the system settings. The
// desktop has always ended it this way — exit(0) takes the process with it.
//
// The stops are passed in so this can be run without a network: every one of
// them binds sockets in production. The selection is passed in for the same
// reason in reverse: it lives in a State object, and this function has none.
Future<void> shutdownForExit({
  required bool android,
  required Future<void> Function() cancelSend,
  required Future<void> Function() stopReceiver,
  required Future<void> Function({bool announceLeaving}) stopAdvertisement,
  required void Function() stopPolling,
  required Future<void> Function() stopBackgroundService,
  required void Function() clearSelection,
}) async {
  // Through the sender's own cancel, so the far end is told with a /cancel
  // instead of being left holding a session that only times out. Files already
  // verified over there stay where they are.
  //
  // Bounded, because telling the far end means dialling it: a peer that has gone
  // away takes the connect, header and body deadlines one after another, and an
  // exit would sit on screen for the better part of half a minute. The transfer
  // is already marked cancelled and its client force-closed before cancel()
  // awaits anything, so giving up on the notification costs nothing here.
  try {
    await cancelSend().timeout(const Duration(seconds: exitCancelTimeoutSec));
  } catch (e) {
    myPrint('exit stopped waiting for the outgoing transfer: $e');
  }
  await stopReceiver();
  await stopAdvertisement(announceLeaving: true);
  stopPolling();
  if (android) await stopBackgroundService();
  for (final Device device in xvDevices) {
    device.departedAt = null;
  }
  // The picked list goes with the rest of the one-run state, and for a sharper
  // reason than tidiness: the next launch sweeps the cache of copied documents,
  // so a selection inherited across an exit points at files that sweep has just
  // deleted — a row that is there, a Send that is live, and a per-file failure
  // saying the original is gone.
  clearSelection();
  clearSessionState();
}

// Retry opens a transfer of its own, so it waits for whatever is on screen to
// end: this device does one transfer at a time, in either direction. Without
// this the button was live while an incoming transfer ran, and pressing it was
// the one way left to have two of them at once.
bool retryEnabled({required bool senderBusy, required bool anyTransferRunning}) =>
    !senderBusy && !anyTransferRunning;

// Why Send cannot start right now, or null when nothing is in the way.
enum SendBlock {
  // A receive holds the one transfer slot. Not the same as a row in the transfer
  // list: the slot is taken from the moment a prepare arrives, and the consent
  // question can stand on screen for half a minute before any row exists. That
  // window was the one place where this device could be made to send and receive
  // at once, against SPEC 5.7 — the receiver refuses a second peer, and nothing
  // used to refuse the user.
  receiving,
  noFiles,
  noTarget,
}

SendBlock? sendBlockedBy({
  required bool receiveSlotHeld,
  required bool hasFiles,
  required bool hasTarget,
}) {
  if (receiveSlotHeld) return SendBlock.receiving;
  if (!hasFiles) return SendBlock.noFiles;
  if (!hasTarget) return SendBlock.noTarget;
  return null;
}

enum SendButtonMode { send, stop, stopping }

// What the one button at the bottom is at this moment. Cancelling marks the
// transfer cancelled straight away, while the send holds its client until the
// request it was in the middle of has unwound. Without the state in between,
// the button offered Send in that gap and did nothing at all when pressed.
SendButtonMode sendButtonMode({
  required bool transferRunning,
  required bool senderBusy,
}) {
  if (transferRunning) return SendButtonMode.stop;
  if (senderBusy) return SendButtonMode.stopping;
  return SendButtonMode.send;
}

// The platform icon of a device row. An unreachable device gets the
// struck-through variant, which is the whole of what says so: the row used to
// spell "offline" beside the address and wrapped it onto a third line.
IconData deviceRowIcon({required bool phone, required bool online}) {
  if (online) return phone ? Icons.smartphone : Icons.computer;
  return phone ? Icons.phonelink_off : Icons.desktop_access_disabled;
}

// A receiver destination may only occur once. Case folding also prevents a
// selection that would collapse when the peer runs Windows.
String targetKey(FileItem f) => f.relativePath.toLowerCase();

// The source paths a finished batch actually delivered.
//
// The picked list normally recognises its own items: a send is handed the very
// objects the list holds, so marking one done is enough. A Retry cannot work
// that way — it rebuilds its batch from disk to re-read what is there now, and
// what it marks done are new objects with new ids. The path they were read from
// is the one thing both sides still agree on.
Set<String> deliveredSourcePaths(Iterable<FileItem> batch) => {
  for (final FileItem file in batch)
    if (file.done && file.sourcePath != null) file.sourcePath!,
};

// What is left of a selection once a finished batch has been accounted for.
// Scoped to that one batch on purpose: a file the user picks again after it has
// already been sent belongs back in the list, so this must not be asked of
// every transfer ever made in this run.
List<FileItem> withoutDelivered(
  List<FileItem> selection,
  Iterable<FileItem> batch,
) {
  final Set<String> delivered = deliveredSourcePaths(batch);
  if (delivered.isEmpty) return selection;
  return [
    for (final FileItem file in selection)
      if (file.sourcePath == null || !delivered.contains(file.sourcePath))
        file,
  ];
}

// What of a fresh pick can actually be sent, and how much of it cannot. Two
// ways of picking the same thing twice: the same file on disk, and two files
// that would land on the same place at the far end — the second one catches a
// file added on its own and again inside its folder. Unusable ones are those
// the receiver would refuse anyway, found here so the answer is a sentence
// rather than a transfer that dies at 'HTTP 400'.
({List<FileItem> fresh, int duplicates, List<RefusedPick> refused})
sortPickedFiles(List<FileItem> items, List<FileItem> selected) {
  final Set<String> knownSources = selected
      .map((f) => f.sourcePath)
      .whereType<String>()
      .toSet();
  final Set<String> knownTargets = selected.map(targetKey).toSet();
  final List<FileItem> fresh = [];
  final List<RefusedPick> refused = [];
  int duplicates = 0;

  for (final FileItem file in items) {
    if (sanitizeRelPath(file.relativePath) == null ||
        file.size > maxDeclaredFileBytes) {
      refused.add((
        file: file,
        problem: classifyRefusal(file.relativePath, size: file.size),
      ));
      continue;
    }
    final String? source = file.sourcePath;
    // Both sets are asked before the verdict: && would skip the second add.
    final bool newSource = source == null || knownSources.add(source);
    final bool newTarget = knownTargets.add(targetKey(file));
    if (!newSource || !newTarget) {
      duplicates++;
      continue;
    }
    fresh.add(file);
  }
  return (fresh: fresh, duplicates: duplicates, refused: refused);
}

// The whole application is this one screen: picking, devices, progress. No tabs
// and no bottom navigation (SPEC 4).
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver, WindowListener {
  final List<FileItem> _selected = [];
  // Delete each source once the other side has it. Never persisted and never
  // carried over: see _buildMoveTick.
  bool _move = false;
  // Only meaningful while _move is on: whether the move also takes the folders
  // it emptied.
  bool _moveFolders = false;
  // Immutable source/relative-path pairs preserve folder structure while
  // current size/date are re-read when the batch is restored.
  List<FileSnapshot> _lastSent = [];
  Device? _target;
  // True while something is being dragged over the drop zone.
  bool _dragOver = false;
  // The selection has its own scroll area, so it needs its own controller for
  // the scrollbar to attach to.
  final ScrollController _selectedScroll = ScrollController();
  Timer? _windowSaveTimer;

  // One listenable for everything the screen mirrors.
  late final Listenable _netTicks = Listenable.merge([
    devicesTick,
    transfersTick,
    serverTick,
  ]);

  StreamSubscription<List<SharedMediaFile>>? _shareSub;
  // Starts off, so the first _setNetworkDesired(true) is a real transition.
  bool _networkDesired = false;
  // The port changed and the server has to rebind — which drops whatever the
  // socket is doing, so it waits for the transfer that is using it.
  bool _restartPending = false;
  bool _disposed = false;
  // Set once the exit has committed. The widget tree survives the exit together
  // with the engine, so this is what tells the lifecycle observer that the
  // events still coming are a teardown and not the user leaving the app.
  bool _exiting = false;
  int _networkEpoch = 0;
  final SerialQueue _networkQueue = SerialQueue('network transition');
  Future<void> _networkTail = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // The window frame's own close button is prevented in main() so that it
    // comes here instead, and asks and shuts down like the button in the bar.
    if (!Platform.isAndroid) windowManager.addListener(this);
    devicesTick.addListener(_dropOfflineTarget);
    transfersTick.addListener(_pruneSentFiles);
    androidServiceStateTick.addListener(_handleAndroidServiceState);
    // The notification's buttons act on the same two paths as the screen does.
    androidService.onNotificationStop = _stop;
    androidService.onNotificationExit = () =>
        _exitApp(mayKeepReceiving: false);
    receiveServer.onListenerLost = _rebuildLostListener;
    androidService.attach();
    _startNetwork();
    _listenForShares();
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _showFirstStartWarning(),
    );
  }

  // The picked list doubles as the queue: a file that arrived and passed its
  // checksum leaves it, so whatever remains is exactly what did not get there.
  void _pruneSentFiles() {
    // The exit path empties this list itself and has already taken the network
    // down by hand. Answering its tick would queue one more transition behind
    // an app that is leaving, and prune a selection nobody will see again.
    if (_exiting) return;
    // Whatever was postponed while the sockets were busy gets its turn as soon
    // as they are idle: shutting the network down, or rebinding a new port.
    if ((!_networkDesired || _restartPending) &&
        !xvTransfers.any((t) => t.isRunning)) {
      _queueNetworkTransition();
    }
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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Every platform, and before the Android-only part below: polling follows
    // whether anyone can see the list, which is a question a minimized desktop
    // window answers too.
    _syncManualPolling(state);
    if (!Platform.isAndroid) return;
    final LifecycleNetworkDecision decision = lifecycleNetworkDecision(
      state,
      receiveInBackground: xdef['Receive in background'] == 'true',
      exiting: _exiting,
    );
    _exiting = decision.stillExiting;
    final bool? desired = decision.desired;
    if (desired != null) _setNetworkDesired(desired);
    // Back on screen is the other moment a foreground service may be started,
    // and the moment to repair a notification Android took while we were away.
    // _setNetworkDesired above is a no-op whenever the network never stopped,
    // so nothing else here would notice the service had gone.
    if (state == AppLifecycleState.resumed) {
      unawaited(androidService.reassert());
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
    _disposed = true;
    _networkDesired = false;
    _networkEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    if (!Platform.isAndroid) windowManager.removeListener(this);
    devicesTick.removeListener(_dropOfflineTarget);
    transfersTick.removeListener(_pruneSentFiles);
    androidServiceStateTick.removeListener(_handleAndroidServiceState);
    _shareSub?.cancel();
    _selectedScroll.dispose();
    _windowSaveTimer?.cancel();
    androidService.onNotificationStop = null;
    androidService.onNotificationExit = null;
    receiveServer.onListenerLost = null;
    androidService.detach();
    receiveServer.stop();
    discovery.stop();
    manualPoller.stop();
    super.dispose();
  }

  // The listening socket died on its own — the network it was bound through
  // went away. Rebinding it is a network transition like any other, so it goes
  // through the queue instead of calling start() from under a socket callback.
  // The epoch is deliberately left alone: a transition already in flight is
  // bringing the same state up and does not need to abandon itself.
  void _rebuildLostListener() {
    if (_disposed || _exiting || !_networkDesired) return;
    _queueNetworkTransition();
  }

  void _handleAndroidServiceState() {
    if (_disposed || androidService.backgroundReady || appInForeground) return;
    unawaited(_stopNetworkAfterServiceTimeout());
  }

  Future<void> _stopNetworkAfterServiceTimeout() async {
    // A timed-out foreground service may not leave sockets and transfers
    // silently running as an ordinary background process. End current work
    // first; the normal serialized transition then closes every listener.
    await sender.cancel();
    await receiveServer.cancelCurrent();
    if (_disposed || appInForeground) return;
    _setNetworkDesired(false);
    await _networkTail;
  }

  Future<void> _startNetwork() async {
    bool desired = true;
    if (Platform.isAndroid) {
      // The Application-owned engine starts before the first Activity attaches.
      // Foreground-only networking must wait for resumed instead of asking an
      // Activity-bound permission plugin while there is no Activity yet.
      final AppLifecycleState state =
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.detached;
      desired =
          networkDesiredFor(
            state,
            receiveInBackground: xdef['Receive in background'] == 'true',
          ) ??
          false;
    }
    _setNetworkDesired(desired);
    await _networkTail;
  }

  // Only a real change is a transition. Repeating the state the network is
  // already in would bump the epoch and make the transition in flight abandon
  // itself halfway, which with background receiving on happens on every single
  // lifecycle event.
  void _setNetworkDesired(bool desired) {
    if (_networkDesired == desired) return;
    _networkDesired = desired;
    _networkEpoch++;
    _queueNetworkTransition();
  }

  void _queueNetworkTransition() {
    final int epoch = _networkEpoch;
    _networkTail = _networkQueue.add(() => _runNetworkTransition(epoch));
  }

  // A transition that throws must not pass without a trace. The queue's own
  // handler only reaches myPrint, which is compiled out of the release builds
  // this project ships, and the screen would go on showing whatever it showed
  // before — a device list from a discovery that is now stopped, or a receiver
  // that never started. Readiness is the surface that already exists for
  // "receiving is off", so a failed transition speaks through it.
  Future<void> _runNetworkTransition(int epoch) async {
    try {
      await _applyNetworkState(epoch);
    } catch (e, st) {
      myPrint('network transition failed: $e\n$st');
      // An epoch superseded on purpose is not a failure: whoever bumped it is
      // already queued behind this and will bring the state where it belongs.
      if (!_stillWantsNetwork(epoch)) return;
      receiveServer.noteTransitionFailure();
      // Nothing may go on advertising a receiver whose setup did not finish.
      try {
        await discovery.stop();
      } catch (stopError) {
        myPrint('cannot stop advertising after a failed transition: $stopError');
      }
    }
  }

  bool _stillWantsNetwork(int epoch) =>
      !_disposed && _networkDesired && epoch == _networkEpoch;

  // What the app is doing before the first lifecycle event arrives. The two
  // defaults are the ones the rest of this screen already assumes: on Android
  // the engine can be up with no Activity attached yet, so nothing is visible;
  // elsewhere the window is there as soon as the app is.
  AppLifecycleState get _lifecycleNow =>
      WidgetsBinding.instance.lifecycleState ??
      (Platform.isAndroid
          ? AppLifecycleState.detached
          : AppLifecycleState.resumed);

  // Called from both sides of the question: a lifecycle event, and the network
  // transition that may have brought the network up or taken it down. Starting
  // an already-running poller would restart its timer and fire an extra pass on
  // every event, so the state is asked first.
  void _syncManualPolling([AppLifecycleState? state]) {
    final bool wanted = manualPollingWanted(
      state: state ?? _lifecycleNow,
      networkUp: _networkDesired && !_disposed,
    );
    if (!wanted) {
      manualPoller.stop();
    } else if (!manualPoller.running) {
      manualPoller.start();
    }
  }

  bool get _transferBusy => sender.busy || xvTransfers.any((t) => t.isRunning);

  // Every path that abandons this method leaves a queued transition behind it,
  // so nothing has to be torn down on the way out: whoever bumped the epoch is
  // about to run and will do it.
  Future<void> _applyNetworkState(int epoch) async {
    if (!_networkDesired || _disposed) {
      if (_transferBusy) return;
      manualPoller.stop();
      await discovery.stop();
      await receiveServer.stop();
      return;
    }

    // Ask before the first transfer rather than at the moment files arrive:
    // without storage access the receive folder cannot be written at all.
    await ensureStoragePermission();
    if (!_stillWantsNetwork(epoch)) return;
    if (Platform.isAndroid && xdef['Receive in background'] == 'true') {
      if (!await ensureNotificationPermission()) {
        xdef['Receive in background'] = 'false';
        await saveSettings();
        rebuildApp();
        await androidService.sync();
        okInfoBarRed(
          lw('Background receiving needs notifications'),
        );
        final AppLifecycleState state =
            WidgetsBinding.instance.lifecycleState ??
            AppLifecycleState.detached;
        final bool desired =
            networkDesiredFor(state, receiveInBackground: false) ?? false;
        if (desired != _networkDesired) _setNetworkDesired(desired);
        if (!_stillWantsNetwork(epoch)) return;
      }
    }
    // Here rather than at main(), because on Android a leftover session cannot
    // even be deleted until the storage permission above has been answered.
    await sweepOrphanSessionsOnce();
    // Copies the picker had to make of documents it could not hand over as
    // plain files. Nobody owns them once the app has restarted, and a couple of
    // picked videos leave gigabytes in the cache.
    await sweepPickedCopiesOnce();
    if (!_stillWantsNetwork(epoch)) return;
    if (_restartPending) {
      // Leave everything exactly as it is until the sockets are free: starting
      // on the new port would rebind, and rebinding is what drops the session.
      // _pruneSentFiles comes back here when the last transfer ends.
      if (_transferBusy) return;
      _restartPending = false;
      await discovery.stop();
      await receiveServer.stop();
      if (!_stillWantsNetwork(epoch)) return;
    }
    // Manual peers and outgoing sends remain useful even if this machine
    // cannot currently receive. Automatic discovery, however, would advertise
    // a dead port or an unusable destination, so it follows receive readiness.
    // Polling those manual peers follows something else again — whether the
    // list is on screen at all — so it is asked rather than simply started.
    _syncManualPolling();
    final bool receiveReady = await receiveServer.start();
    if (!_stillWantsNetwork(epoch)) return;
    await updateReceiverAdvertisement(
      receiverReady: receiveReady,
      startAdvertisement: discovery.start,
      stopAdvertisement: discovery.stop,
    );
    if (!_stillWantsNetwork(epoch)) return;
    if (!receiveReady) return;
  }

  // Called after the port may have changed in settings.
  Future<void> _restartNetwork() async {
    _restartPending = true;
    // Rebinding drops the socket, so a transfer that is using it keeps the old
    // port until it is done — said out loud, since the setting is already
    // showing the new number.
    if (_transferBusy) {
      okInfoBarOrange(lw('The port changes when the transfer ends'));
    }
    _networkEpoch++;
    _queueNetworkTransition();
    await _networkTail;
  }

  int get _totalBytes => _selected.fold(0, (sum, f) => sum + f.size);

  bool get _canSend =>
      !sender.busy &&
      sendBlockedBy(
            receiveSlotHeld: receiveServer.receiveSlotHeld,
            hasFiles: _selected.isNotEmpty,
            hasTarget: _target != null,
          ) ==
          null;

  Future<void> _pickFiles() async {
    // Android goes through the Activity rather than through file_picker: the
    // system destroys the Activity while the picker is open on both phones
    // here, and the plugin drops the pending result with it. See
    // MainActivity.pickFiles.
    if (Platform.isAndroid) {
      final List<String>? picked = await pickFilesFromActivity();
      if (picked == null) {
        okInfoBarRed(lw('Could not open the file manager'));
        return;
      }
      // Empty is the user backing out, which needs no comment.
      if (picked.isEmpty) return;
      await _addPaths(picked);
      return;
    }

    final List<PlatformFile> files;
    try {
      files = await FilePicker.pickFiles();
    } catch (e) {
      // Whatever the picker throws, the user is owed a sentence: the file
      // manager closing with nothing to show for it reads as the button being
      // broken.
      myPrint('picking files failed: $e');
      okInfoBarRed(lw('Could not open the file manager'));
      return;
    }
    // An empty list is the user backing out, which needs no comment.
    if (files.isEmpty) return;
    final List<String> paths = files
        .map((f) => f.path)
        .whereType<String>()
        .toList();
    // A picked file with no path of its own: the plugin could not put a copy
    // where dart:io can reach it. Silently dropping it is what made picking
    // look like it did nothing at all.
    if (paths.isEmpty) {
      okInfoBarRed(lw('The file manager gave no path'));
      return;
    }
    await _addPaths(paths);
  }

  Future<void> _pickFolder() async {
    final String? dir = await pickFolder();
    if (dir == null) return;
    await _addPaths([dir]);
  }

  Future<void> _addPaths(List<String> paths) async {
    final CollectedFiles collected = await collectFiles(paths);
    if (!mounted) return;
    // Said as soon as the walk knows, instead of after a folder of any size has
    // been read into memory in full.
    if (collected.tooManyFiles) {
      okInfoBarRed('${lw('Too many files at once')}: $maxManifestFiles');
      return;
    }
    if (collected.tooLarge) {
      okInfoBarRed(lw('The selection is too large'));
      return;
    }
    final List<FileItem> items = collected.items;
    // collectFiles skips anything that is neither a file nor a directory by the
    // time it looks — a path that never materialised, or one this process may
    // not read. Coming back with nothing at all is not a selection the user can
    // be left to guess about.
    if (items.isEmpty && paths.isNotEmpty) {
      okInfoBarRed(lw('The selection could not be read'));
      return;
    }
    final picked = sortPickedFiles(items, _selected);

    // The receiver refuses a manifest past these limits, and it refuses the
    // whole thing. Said here, before anything is sent, it is one sentence
    // instead of a transfer that gets as far as the other end and dies.
    if (_refuseOverLimit(picked.fresh)) return;

    setState(() => _selected.addAll(picked.fresh));
    if (picked.duplicates > 0) {
      okInfoBarOrange('${lw('Duplicates skipped')}: ${picked.duplicates}');
    }
    if (picked.refused.isEmpty) return;

    // Named one by one, with the reason, before anything is sent. The only
    // repair on offer is the backslash; whoever says yes to it is agreeing to
    // a file arriving under a name they did not choose.
    if (!await showRefusedNamesDialog(picked.refused)) return;
    final List<FileItem> repaired = [
      for (final RefusedPick item in picked.refused)
        if (item.problem == PickProblem.backslash)
          item.file.renamed(repairBackslashes(item.file.relativePath)),
    ];
    if (!mounted || repaired.isEmpty) return;
    // Through the same sort again: a repaired name can collide with something
    // already picked, and it still has to pass every other rule.
    await _addRepaired(repaired);
  }

  // Whether the selection may not grow by these files, said out loud when so.
  // Both admission paths ask it: the repair used to check the count alone and
  // could add a file that pushed the whole selection past the size limit.
  bool _refuseOverLimit(List<FileItem> fresh) {
    switch (selectionLimitBroken(_selected, fresh)) {
      case SelectionLimit.files:
        okInfoBarRed('${lw('Too many files at once')}: $maxManifestFiles');
        return true;
      case SelectionLimit.bytes:
        okInfoBarRed(lw('The selection is too large'));
        return true;
      case SelectionLimit.names:
        okInfoBarRed(lw('The names are too long'));
        return true;
      case null:
        return false;
    }
  }

  Future<void> _addRepaired(List<FileItem> repaired) async {
    final picked = sortPickedFiles(repaired, _selected);
    if (_refuseOverLimit(picked.fresh)) return;
    setState(() => _selected.addAll(picked.fresh));
    if (picked.refused.isNotEmpty) {
      okInfoBarOrange(
        '${lw('Some names cannot be sent')}: ${picked.refused.length}',
      );
    }
  }

  // Clear resets the whole choice, files and target alike.
  void _clear() => setState(() {
    _selected.clear();
    _target = null;
  });

  void _remove(FileItem item) => setState(() => _selected.remove(item));

  // What an exit lets go of on this screen: the picked list and the batch the
  // Restore button would bring back. Both hold source paths, some of them copies
  // the picker made in the cache, and the next launch sweeps that cache.
  //
  // The target is deliberately left alone: it is a device, not a file, and
  // _dropOfflineTarget drops it on the first tick that cannot find it.
  void _releaseSelection() {
    _selected.clear();
    _lastSent = [];
    if (mounted) setState(() {});
  }

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
  //
  // Unless background receiving is on and working: then ✕ only closes the
  // screen and everything below is left running. The notification's Exit button
  // passes false and always ends the app — it is what that ongoing notification
  // is there to offer.
  Future<void> _exitApp({bool mayKeepReceiving = true}) async {
    final bool android = Platform.isAndroid;
    final bool receiveInBackground = xdef['Receive in background'] == 'true';
    final bool askBeforeExit = xdef['Ask before exit'] == 'true';
    final bool backgroundReady = androidService.backgroundReady;
    final bool running = xvTransfers.any((t) => t.isRunning);

    bool confirmed = true;
    if (exitAsksFirst(
      android: android,
      mayKeepReceiving: mayKeepReceiving,
      receiveInBackground: receiveInBackground,
      backgroundReady: backgroundReady,
      transferRunning: running,
      askBeforeExit: askBeforeExit,
    )) {
      confirmed = await okConfirm(
        title: lw('Exit'),
        // Said outright, because leaving now ends the transfer: "Exit?" over a
        // running one used to read as a question about the screen.
        message: running
            ? '${lw('The transfer will be stopped')}. ${lw('Exit the application')}?'
            : '${lw('Exit the application')}?',
      );
    }

    switch (exitPlan(
      android: android,
      mayKeepReceiving: mayKeepReceiving,
      receiveInBackground: receiveInBackground,
      backgroundReady: backgroundReady,
      transferRunning: running,
      askBeforeExit: askBeforeExit,
      confirmed: confirmed,
    )) {
      // The answer was no. Nothing has been touched yet, and nothing is.
      case ExitPlan.stay:
        return;

      case ExitPlan.keepReceiving:
        // Nothing is asked and nothing is stopped: a running transfer carries on
        // in the background, which is the whole point of the switch.
        //
        // The notification is posted again first. This is the last moment the
        // app is in the foreground, and if Android has quietly taken the service
        // — which it does when a task is removed — this is the only place
        // allowed to bring it back. Leaving the screen without it would leave a
        // receiver running with nothing on screen to say so.
        await androidService.reassert();
        if (_windowSaveTimer?.isActive ?? false) await _saveWindowBounds();
        // Deliberately not finishActivityAndTask(): the screen closes but the
        // Recents card stays, because the app is still running and that card is
        // the ordinary way back to it. Only a full exit takes the card away.
        await SystemNavigator.pop();
        return;

      case ExitPlan.shutDown:
        await _shutDownAndLeave();
        return;
    }
  }

  // The full exit, in the order it has to happen in.
  Future<void> _shutDownAndLeave() async {
    // Before the first await, not after: the stops below can be overtaken by
    // the lifecycle events of the app going away, and with background receiving
    // on those ask for the network to come straight back up.
    _exiting = true;
    // Tell the network state machine rather than going around it. On Android
    // the engine belongs to EasySendApplication and outlives this Activity, so
    // everything here survives the exit — and _setNetworkDesired returns early
    // when the flag already holds the value asked for. Leaving it at true while
    // the sockets are closed means reopening the app can never rebind them, and
    // only killing the process recovers.
    _networkDesired = false;
    _networkEpoch++;
    await shutdownForExit(
      android: Platform.isAndroid,
      cancelSend: sender.cancel,
      stopReceiver: receiveServer.stop,
      stopAdvertisement: discovery.stop,
      stopPolling: manualPoller.stop,
      stopBackgroundService: androidService.stopService,
      clearSelection: _releaseSelection,
    );
    // A move or resize in the last 400 ms is still sitting in the debounce, and
    // exit(0) below would take it with it: the window would come back where it
    // was two positions ago, which reads as the feature not working.
    if (_windowSaveTimer?.isActive ?? false) await _saveWindowBounds();

    if (Platform.isAndroid) {
      // Ends the screen and clears its Recents card in one step. If no Activity
      // answered, the screen still has to close, and a listed task is a better
      // outcome than an exit button that does nothing.
      if (!await finishActivityAndTask()) await SystemNavigator.pop();
    } else {
      // Not windowManager.close(): the engine tears the GTK window down first
      // and then trips over its own compositor cleanup with no GL context left,
      // which ends in an abort. Everything of ours is already stopped above.
      exit(0);
    }
  }

  // The close button on the window frame, prevented in main() so it lands here.
  @override
  void onWindowClose() => _exitApp();

  @override
  void onWindowMove() => _scheduleWindowSave();

  @override
  void onWindowResize() => _scheduleWindowSave();

  void _scheduleWindowSave() {
    if (Platform.isAndroid) return;
    _windowSaveTimer?.cancel();
    _windowSaveTimer = Timer(
      const Duration(milliseconds: 400),
      _saveWindowBounds,
    );
  }

  Future<void> _saveWindowBounds() async {
    if (Platform.isAndroid) return;
    _windowSaveTimer?.cancel();
    _windowSaveTimer = null;
    try {
      final Offset position = await windowManager.getPosition();
      final Size size = await windowManager.getSize();
      xdef['.Window bounds'] = encodeWindowBounds(
        x: position.dx,
        y: position.dy,
        width: size.width,
        height: size.height,
      );
      await saveSettings();
    } catch (e) {
      myPrint('cannot save window bounds: $e');
    }
  }

  Future<void> _showFirstStartWarning() async {
    if (!mounted || xdef['.First start'] != 'true') return;
    final bool shown = await showNetworkSafetyWarning(context: context);
    if (!mounted || !shown) return;
    xdef['.First start'] = 'false';
    await saveSettings();
  }

  // Send with nothing chosen: one reachable device is no choice at all, so it
  // becomes the target and the transfer starts; with several, ask. An empty
  // selection is asked about first, being the earlier of the two steps.
  Future<void> _sendOrPickTarget() async {
    switch (sendBlockedBy(
      receiveSlotHeld: receiveServer.receiveSlotHeld,
      hasFiles: _selected.isNotEmpty,
      hasTarget: _target != null,
    )) {
      // Said rather than silently ignored: with a consent question on screen
      // there is nothing in the transfer list to explain why Send does nothing,
      // and declining it makes Send work again at once.
      case SendBlock.receiving:
        okInfoBarOrange(lw('A transfer is already running'));
        return;
      case SendBlock.noFiles:
        // With neither piece in place, naming only the files would leave the
        // second step to be discovered on the next press.
        okInfoBarOrange(
          lw(
            _target == null
                ? 'Add files and pick a device'
                : 'Add files to send',
          ),
        );
        return;
      case SendBlock.noTarget:
        // One reachable device is no choice at all: it becomes the target and the
        // transfer starts. With several, ask.
        final List<Device> reachable = xvDevices.where((d) => d.online).toList();
        if (reachable.length != 1) {
          okInfoBarOrange(lw('Select a target device'));
          return;
        }
        setState(() => _target = reachable.first);
      case null:
        break;
    }
    await _send();
  }

  Future<void> _send() async {
    final Device? target = _target;
    if (target == null || _selected.isEmpty) return;
    final List<FileItem> batch = List<FileItem>.of(_selected);
    setState(() {
      _lastSent = snapshotFiles(batch);
    });
    // Files leave the list one by one as they land, via _pruneSentFiles.
    final TransferStatus status = await sender.send(
      peer: target,
      files: batch,
      move: _move,
      moveFolders: _move && _moveFolders,
    );
    if (!mounted) return;
    // Whatever came of it, the ticks do not carry into the next transfer.
    setState(() {
      _move = false;
      _moveFolders = false;
    });
    // Everything arrived: drop the target too, so the next send starts clean.
    // After a partial or failed one it stays selected, together with the files
    // still in the list, ready for another attempt.
    if (status == TransferStatus.done) setState(() => _target = null);
  }

  // Bring the last batch back into the list, re-reading it from disk.
  Future<void> _restoreLastBatch() async {
    if (_lastSent.isEmpty) return;
    final restored = await restoreFileSnapshot(_lastSent);
    final List<FileItem> items = restored.files;
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
    if (restored.missing > 0) {
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
            const Text(
              'EasySend',
              style: TextStyle(fontSize: fsLarge, fontWeight: fwBold),
            ),
            Text(
              xvDeviceName,
              style: TextStyle(fontSize: fsSmall, color: clUpBarText),
            ),
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
            if (receiveServer.readinessFailure != null)
              SliverToBoxAdapter(child: _buildReceiveBanner()),
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

  // Receiving is down while its port or folder is unavailable; sending still
  // works, so this is a banner and not a blocking error.
  Widget _buildReceiveBanner() {
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
              receiveBannerText(receiveServer.readinessFailure, currentPort),
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
            style: bannerButtonStyle,
            child: Text(
              lw('Settings'),
              style: const TextStyle(fontSize: fsSmall),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPickRow() {
    final Widget buttons = Row(
      children: [
        Expanded(
          child: _pickButton(
            Icons.insert_drive_file_outlined,
            lw('File'),
            _pickFiles,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _pickButton(Icons.folder_open, lw('Folder'), _pickFolder),
        ),
      ],
    );

    // Android has no pointer to drag with; there the share menu does this job.
    if (Platform.isAndroid) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: buttons,
      );
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
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(btnRadius),
        ),
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
    if (empty && _lastSent.isNotEmpty) {
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

    return sectionTitle(title, trailing: trailing);
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
    if (_selected.isEmpty) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }

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
          // Left to appear on scrolling: pinned, it drew a bar beside two rows
          // that had nowhere to scroll to.
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
                contentPadding: rowPadding,
                title: Text(
                  item.relativePath,
                  style: tsNormal,
                  overflow: TextOverflow.ellipsis,
                ),
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
                  icon: Icon(Icons.close, color: clTextMuted, size: 20),
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
      trailing: sectionButton(
        Icons.add,
        tooltip: lw('Add device'),
        onTap: _addManualDevice,
      ),
    );
  }

  // The receive folder is one tap away wherever the transfers are listed, so
  // the section header stays on screen even with nothing in it yet.
  Widget _buildTransfersHeader() {
    return sectionTitle(
      lw('Transfers'),
      trailing: sectionButton(
        Icons.folder_open,
        tooltip: lw('Open the receive folder'),
        onTap: _openRecvFolder,
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
          contentPadding: rowPadding,
          leading: _deviceIcon(device, isTarget),
          title: Text(device.name, style: tsNormal),
          // Nothing but the address: being offline is said by the icon.
          // Dropped altogether when there is no address, rather than leaving an
          // empty line under the name.
          subtitle: device.address.isEmpty
              ? null
              : Text(
                  '${device.address}:${device.port}',
                  style: TextStyle(
                    fontSize: fsSmall,
                    color: device.online ? clText : clTextMuted,
                  ),
                ),
          trailing: device.manual
              ? IconButton(
                  icon: Icon(Icons.close, color: clTextMuted, size: 20),
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
              ? () => setState(
                  () => _target = _target?.id == device.id ? null : device,
                )
              : null,
        );
      },
    );
  }

  Widget _deviceIcon(Device device, bool isTarget) {
    final bool phone = device.platform == 'android';
    final IconData icon = deviceRowIcon(phone: phone, online: device.online);
    if (!device.online) {
      // Still spelled out for anyone who asks: an unreachable device cannot be
      // picked, and a dead row with no explanation is worse than a long one.
      //
      // A device that said goodbye gets the filled badge the reachable ones get,
      // in amber instead of green: the struck-through icon inside still says
      // unreachable, and only the badge carries which of the two silences this
      // is. Tinting the outline instead was invisible — a hue in a 20 px line
      // reads as no change at all.
      //
      // The icon is read off the badge rather than painted in the background
      // colour the green one uses: this badge is light on purpose, and a light
      // icon on it would disappear the same way the tinted outline did.
      if (device.departed) {
        return Tooltip(
          message: lw('exited'),
          child: CircleAvatar(
            radius: 16,
            backgroundColor: clDeparted,
            child: Icon(icon, color: onColor(clDeparted), size: 18),
          ),
        );
      }
      return Tooltip(
        message: lw('offline'),
        child: Icon(icon, color: clTextMuted),
      );
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
    final FileItem? currentFile = t.currentIndex < t.files.length
        ? t.files[t.currentIndex]
        : null;
    final int? eta = t.etaSeconds;

    return InkWell(
      onTap: () => _openTransferLog(t),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  t.incoming ? Icons.download : Icons.upload,
                  size: 18,
                  color: clText,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    t.peerName,
                    style: tsNormal,
                    overflow: TextOverflow.ellipsis,
                  ),
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
                          constraints: const BoxConstraints.tightFor(
                            width: 32,
                            height: 24,
                          ),
                          icon: Icon(Icons.close, color: clTextMuted, size: 20),
                          tooltip: lw('Remove'),
                          onPressed: () {
                            xvTransfers.remove(t);
                            transfersChanged();
                          },
                        ),
                ),
                if (_canRetry(t))
                  TextButton(
                    onPressed:
                        retryEnabled(
                          senderBusy: sender.busy,
                          anyTransferRunning: _running != null,
                        )
                        ? () => _retryTransfer(t)
                        : null,
                    child: Text(lw('Retry')),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // The bar already says red; the line under it says the same, so the
            // reason is not read as an ordinary status.
            Text(
              _transferSubtitle(t, currentFile, eta),
              style: t.status == TransferStatus.failed
                  ? tsSmall.copyWith(color: clError, fontWeight: fwBold)
                  : tsSmall,
            ),
          ],
        ),
      ),
    );
  }

  bool _canRetry(TransferSession transfer) =>
      !transfer.incoming &&
      (transfer.status == TransferStatus.partial ||
          transfer.status == TransferStatus.failed) &&
      transfer.files.any((file) => !file.done && file.sourcePath != null);

  Future<void> _retryTransfer(TransferSession transfer) async {
    final int peerIndex = xvDevices.indexWhere(
      (device) => device.id == transfer.peerId,
    );
    if (peerIndex < 0 || !xvDevices[peerIndex].online) {
      okInfoBarRed(lw('Device is offline'));
      return;
    }
    final snapshots = snapshotFiles(transfer.files.where((file) => !file.done));
    final restored = await restoreFileSnapshot(snapshots);
    if (!mounted) return;
    if (restored.files.isEmpty) {
      okInfoBarRed(lw('Files are no longer there'));
      return;
    }
    if (restored.missing > 0) {
      okInfoBarOrange(lw('Some files are no longer there'));
    }
    final List<FileItem> batch = restored.files;
    await sender.send(peer: xvDevices[peerIndex], files: batch);
    // _pruneSentFiles cannot see this one: it recognises delivered files by
    // identity, and these are rebuilt objects. Without this a file that has just
    // arrived stays in the picked list, and the next Send sends it again.
    _dropDelivered(batch);
  }

  void _dropDelivered(List<FileItem> batch) {
    if (!mounted) return;
    final List<FileItem> left = withoutDelivered(_selected, batch);
    if (left.length == _selected.length) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(left);
    });
  }

  // Tapping a row opens its log. It used to open the received file or folder,
  // which the folder button in the section heading already does, and only ever
  // worked on incoming rows — half the list did nothing at all.
  Future<void> _openTransferLog(TransferSession transfer) async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => TransferLogScreen(transfer)),
    );
  }

  // The bar carries the outcome at a glance: red went wrong, grey was stopped
  // on purpose, green finished.
  Color _progressColor(TransferSession t) {
    switch (t.status) {
      case TransferStatus.failed:
        return clError;
      case TransferStatus.cancelled:
        return clTextMuted;
      // The outcome of an operation, not the presence of a device: they share a
      // value in every palette today, but they are two different meanings and
      // the palette is free to tell them apart.
      case TransferStatus.done:
        return clSuccess;
      // Every file is here, and something still went wrong: neither the green
      // of a clean finish nor the red of a failure. A hue of its own, because
      // every other state of this bar is warm and a warning tone would read as
      // a transfer still running.
      case TransferStatus.unconfirmed:
        return clUnconfirmed;
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
        final String direction = t.incoming ? lw('Received') : lw('Sent');
        // A partial transfer knows why only when something told it; counts
        // alone leave the user guessing at what to do about it.
        final String why = t.error == null ? '' : ' — ${t.error}';
        return '$direction ${t.doneCount}/${t.files.length}, ${lw('failed')}: ${t.failedCount}$why';
      // Everything arrived; only the closing handshake did not. The count comes
      // first because it is the answer to "did my files get there", and the
      // caveat after it, rather than a bare status that answers neither.
      case TransferStatus.unconfirmed:
        final String direction = t.incoming ? lw('Received') : lw('Sent');
        return '$direction: ${t.doneCount} — ${formatBytes(t.bytesTotal)}. '
            '${lw('The sender did not confirm the transfer')}';
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

  // Sits beside the button that acts on it, always on screen so the mode can be
  // read before pressing rather than discovered afterwards. It is a decision
  // about one batch, so it is cleared once the transfer is over: the next send
  // has to ask for it again instead of quietly deleting a second set of files.
  Widget _buildMoveTick() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _moveTickRow(
          value: _move,
          label: lw('Delete originals'),
          onChanged: (bool v) => setState(() {
            _move = v;
            // The folders tick means nothing on its own, so it goes down with
            // the mode it qualifies rather than waiting, ticked, for a move
            // nobody asked for yet.
            if (!v) _moveFolders = false;
          }),
        ),
        // Only ever a qualifier on the tick above: with originals kept there is
        // nothing to empty, so it is shown greyed rather than hidden, and the
        // pair reads as one decision with two levels.
        _moveTickRow(
          value: _moveFolders,
          label: lw('Including folders'),
          enabled: _move,
          onChanged: (bool v) => setState(() => _moveFolders = v),
        ),
      ],
    );
  }

  Widget _moveTickRow({
    required bool value,
    required String label,
    required void Function(bool) onChanged,
    bool enabled = true,
  }) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(btnRadius),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Checkbox(
            value: value,
            activeColor: clAccent,
            checkColor: onColor(clAccent),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: enabled ? (bool? v) => onChanged(v ?? false) : null,
          ),
          const SizedBox(width: 4),
          // Wrapped rather than laid out in one line: at body size the label
          // would take a fifth of the width away from the button beside it.
          // Wide enough that the shorter, qualifying label stays on one line
          // even when the system scales text up a step — broken after its first
          // word it read as two separate options rather than one.
          SizedBox(
            width: 100,
            child: Text(
              label,
              // Dimmed from the theme's own text colour rather than a fixed
              // grey, so it stays legible in the dark palettes too.
              style: enabled
                  ? tsNormal
                  : tsNormal.copyWith(color: clText.withValues(alpha: 0.45)),
              maxLines: 2,
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildSendButton() {
    final SendButtonMode mode = sendButtonMode(
      transferRunning: _running != null,
      senderBusy: sender.busy,
    );
    final bool ending = mode != SendButtonMode.send;
    // The count and the size are in the Selected heading already; what the
    // button has to say is what pressing it does, and with the tick on that is
    // no longer sending.
    final String label = switch (mode) {
      SendButtonMode.stop => lw('Stop'),
      SendButtonMode.stopping => lw('Stopping'),
      SendButtonMode.send => _move ? lw('Move') : lw('Send'),
    };
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(
          children: [
            _buildMoveTick(),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton(
                // Never disabled: a transfer in flight has already turned this
                // into Stop, and with a piece still missing the button says
                // which one it is instead of sitting there grey and mute.
                // Pressing it while the stop is still unwinding asks again,
                // which costs nothing.
                onPressed: ending ? _stop : _sendOrPickTarget,
                style: ElevatedButton.styleFrom(
                  // Grey while a target is still missing: pressing it then only
                  // asks for one.
                  backgroundColor: ending
                      ? clError
                      : _canSend
                      ? clAccent
                      : clFrame.withValues(alpha: 0.3),
                  // Said outright, because the defaults are not the same on
                  // both platforms: ThemeData takes visualDensity and
                  // materialTapTargetSize from the platform, so the same code
                  // gave Android a 48 px button and Linux a 41 px one. This is
                  // the main action of the app and keeps one height everywhere.
                  minimumSize: const Size.fromHeight(56),
                  visualDensity: VisualDensity.standard,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(btnRadius),
                  ),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: fsLarge,
                    // Whatever the button is painted with decides the
                    // lettering: an accent light enough for dark text is a
                    // valid palette.
                    color: ending
                        ? onColor(clError)
                        : _canSend
                        ? onColor(clAccent)
                        : clText,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
