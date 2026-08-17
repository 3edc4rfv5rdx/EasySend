# EasySend — audit of discovery, the local transfer slot, and the never-audited files, 2026-08-17

Scope was named by the user: `lib/net_discovery.dart`, the "one transfer at a time
in either direction" rule as it is enforced on this device, and the four files no
previous audit read — `lib/ui_helpers.dart`, `lib/android_helpers.dart`,
`lib/settings_screen.dart`, `lib/log_screen.dart`, `lib/main.dart`.

Product contract: `SPEC.md` as of this commit (5.2 discovery, 5.4 manual devices,
5.7 mandatory receiver checks, 7 Android specifics, 9 the accepted security
limits), plus `ADD/tofix1.md`…`ADD/tofix7.md`, all of whose findings are marked
fixed or accepted.

Baseline: working tree clean at `af6dbe1` (build 112), `05-Lint.sh` clean,
`06-Test.sh` 346 tests green.

Everything below is a code fact read off the current source, with the file, the
line and the expression named. Nothing here was reproduced on hardware: this
desktop is wired-only on another subnet and cannot exchange discovery traffic with
the phone, so every claim about what a peer would see is reasoned from the code.
Findings 4 and 7 additionally rest on an empirical assumption, labelled in place.

## System model

**Who owns what.** `xvDevices` (in `settings_helpers.dart`) is one global list
mutated by four writers: `DiscoveryService._touchDevice` / `_noteDeparture` (UDP),
`ManualPoller._pollOne` / `verifyIdentity` / `addByAddress` (HTTP), the receiver's
`learnSenderAddress` (an accepted incoming transfer), and the UI (adding and
removing by hand, revoking trust). Only `manual` and `trusted` entries are
persisted. Freshness is judged by one clock, `xvNow` (`globals.dart`).

`ReceiveServer` owns the single receive slot: `_preparing` from the moment a
`prepare` arrives, then `_current` for the session, exposed as `receiveSlotHeld`.
`SendService` owns the single outgoing transfer, exposed as `busy`. Both push rows
into `xvTransfers`, which the screen renders and the Android service mirrors.

**Lifecycle of the main operation.** prepare → consent (dialog or notification,
30 s) → per file: upload, verify, publish → finish. The consent await is the one
place where the slot is held with nothing in `xvTransfers` to show for it.

**Trust boundaries.** UDP announces (any host on the subnet, unauthenticated),
`/info` answers from a manual address, and the `prepare` manifest. All three go
through `validatedPeerInfo` / the manifest checks for shape and size; none of them
is authenticated, which SPEC 9 accepts for the incoming direction.

**Invariants the product depends on.**

- **I1.** One transfer at a time on this device, in either direction (SPEC 5.7).
- **I2.** A device record's transfer address is only ever changed by evidence the
  user can see: their own editing, or an exchange with that device.
- **I3.** A list row is either backed by something that keeps it honest — announces
  or polling — or it is dropped.
- **I4.** What the settings screen shows is what the app currently believes.
- **I5.** A notification on screen answers to something that still exists.
- **I6.** `manual` and `trusted` records are never evicted by UDP traffic (SPEC 5.2).

## Findings

### 1. P2 [FIXED e33a1ee] — A forged announce repoints a trusted device, and the next Send goes to the forger

**Affected components:** `lib/net_discovery.dart` — `_touchDevice()` (the
`else` branch, lines 475-482), `_onEvent()`; `_noteDeparture()` for the contrast;
`lib/home_screen.dart` `_send()`; SPEC 5.2, SPEC 5.4, SPEC 9.

**Current behavior and reproduction:** an announce for an id that is already in
the list overwrites the whole record without any check of where it came from:

```dart
} else {
  final Device device = xvDevices[index];
  device.name = name;
  device.platform = platform;
  device.address = address;   // net_discovery.dart:478
  device.port = port;         // net_discovery.dart:479
```

Any host on the subnet that knows a listed `id` — it travels in every announce in
clear text, five seconds apart — can send one packet carrying that id and its own
address. The row keeps its name and its trust, and points at the forger. The next
transfer the user starts to that row uploads their files there: `_send()` dials
`peer.address`, and nothing re-checks who answers except for `manual` records,
which go through `verifyIdentity()` first.

The same function is the eviction path for I6-protected records in reverse: a
`manual` record whose address the user typed by hand is silently retyped by a
packet, which SPEC 5.4 does not allow for.

Two doors down, the same file already applies the rule this one is missing:

```dart
// _noteDeparture(), net_discovery.dart
if (device.address != address) { ... return; }   // a bye is believed only from
                                                // the address it is listed at
```

