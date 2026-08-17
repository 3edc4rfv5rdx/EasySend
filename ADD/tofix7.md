# EasySend — open items from the farewell-on-exit work, 2026-08-14

These are the findings left standing after the four commits that added the
`bye` announcement, the "departed" badge, the release of one-run state on exit,
and the extraction of `shutdownForExit()`. They were found while implementing,
verified against the code, and consciously **not** fixed — either because they
were outside what was asked for, or because the right answer is a product
decision rather than a repair.

Baseline: commit `ec41e46` (build 108), working tree clean, 334 tests green.

Everything here is a code fact with a file and an expression, except where a
finding says otherwise. None of them was reproduced on a device: the exit path
is Android-specific and the machine this was written on cannot drive it beyond
`adb`.

All six were re-checked against `ec41e46` before this file was written down, and
none of them is done. Finding 5 was narrowed at that check: part of what it
claimed was untested turned out to be held by an existing contract test, which
it now names.

## Shared root

Three of the six findings come from one platform fact, stated here once:

**On Android the process outlives an exit.** `_exitApp` ends with
`finishActivityAndTask()`, never `exit(0)` — that call is the desktop branch
(`lib/home_screen.dart`, end of `_exitApp`). The Flutter engine belongs to
`EasySendApplication`, so the Dart isolate, every global in `lib/globals.dart`
and every `State` object survive the exit and are inherited by the next launch.
Anything documented as lasting "until the app restarts" is therefore wrong on
Android unless it is released by hand on the way out. `shutdownForExit()` now
does that for the transfer list, the once-a-launch sweeps and the departure
badges; the items below are what it does not cover.

## Findings

### 1. P2 [FIXED e38b324] — The picked file list survives an exit on Android, so a launch can open on a selection the user made yesterday

**Affected components:** `lib/home_screen.dart` — `_selected` (the `State`
field behind the "Nothing selected" section and the Send button),
`shutdownForExit()`; `lib/file_helpers.dart` `clearSessionState()`; SPEC 4
("Главный экран", items 2 and 5).

**Current behavior:** `clearSessionState()` releases `xvTransfers` and the sweep
flags, but `_selected` is a field of `_HomeScreenState`, unreachable from there
and untouched by the exit. Because the isolate survives (see *Shared root*), the
next launch shows the same picked files, with the same sizes read at pick time,
and the Send button live for them.

That list is also what the cache sweep assumes nobody refers to any more:

```dart
// lib/file_helpers.dart, above _copiesSwept
// ... because a copy may still be sitting in the picked list — and that
// list does not survive a restart, so by the next one nothing refers to them.
```

`sweepPickedCopiesOnce()` now runs again on the next launch (that was fixed),
and it deletes the cache directory holding the copies of picked documents. So a
selection that survived the exit can point at files the sweep has just removed:
the row is there, Send is enabled, and the send fails per file with the original
gone.

**What to implement:** release the picked selection as part of the exit, in the
same place the rest of the one-run state is released. Either move the selection
into a global that `clearSessionState()` can reach, or give `shutdownForExit()`
a `clearSelection` callback the way it already takes the stops. Prefer whichever
keeps `shutdownForExit()` free of `State`.

**Constraints not to break:** ✕ with background receiving on is not an exit
(`exitKeepsReceiving` in `lib/globals.dart`) and must keep the selection, along
with everything else — the user is only putting the screen away. The desktop
path must stay indifferent: there the process dies and any release is a no-op.

**Tests to add:** extend `test/exit_shutdown_test.dart` — after
`shutdownForExit()` the selection is empty; and a case asserting that the branch
which keeps receiving never calls it.

### 2. P2 [FIXED b0b3d27] — An exit does not cancel an outgoing send, so on Android it keeps sending after the screen is gone

**Affected components:** `lib/home_screen.dart` `_exitApp` and
`shutdownForExit()`; `lib/net_sender.dart` `SendService.cancel()`;
`lib/globals.dart` `exitNeedsConfirmation()`; SPEC 3.1, SPEC 7.

**Current behavior:** the exit stops the receiver, discovery, the poller and the
foreground service. It never touches `sender`. `sender.cancel()` is called only
from `_stop()` (the Stop button) and from `_stopNetworkAfterServiceTimeout()`.
On desktop this is invisible — `exit(0)` takes the process — but on Android the
send goes on with no screen, no notification (the service was just stopped) and
no way to stop it short of killing the app from the system settings.

The user is asked about it and answers, which makes the current behaviour look
deliberate:

```dart
final bool running = xvTransfers.any((t) => t.isRunning);
... message: running ? '${lw('A transfer is running')}. ${lw('Exit the application')}?' : ...
```

but "Exit?" answered with yes reads as "stop and leave", not "leave it
running invisibly". Note also that the question is asked about `isRunning`
sessions only, while the send service has a documented window where
`sender.busy` is true and no session is running — the comment on
`sendButtonMode()` in `lib/home_screen.dart` describes it for cancellation.
Whether that window can be reached from an exit was not verified; treat this
sentence as a lead, not a fact.

`clearSessionState()` deliberately keeps a running transfer in the list so that
it is not orphaned, which is a symptom of this, not a solution.

**What to implement:** decide and then make it one thing. Either an exit cancels
the send (`await sender.cancel()` inside `shutdownForExit()`, before the stops)
and the confirmation text says so, or the send is meant to continue and the
foreground service must be kept alive for it, with a notification that says a
transfer is still going. The first is the smaller change and matches what the
desktop already does.

**Constraints not to break:** cancelling must go through `sender.cancel()` so
the receiver is told (`/cancel`) instead of being left holding a session that
times out after `receiveSessionTimeoutSec`. Do not cancel on the ✕ path that
keeps receiving. Files already delivered and verified stay delivered.

**Tests to add:** in `test/exit_shutdown_test.dart`, a fake sender records that
cancel was called before the receiver stop; a test that the keep-receiving
branch does not cancel. If the other answer is chosen, a test that the service
is not stopped while `sender.busy`.

### 3. P3 — A goodbye is silently skipped when discovery is already down

**Affected components:** `lib/net_discovery.dart` — `stop()`, `_broadcast()`,
`_farewellUnicast()`, `_sendTo()`.

**Current behavior:** both halves of the farewell go out through the live
socket:

```dart
void _farewellUnicast() { ... _sendTo('bye', address, _port); }
void _sendTo(...) { ... _socket?.send(...); }
Future<void> _broadcast(String type) async {
  final RawDatagramSocket? socket = _socket;
  if (socket == null) return;
```

If discovery was stopped before the exit — the network went away, the receive
folder became unwritable and `updateReceiverAdvertisement` took the
advertisement down, a port change is pending — `_socket` is null and nothing is
sent. Peers then wait out the ordinary timeout, which is exactly the case the
feature exists to remove. It is invisible: `myPrint` is compiled out of release
builds.

This is a real gap but a narrow one, and the timeout is a correct fallback, so
it is P3 rather than P2.

**What to implement:** when `announceLeaving` is asked for and `_socket` is
null, bind a temporary `RawDatagramSocket` on `InternetAddress.anyIPv4:0`, send
the same payload to every listed address and to the broadcast/multicast targets,
and close it. Keep the whole attempt inside a try/catch and inside a short
deadline — an exit must not hang on a socket the OS will not give.

**Constraints not to break:** no farewell may be sent from any stop that is not
a real exit (`announceLeaving` defaults to false and must stay that way). The
payload must remain `buildDiscoveryPayload(type: 'bye', ...)` so old builds go
on ignoring it.

**Tests to add:** in `test/discovery_interface_reconciliation_test.dart`, stop a
service that was never started with `announceLeaving: true` and assert the
unicast override still saw a `bye` for every listed address.

### 4. P3 — The departure badge is written by an injectable clock and read by the wall clock

**Affected components:** `lib/models.dart` `Device.departed` /
`Device.departedAt`; `lib/net_discovery.dart` `_noteDeparture()` (writes
`_now()`), `DiscoveryService({DateTime Function()? now})`.

**Current behavior:** the write side honours the injected clock, the read side
does not:

```dart
device.departedAt = _now();                                   // net_discovery.dart
return DateTime.now().difference(left).inSeconds <= departedNoticeSec;  // models.dart
```