So one subsystem answers "may a packet change this record?" by checking the source
and the other does not. SPEC 9 accepts that a *sender* can be spoofed — the cost
it names is trust on the receiving side — and says nothing about the user's own
outgoing files being redirected.

**Root cause:** I2 is not enforced. Identity is bound to `id`, and `id` is treated
as proof of address, though the protocol offers nothing that ties one to the other.

**Required outcome:** an announce may not silently move a record the user has a
relationship with. A record that is `manual` or `trusted` keeps the address it has
unless the change is confirmed by a channel the forger cannot fake for it (an
`/info` answer from the new address carrying the same id, which is what
`verifyIdentity()` already does), or until the user edits it. A transient
discovered record may keep following announces as it does today. Whatever the
decision, a device whose address changes must not be *sent to* until the identity
at the new address has been confirmed.

**Constraints:** discovery must keep working with no configuration for ordinary
devices whose address changed by DHCP (SPEC 13 item 1) — the answer cannot be to
freeze addresses forever. Trust stays bound to `id`, not to IP (SPEC 5.2). The
admission limits of `_admitNewPeer` and I6 must be preserved. No new UI dialog on
the discovery path: it runs with nobody looking.

**Tests to add:** in `test/discovery_admission_test.dart`, a trusted device listed
at one address receives an announce with the same id from another address, and the
record's `address` is unchanged; the same for a `manual` record; and a transient
discovered record still follows the move if that is the chosen behaviour.

### 2. P2 [FIXED 4de0a13] — The one-transfer rule is enforced against peers but not against the user, in the consent window

**Affected components:** `lib/home_screen.dart` `_canSend` (line 638),
`_sendOrPickTarget()`, `_send()`, `_running` (line 1693); `lib/net_server.dart`
`_prepare()` (the busy check at line 330, the consent await at line 427, the
generation check at line 442), `receiveSlotHeld` (line 218); SPEC 5.7;
`ADD/tofix6.md` finding 5, which closed the other half of this.

**Current behavior and reproduction:** the receiver refuses a second transfer
while this device is sending —

```dart
if (_preparing || _current != null || outgoingTransferRunning()) {   // :330
  return _json(req, {'reason': 'busy'}, status: HttpStatus.conflict);
```

— but the check happens once, before the consent question, and the sending side
has no matching check at all:

```dart
bool get _canSend => _selected.isNotEmpty && _target != null && !sender.busy;
```

`sender.busy` and the selection are all it asks; `receiveServer.receiveSlotHeld`
is consulted only by the settings screen (`settings_screen.dart:156`). So:

1. A peer's `prepare` arrives and parks on the consent question. The slot is held
   (`_preparing == true`) and `xvTransfers` is still empty, so the main button
   still reads Send rather than Stop.
2. The user presses Send. An outgoing transfer starts.
3. The user then accepts the incoming one. `_prepare` resumes, re-checks only
   `generation != _generation` (line 442), never `outgoingTransferRunning()`
   again, and installs the session.

Two transfers now run in opposite directions, which SPEC 5.7 says cannot happen —
and the single Stop button acts on `_running`, the first running row it finds, so
the other one cannot be stopped from the screen at all. That last sentence is the
defect `ADD/tofix6.md` finding 5 was about; it was fixed by making the *receiver*
refuse, which leaves exactly this window open.

The window is short but entirely user-driven: the consent question stands for up
to `acceptTimeoutSec` (30 s), and pressing Send during it is an ordinary thing to
do — the screen gives no sign that a receive is pending.

**Root cause:** I1 is enforced at one door out of two, and the enforcement it does
have is a check before an await rather than a decision held for the whole
operation.

**Required outcome:** while the receive slot is held, this device does not start an
outgoing transfer, and the screen says why rather than failing silently. And a
`prepare` that was accepted while an outgoing transfer started must not install a
session: it answers busy, exactly as it would have before the question.

**Constraints:** the check must be `receiveSlotHeld`, not "is there a row in
`xvTransfers`" — during consent there is no row, which is the whole point.
Declining or timing out the consent must free the slot as it does today, and Send
must work again the moment it does. Do not disable the button: the app's rule is
that pressing it explains what is missing (`_sendOrPickTarget`).

**Tests to add:** a test that `_prepare` answers 409 when an outgoing transfer
started while its consent was pending — drive it with the `askUser` seam already
in `ReceiveServer` and `xvTransfers` holding a running outgoing session; and a
pure-function test for whatever rule the Send path grows, in the shape of
`sendButtonMode()`, covering "receive slot held" as its own reason.

### 3. P3 [FIXED 611c1d8] — With discovery down, stale rows are never forgotten