With a stubbed clock the two disagree by however far the stub is from now, so
`departed` reads false immediately after a departure. `test/discovery_admission_test.dart`
works around this by using `DateTime.now()` in the bye tests, which is a test
bending to a defect rather than the other way round. `Device.online` has the
same shape, so this is a pre-existing pattern, not something the badge
introduced.

**What to implement:** give the model one clock. Either pass a
`DateTime Function()` into `Device` (and default it to `DateTime.now`), or move
both `departed` and `online` behind functions that take `now` as an argument and
let the callers supply it.

**Constraints not to break:** `departedAt` and `lastSeen` must stay out of
`toJson()` — a launch knows nothing about how anyone left, and a device is
online only if it answers now.

**Tests to add:** the bye tests in `test/discovery_admission_test.dart` return
to a stubbed clock and assert the badge expires exactly at `departedNoticeSec`.

### 5. P3 — Part of `_exitApp` before the shutdown is untested — but less of it than it looks

**Affected components:** `lib/home_screen.dart` `_exitApp` (the confirmation,
`_exiting`, `_networkDesired`, `_networkEpoch`, the window-bounds save, the
platform ending).

**Already covered — do not redo this part.** The keep-receiving branch is held
in place by a contract test that reads the source:
`test/android_engine_lifetime_contract_test.dart` (the block matched by
`RegExp(r'if \(exitKeepsReceiving\((.*?)\n      return;')`) asserts that the
branch returns before anything else, that it contains `SystemNavigator.pop()`
and `androidService.reassert()`, and that it does **not** call
`finishActivityAndTask` — the Recents card has to stay. The rule itself is a
table test in `test/network_lifecycle_test.dart` (around lines 305-330), and
`shutdownForExit()` is covered by `test/exit_shutdown_test.dart`.

**Current behavior:** what no test reaches is the rest of the wiring: that
`_exiting` is set before the first `await` (a lifecycle event arriving mid-exit
used to restart the network), that the confirmation is asked exactly when
`exitNeedsConfirmation()` says so and a "no" leaves everything running, and that
the debounced window bounds are flushed before the process ends.

**What to implement:** lift the decision into a pure function — given platform,
`mayKeepReceiving`, the two settings, whether a transfer runs and the user's
answer, return an enum: `keepReceiving`, `shutDown`, `stay`. `_exitApp` then
reads as a switch over it. Keep the shape the contract test above matches, or
update that test in the same change: it reads the source text, so a refactor
that is correct in every other way still breaks it.

**Constraints not to break:** the order inside `_exitApp` is load-bearing and is
documented in place: `_exiting = true` before the first await, and the debounced
window save flushed before the process ends.

**Tests to add:** a table test over the new enum covering the eight
combinations, including a running transfer answered with "no".

### 6. P3 — SPEC says the badge lasts exactly as long as the row, and it is a second longer

**Affected components:** `lib/globals.dart` `departedNoticeSec` (60);
`lib/net_discovery.dart` `lastSeenAfterBye()` (backdates by
`max(deviceTimeoutSec, manualPollSec * 2) + 1` = 21 s) and
`_forgetStaleDevices()` (drops at `> deviceTimeoutSec + 60`, i.e. 80 s after
`lastSeen`); SPEC 4 item 3.

**Current behavior:** a discovered device that says goodbye is dropped from the
list 80 − 21 = **59 s** after the bye, while its badge is defined to last
**60 s**. So the row disappears one second before the badge would have expired,
and SPEC claims the two windows are the same ("столько же, сколько строка
автоматически найденного устройства живёт после ухода"). Nothing misbehaves —
the row is simply gone first — but the two constants are related by arithmetic
nobody stated.

**What to implement:** derive one from the other instead of writing 60 twice.
For example define the drop delay as `departedNoticeSec` and have
`_forgetStaleDevices()` use `deviceTimeoutSec + departedNoticeSec`, then say in
SPEC that the badge outlives the row by exactly the backdating.

**Constraints not to break:** manual and trusted devices are never dropped from
the list, whatever their `lastSeen` (`_forgetStaleDevices` returns early for
them). The backdating must keep pushing `lastSeen` past **both** windows —
announce and manual poll — or a manual device would still read as online.

**Tests to add:** a test that a discovered device which said goodbye is still
listed at `departedNoticeSec - 1` seconds and gone at the documented moment,
driven by `tickNow()`.