**Affected components:** `lib/net_discovery.dart` `_tick()` (the early return at
line 167, `_forgetStaleDevices()` at line 170), `stop()`; `lib/home_screen.dart`
`_applyNetworkState()`; SPEC 5.2 ("через минуту убирается из списка").

**Current behavior and reproduction:** forgetting happens only inside the announce
tick, and the tick gives up before it whenever the socket is gone:

```dart
final bool changed = await _reconcileInterfaces();
if (socket == null || _socket != socket) return;   // :167
...
_forgetStaleDevices();                             // :170
```

Discovery is stopped, with the app still on screen and the list still visible, in
several ordinary cases: the receive folder became unwritable or the port is busy,
so `updateReceiverAdvertisement()` took the advertisement down; a port change is
pending; a network transition failed and `_runNetworkTransition` stopped
advertising on purpose. In all of them a discovered device that has since gone
stays in the list indefinitely. It reads offline, so nothing lies outright, but
SPEC promises the row is removed a minute after the silence, and `_dropOfflineTarget`
keeps re-selecting nothing while a dead row remains selectable.

**Root cause:** I3 is tied to the socket rather than to the passage of time. The
list is global state; the only thing that prunes it is a loop that requires a live
socket.

**Required outcome:** a discovered record that has aged past `deviceDropSec` is
dropped whether or not discovery is running, and the list stops holding rows
nothing keeps honest. `manual` and `trusted` records keep their exemption (I6).

**Constraints:** no new timer that runs while the app is off screen — SPEC 7 is
explicit that a backgrounded app with the switch off does nothing. The pruning must
not fire during a transfer in a way that removes the peer of a running session.

**Tests to add:** with `xvNow` stubbed, a discovered record aged past
`deviceDropSec` while `DiscoveryService` was never started is gone after whatever
seam the fix introduces, and a `manual` one of the same age is still there.

### 4. P3 [FIXED 94cf890] — A stale consent notification survives a process death and answers nothing

**Affected components:** `lib/android_helpers.dart` — `initNotifications()` (line
34), `askAcceptViaNotification()` (`_askNotificationId` at line 26, the `show` at
line 147, the cleanup at line 191), `_onNotificationResponse()`; SPEC 7
("Подтверждение при свёрнутом приложении").

**Current behavior and reproduction:** the consent notification is posted with
`ongoing: true` and is cancelled in exactly two places — after the answer and
after the 30-second timeout, both inside the same function call. If the process is
killed while the question is up (SPEC 7 says outright that this happens), the
notification stays on the shade across the kill. The next launch never clears it:
`initNotifications()` only initializes the plugin. Its Accept and Decline buttons
then reach `_onNotificationResponse`, where `_askCompleter` is null:

```dart
final Completer<bool>? completer = _askCompleter;
if (completer == null || completer.isCompleted) return;
```

so the buttons do nothing at all, on a notification that still says files are
waiting. Whether Android keeps an `ongoing` notification across a process death
long enough to matter is an **empirical assumption** — it does across an Activity
death, which is the common case here.

**Root cause:** I5 is not enforced at startup. The notification's lifetime is
owned by a function call, while the notification itself outlives the process.

**Required outcome:** no consent notification is on screen that nothing is waiting
on. A launch clears any leftover before it can be pressed.

**Constraints:** the finished-transfer notification (`_doneNotificationId`) is
deliberately left alone — it is a record of something that did happen. Clearing
must not touch the ongoing foreground-service notification, which belongs to the
Kotlin side.

**Tests to add:** `initNotifications()` cancels the ask notification id; drive it
through the same kind of injectable seam `askAcceptViaNotification` already takes
for `showNotification`, so no plugin is needed in the test.

### 5. P3 [FIXED 081690a] — The settings screen keeps showing the trust list it was opened with

**Affected components:** `lib/settings_screen.dart` — `build()` (line 232,
`xvDevices.where((d) => d.trusted)`), the whole screen has no listener;
`lib/globals.dart` `devicesTick`; SPEC 4 ("Экран настроек").

**Current behavior and reproduction:** the trusted list and its count are computed
in `build()` and nothing rebuilds the screen when `xvDevices` changes. The home
screen subscribes to `devicesTick` (`_netTicks`); this one does not. Two ordinary
events change the list while the screen can be open on top of it: an incoming
transfer accepted with "always trust", and the "Trust after sending" switch
marking a peer trusted after a successful `prepare`. Until the screen is closed and
reopened it shows a count that is out of date — and, with the trust list empty when
it opened, the "No trusted devices" line under a heading that now has entries.

**Root cause:** I4 is not enforced for this screen; the state it renders is global
and mutable, and the screen treats it as a snapshot.

**Required outcome:** the settings screen reflects the device list as it is, the
way the main screen does.

**Constraints:** the rest of the screen must not rebuild more than it has to —
`_addresses` is loaded asynchronously and must not be re-fetched by a device tick.

**Tests to add:** a widget test would be new ground for this project (see
`ADD/tofix5.md` finding 11, accepted); at minimum a contract test asserting the
screen listens to `devicesTick`, in the style of
`test/android_engine_lifetime_contract_test.dart`.

### 6. P3 — ACCEPTED — Four dialog helpers are dead code

**Affected components:** `lib/ui_helpers.dart` — `okInfo()`, `okErr()`,
`okWarning()`, `okSuccess()` (lines 561-584), `okInfoBarPurple()` (line 696) and
`showCustomDialog()`, which only they call apart from
`showNetworkSafetyWarning`'s own dialog.

**Current behavior:** nothing in `lib/` or `test/` calls any of the five. A grep
for each name outside their own definitions comes back empty. `okInfoBarPurple`
also carries a `Duration(days: 3)` snack bar with `DismissDirection.none`, which
would sit on screen until its own OK is pressed — a shape no other message in the
app has.

**Why accepted:** they are a five-function palette of message helpers kept
deliberately symmetric with the snack-bar family beside them, and the project is
one developer's. Deleting them is a judgement call about the shape of the helper
file, not a repair. Written down so the next reading does not file it as a find,
and so that if `okInfoBarPurple` is ever wired up, the three-day duration is
noticed first.

**Cross-reference:** finding 4 touches the other notification lifetime in this
codebase; nothing else here shares code with this item.

### 7. P3 [MEASURED 2026-08-17 — ACCEPTED] — Every announce builds and tears down one socket per interface address

**Affected components:** `lib/net_discovery.dart` `_sendMulticast()`,
`_broadcast()`, `_tick()`; SPEC 5.2.

**Current behavior:** each announce — one every `announceIntervalSec`, i.e. every
5 s, plus one `query` on every interface change — binds a fresh ephemeral socket
for every IPv4 address of every active interface, sends one datagram and closes it:

```dart
for (final NetworkInterface interface in List.of(_interfaces.values)) {
  for (final InternetAddress address in interface.addresses) {
    sender = await RawDatagramSocket.bind(address, 0);
```

On a phone with Wi-Fi and a VPN that is a handful of bind/close pairs every five
seconds, all night, while background receiving is on. That this costs enough to
matter — battery, or a bind that fails under pressure and silently loses that
interface's announce for the cycle — is an **empirical assumption**: nothing here
was measured, and the comment in place explains that per-interface binding is the
documented way around Dart's deprecated `multicastInterface`.

**Root cause:** no invariant is violated. This is a cost that was never measured
against the alternative of holding one socket per interface for as long as
discovery runs.

**Measured, 2026-08-17 — nothing to change.** The empirical assumption above was
tested rather than reasoned about:

- A probe on this desktop ran the exact sequence `_sendMulticast` performs — bind
  an ephemeral socket to the interface address, set `multicastHops`, send one
  datagram to the group, close — 200 times: **30 us per cycle, no failures**. At
  one announce every 5 s that is ~22 ms of CPU per hour with one interface, ~65 ms
  with three.
- On the phone (SM-A366B, build 112, one `wlan0`, no VPN) the app burned **300 ms
  of CPU over a 120 s window** with the screen on — 24 announces in it. That is
  the UI: discovery ticks repaint the device list. The socket work inside the same
  window is ~0.7 ms, an order of magnitude below the 10 ms resolution of
  `/proc/<pid>/stat`, so the phone can only bound the total, not isolate this.
- The wakeup worry does not survive reading: a radio wakeup is caused by the
  datagram leaving, not by where the socket came from. Holding sockets open for
  the life of discovery would save those 30 us per announce and change nothing
  about Doze.

**Still unmeasured:** a `bind` that fails on Android is invisible in a release
build — `myPrint` is compiled out — so "an interface silently loses its announce
for the cycle" would need a debug build on hardware. And the multi-interface case
was not reproducible: the phone had a single `wlan0` with no VPN up.

**If it is ever revisited:** the sockets would outlive a single announce and be
reconciled together with the memberships in `_reconcileInterfaces()`.

**Constraints:** whatever holds sockets must release them on `stop()` and must not
keep an interface's socket after that interface disappears; a bind that fails must
still leave the other interfaces announcing. Measure before changing anything —
see `prove-the-test-fails`.

**Tests to add:** a probe rather than a unit test: count binds per minute on the
desktop with discovery running, and compare against a build that keeps them. Only
then a test that `stop()` leaves no socket behind.
