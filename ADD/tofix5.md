# EasySend deep code audit — 2026-08-13

This audit reads `lib/` in full, the Kotlin under `android/app/src/main/kotlin/`,
and the Android manifest, against `SPEC.md`, `README.md` and the 244 executable
tests (all green at the time of writing, commit `d306450`). It does not repeat
resolved prompts from `ADD/tofix1.md` … `ADD/tofix4.md`; where an earlier repair
narrowed a problem without closing it, the remaining window is stated.

Every finding below was verified against the current code. Two were measured
with a throw-away probe rather than reasoned about, and say so. Findings that
rest on an assumption about how often a condition occurs are labelled.

## System model and invariants

- `HomeScreen` owns the desired network state and serializes every transition
  through `_networkQueue` + `_networkEpoch`. `ReceiveServer`, `SendService`,
  `DiscoveryService` and `ManualPoller` own their own mutable workflows. On
  Android the Dart isolate lives in an `Application`-owned Flutter engine and
  outlives any Activity.
- A send is prepare → sequential upload → verify per file → finish. The receiver
  holds exactly one consent/session slot and one file operation at a time; a
  file becomes real only when its CRC matches and it is renamed out of the
  session's incomplete directory.
- Untrusted input crosses into the receiver at `/api/v1/*` (manifest paths,
  sizes, ids, names) and at UDP discovery (announce/query payloads). Both are
  bounded by `validatedPeerInfo`, `sanitizeRelPath`, `buildDestinationPlan` and
  the size/count constants in `globals.dart`.
- Persistent state is `settings.json` (settings, manual + trusted devices) and
  the incomplete-session registry under the config directory. Nothing else
  survives a restart; transfers and their logs are memory-only by design.

Invariants this audit measured against:

1. Untrusted input bounds the *work* the receiver does, not only the data it
   accepts — including work done before consent.
2. A transfer's log accounts for every file: what the cap drops is only lines
   with nothing to report, and what it dropped is stated.
3. Persistent device state changes only on a user decision, never as a side
   effect of a request the user refused.
4. A resource acquired for the foreground is released when the app leaves it.
5. Both ends of a transfer describe the same outcome, and a row's own numbers
   agree with its status.
6. Deleting a source deletes the object the user picked.

## Findings

### 1. P1 [FIXED 42b34ee] — A maximum-size manifest freezes the receiver for half a second before the consent question appears

**Affected components:** `lib/file_helpers.dart` (`buildDestinationPlan`, the
`safePaths` double loop at the `other.startsWith('$key/')` comparison),
`lib/net_server.dart` (`_prepare`, the `buildDestinationPlan` call that precedes
`_askAccept`), SPEC 5.7, `test/manifest_plan_test.dart`.

**Current behavior and reproduction:** `buildDestinationPlan` detects
file-versus-directory conflicts with a full `O(n²)` scan: for every pair `(i, j)`
it recomputes `foldCase ? safePaths[j].toLowerCase() : safePaths[j]` *inside* the
inner loop and calls `startsWith`. `maxManifestFiles` is 3000, so an ordinary
camera-folder transfer reaches 9,000,000 iterations. The loop is fully
synchronous — it contains no `await` — so it occupies the single Dart event loop
outright: the receiver's UI does not repaint, no other request is served, and
the consent dialog has not been shown yet.

Measured with a probe over 3000 realistic manifest paths
(`Camera/2026/08/IMG_000000.jpg`) in the project's own test VM:

| files | case-sensitive (Linux/Android) | case-folding (Windows) |
|---|---|---|
| 500 | 18 ms | 19 ms |
| 1500 | 99 ms | 160 ms |
| 3000 | 393 ms | 630 ms |

An AOT phone build will be in the same order, and this cost is paid before the
user is asked anything. `_prepare` serializes on `_preparing`, so a peer that
repeats a 3000-entry manifest holds the receiver's event loop at close to full
occupancy for as long as it likes without ever being accepted.

**Root cause:** A pairwise scan is used for a question that is a prefix lookup.
Invariant 1 is broken: the manifest's *size* is bounded, but the work it buys is
quadratic in that bound, and it is spent before consent rather than after.

**Required outcome:** The file/directory conflict check must be linear in the
number of entries times their depth. Build one set of the case-folded entry keys,
then for each entry walk its own parent prefixes (`a/b/c` → `a/b`, `a`) and
reject when a prefix is itself an entry. Case folding is computed once per entry,
not once per pair. The refusal reason and status stay exactly as they are.

**Constraints:** Keep refusing `file/directory path conflict` for every manifest
the current code refuses, including the Windows case-insensitive collisions and
the `'/'`-on-the-wire comparison that must not go through the host separator.
Keep the duplicate/empty-id check, the `sanitizeRelPath` refusal, and the order
in which `DestinationPlanException` reasons are produced. Do not raise or lower
`maxManifestFiles`.

**Tests to add:** In `test/manifest_plan_test.dart`: a 3000-entry manifest with
no conflict must plan in well under 100 ms (assert on a `Stopwatch`, generous
enough not to flake on CI), proving the quadratic behaviour is gone; the
existing conflict cases (`a` + `a/b`, and the Windows-folded `A` + `a/b`) must
still throw `file/directory path conflict`; and a conflict at depth 3
(`x/y` + `x/y/z`) must be caught by the prefix walk.

---

### 2. P1 [FIXED 6a9075a] — A transfer whose log is all failures silently throws failures away and says nothing was lost

**Affected components:** `lib/models.dart` (`TransferSession.log`, the
`events.removeAt(quiet < 0 ? 0 : quiet)` branch and the guarded `quietFiles++`),
`quietFilesLine`, `lib/log_screen.dart`, SPEC 4 ("Отказы, отмены, таймауты и
удаление оригинала при переносе не выбрасываются никогда" and "Сколько файлов
лишились своей строки, сказано последней строкой лога"),
`test/transfer_log_test.dart`.

**Current behavior and reproduction:** When `events` exceeds
`maxTransferEvents` (500), `log()` looks for the oldest `routine` line and
removes it, incrementing `quietFiles`. When there is no routine line left it
removes `events[0]` — whatever it says — and deliberately does **not** increment
`quietFiles`. So once 500 non-routine lines have accumulated, every further line
silently evicts the oldest failure, and `quietFilesLine()` returns `null`,
telling the reader that nothing was trimmed.

Measured with a probe: 550 `failure: true` lines into one session leaves
`events.length == 500`, `quietFiles == 0`, `quietFilesLine() == null`, and the
first surviving line is the 51st — fifty failure lines gone without a trace.

This is easy to reach in normal use, not only under attack. A send to a receiver
that rejects checksums writes up to three `Checksum did not match` lines plus one
`Not sent` line per file, all non-routine: about 125 files fill the log, and
every file after that costs the log its oldest failure. The screen and the copied
text then start mid-transfer, which is precisely what the cap was written to
prevent, and the log claims to be complete.

**Root cause:** The fallback eviction was written as a safety valve and given no
accounting, so invariant 2 holds only while at least one routine line exists.
The two spec promises — failures are never dropped, and whatever is dropped is
counted — are both broken by the same branch.

**Required outcome:** A full log must never lose a failure line without saying
so. Preferred shape: when no routine line remains, still drop the oldest line,
but count it, and make the closing line distinguish the two kinds — the count of
files that went through without a word, and the count of lines the cap had to
drop anyway. The log screen and `transferLogText` must show the same closing
information, and the count must be readable from `TransferSession` for tests.

**Constraints:** The cap stays at `maxTransferEvents`; the log stays in memory
and unpersisted; the oldest routine line is still the first thing dropped;
`formatTransferEvent` and the header are unchanged; every new string is added
to all three locales, punctuation in code (SPEC 8). Do not grow the log to hold
every failure of a three-thousand-file transfer.

**Tests to add:** In `test/transfer_log_test.dart`: filling a session with
`maxTransferEvents + 50` failure-only lines must leave a non-null closing line
whose count is 50, and `transferLogText` must contain it; a mixed log must still
drop routine lines first and only start dropping failures once the routine lines
are exhausted; a log that has never overflowed must still produce no closing
line at all.

---

### 3. P1 [FIXED ab07208] — Manual devices keep being polled over HTTP every 10 seconds while the app is off screen

**Affected components:** `lib/home_screen.dart` (`_setNetworkDesired`'s
early return, `didChangeAppLifecycleState`, `_applyNetworkState`'s
`manualPoller.start()`), `lib/net_discovery.dart` (`ManualPoller.start` /
`_pollAll`), SPEC 5.4 ("Опрос идёт только пока приложение на переднем плане,
чтобы не будить сеть впустую"), SPEC 7 (Doze).

**Current behavior and reproduction:** `manualPoller.start()` is called only
from `_applyNetworkState`, which runs only when a *transition* is queued.
`_setNetworkDesired` returns immediately when the desired state has not changed.
With "Receive in background" on, `networkDesiredFor` answers `true` for
`paused`, `hidden` and `detached` alike, so backgrounding the app changes
nothing, no transition is queued, and the poller's `Timer.periodic` keeps firing
every `manualPollSec` (10 s) for the whole time the app is away — issuing a
`GET /api/v1/info` to every manual device at once, with the screen off, exactly
what SPEC 5.4 says must not happen.

With "Receive in background" off the behaviour is correct: `paused` gives
`desired == false`, a transition runs, and `manualPoller.stop()` is reached.

Two lesser problems live in the same object: `ManualPoller._client` is created in
the constructor and never closed, and `_pollAll` fans out to every manual device
with `Future.wait` regardless of whether anything is waiting for the answer.

**Root cause:** Manual polling was attached to the network-transition state
machine, which models "should this device be reachable", while SPEC 5.4 attaches
it to a different question — "is anyone looking at the device list". The two
answers coincide only while background receiving is off. Invariant 4 is broken:
a foreground-only resource is held in the background.

**Required outcome:** Manual polling must follow foreground visibility, not the
desired network state. Starting it belongs where `resumed` is observed and
stopping it where the app leaves the screen, independently of the "Receive in
background" switch and independently of the receive server, which must keep
listening. A poll already in flight when the app leaves may finish; no new pass
may start.

**Constraints:** Keep manual devices visible while offline and keep their `✕`
(SPEC 5.4); keep `verifyIdentity` working for an outgoing send whatever the
lifecycle state, since a send is initiated from the foreground anyway; keep
`Device.online`'s `manualPollSec * 2` window meaningful when the app comes back
— a device must not be shown as reachable on the strength of a poll from before
the app was backgrounded. Do not stop discovery or the receive server as part of
this change.

**Tests to add:** A test over the lifecycle rule (the pure-function level, as
`networkDesiredFor` is tested today): with background receiving on, `paused`
must stop manual polling while leaving the desired network state `true`;
`resumed` must start it again. In `test/network_lifecycle_test.dart`, drive
`HomeScreen`'s decision function and assert `manualPoller.polling` /
started-state, not wall-clock timing.

---

### 4. P2 [FIXED 3a84bb9] — Declining an incoming transfer still converts the sender into a permanent, polled, "manual" device

**Affected components:** `lib/net_server.dart` (`_askAccept`, the
`if (known >= 0)` block: `device.address = address`, `device.port = port`,
`if (!wasOnline) device.manual = true`, `device.lastSeen = DateTime.now()`),
`lib/settings_helpers.dart` (`_saveSettingsNow` persists `manual` devices),
`lib/net_discovery.dart` (`_forgetStaleDevices` never removes a manual device),
SPEC 5.2, 5.4, 5.5.

**Current behavior and reproduction:** Everything above runs *before* the consent
question, and none of it is undone when the answer is no. Take a device that is
already in the list but not currently online — a peer discovered earlier and
gone quiet, which is the ordinary state of a laptop that was closed. It sends
`prepare`. The receiver rewrites its address and port from the connection,
flips `manual` to `true`, stamps `lastSeen` — which makes it render as reachable
and selectable as a send target — and only then asks the user, who declines.

The device is now permanently in the list: `_forgetStaleDevices` refuses to drop
manual entries, `ManualPoller` polls it every 10 s forever, it shows an `✕` as
though the user had typed its address, and the next `saveSettings()` from any
unrelated action (a settings edit, a window move on desktop, adding a device)
writes it to `settings.json`.

**Root cause:** The address-learning step of SPEC 5.5 — "устройство, которое до
этого молчало, помечается как добавленное вручную" — was implemented on the
arrival of the request rather than on its acceptance. Invariant 3 is broken:
unauthenticated remote input changes persistent device state through a decision
the user explicitly refused.

**Required outcome:** Learning a peer's return address and promoting it to
manual must happen only once the transfer is accepted — by trust or by the
user's answer. A declined `prepare` must leave the device list exactly as it
was: same `manual`, same `lastSeen`, same address and port. A trusted sender
keeps today's behaviour, since acceptance is immediate there.

**Constraints:** Keep the SPEC 5.5 guarantee that a trusted device behind a
router learns its return address from the connection, and that a device accepted
with "Always trust" is added with `manual` set when its address is reachable.
Keep the loopback/self-send handling (`isReachableAddress`, `senderId ==
xvDeviceId`). Keep the one-slot `_preparing` reservation and the generation
check that drops a consent answered after the server stopped.

**Tests to add:** In `test/discovery_admission_test.dart` or a new
`test/prepare_consent_effects_test.dart`: a `prepare` from an id already in the
list that is declined leaves `manual`, `lastSeen`, `address` and `port`
unchanged; the same `prepare` accepted updates them; an accepted `prepare` from
an unknown id with "Always trust" adds the device exactly as it does today; a
declined `prepare` writes nothing to `settings.json`.

---

### 5. P2 [FIXED 07b4ede] — The receive folder can be changed out from under a transfer that is waiting for consent

**Affected components:** `lib/settings_screen.dart` (`_receiving` and both
`_editRecvFolder` guards), `lib/net_server.dart` (`_prepare` captures
`recvDir = xvRecvDir` and `root` before `_askAccept`; the `TransferSession` is
created only after the answer), SPEC 3.2, SPEC 6.

**Current behavior and reproduction:** `_receiving` is
`xvTransfers.any((t) => t.incoming && t.isRunning)`. During the consent window
there is no `TransferSession` at all — `_prepare` adds it to `xvTransfers` only
after `_askAccept` returns true — so `_receiving` is false and both guards let
the folder be changed. Sequence: a sender's `prepare` puts the accept dialog or
notification on screen; the user opens Settings and picks a new receive folder
(the guard passes, `canWriteInto` passes, `xvRecvDir` and the setting are
updated); the user then accepts the transfer. The session writes every file into
the *old* folder, because the plan and `_Incoming.recvDir` were resolved before
the change. The row reports "Received: 3" and the folder button in the Transfers
heading opens the new, empty folder.

The 30-second consent deadline bounds the window, and the accept notification
path makes it reachable without the user ever seeing a dialog.

**Root cause:** The guard tests for a *running transfer* while the thing it must
protect is a *reserved receive slot*, which is taken from the moment `_prepare`
sets `_preparing`. Nothing else notices the gap, because writing into the
captured folder is deliberate and correct once the session exists.

**Required outcome:** Changing the receive folder must be refused for the whole
time the receive slot is held, consent window included — the same orange line
the guard already shows. Expose the reserved-slot state from `ReceiveServer`
(the slot is already tracked by `_preparing` and `_current`) and ask that rather
than scanning `xvTransfers`. Re-check it after the folder picker closes, as the
current code already does.

**Constraints:** Keep the session's own captured folder authoritative for a
session in flight — a session must never be re-pointed at a newer root. Keep the
folder change working freely when nothing is being received. Do not make the
receive server reject `prepare` while the settings screen is open. Keep
`canWriteInto` validation and the existing orange message; no new locale strings
should be needed.

**Tests to add:** In `test/receive_folder_test.dart`: with a `prepare` parked on
an unanswered consent (the test hook `askUser` already holds the answer back),
the receive-folder guard must report busy; once the consent is declined and the
slot is released, it must allow the change; with a session active the guard must
still report busy, as today.

---

### 6. P2 [FIXED 419624e] — A manual device that is simply switched off is reported as "Device identity changed"

**Affected components:** `lib/net_sender.dart` (`send`, the
`if (peer.manual && !await manualPoller.verifyIdentity(peer))` branch and
`_fail(transfer, lw('Device identity changed'))`), `lib/net_discovery.dart`
(`ManualPoller.verifyIdentity`, `_ask` returning `null` on any transport
failure), `test/manual_identity_test.dart`.

**Current behavior and reproduction:** `verifyIdentity` folds three different
outcomes into one `false`: the peer answered with a different id (DHCP handed
the address to somebody else — the case the check exists for), the peer answered
something unusable, and the peer did not answer at all. `_ask` returns `null`
for every connect refusal, timeout and unreadable body. So sending to a manual
device that is merely powered off, asleep, or behind a firewall fails with
"Device identity changed" — a sentence that tells the user their trust
relationship is broken when in fact nothing is wrong but the network.

The device is shown as offline in the list at that point, but Send is not
disabled for manual devices in every path (`_sendOrPickTarget` only requires a
target), and the poll window is 20 s wide, so the case is ordinary rather than
rare.

**Root cause:** One boolean is asked to carry two facts. Invariant 5 in
miniature: the row says something the code does not actually know.

**Required outcome:** `verifyIdentity` must distinguish "unreachable" from
"answered with a different id", and the send must say which one happened — an
existing unreachable/offline message for the first, the current identity message
only for the second. `lastSeen` must still be cleared in both cases: neither
outcome proves the device is there.

**Constraints:** Keep refusing to send when the id does not match — that check is
the whole point and must not be weakened into a warning. Keep the poll timeouts
(`manualPollTimeoutSec`, and the `timeout * 3` whole-exchange deadline). Any new
string goes into all three locales, punctuation in code (SPEC 8); reuse
`Device is offline`, already present, if it fits.

**Tests to add:** In `test/manual_identity_test.dart`: a peer that answers with a
different id fails the send with the identity message; a peer whose port is
closed fails it with the unreachable message; a peer that answers correctly
sends; `lastSeen` is null after both failures.

---

### 7. P2 [FIXED f2bf439] — A rejected `finish` leaves a row reading "Sent 3/3, failed: 0" with no way to act on it, and the two ends disagree

**Affected components:** `lib/net_sender.dart` (`send`: `transfer.status =
finished && transfer.failedCount == 0 ? done : partial`, and the `move` block
that runs afterwards; `_finishRemote`'s `_cancelRemoteBestEffort`),
`lib/home_screen.dart` (`_transferSubtitle` for `partial`, `_canRetry`),
`lib/net_server.dart` (`_cancel` → `_abort`), SPEC 3.3, SPEC 5.5,
`test/finish_response_test.dart`.

**Current behavior and reproduction:** When every file was verified but `finish`
fails — a refused status, a timeout waiting for the answer, a dropped
connection, an oversized body — `_finishRemote` logs the failure, sets
`transfer.error`, sends a best-effort `cancel`, and returns false. `send` then
sets `partial` even though `failedCount` is 0. The row renders
`Sent 3/3, failed: 0 — HTTP 409`: a status that means "some files did not make
it" over numbers that say they all did. `_canRetry` needs a file with
`!done`, so there is no Retry button either — the row states a problem and
offers nothing.

On the other end the best-effort `cancel` is accepted whenever the receiver is
not already in `finishing`, so its own row goes to `Cancelled` with
"Cancelled by the sender" while its receive folder holds every file. SPEC 3.3
promises both sides see the same thing.

Second-order, and worth deciding explicitly rather than leaving implicit: when
`move` is on, the sources of all those delivered files are deleted immediately
after that `cancel` was sent. Each of them did get a `200` from `verify`, so the
deletion satisfies SPEC 3.1 as written — but it is safe only because the
receiver's cancel path happens not to roll back published files. That coupling
belongs in a comment at the deletion site whichever way this finding is fixed.

**Root cause:** `finish` failure was mapped onto the nearest existing status
instead of being given the terminal error SPEC 5.5 asks for, and the compensating
`cancel` was not matched with anything that keeps the receiver's row truthful.

**Required outcome:** A failed `finish` with no failed files must present as a
terminal error, not as a partial success: the row must state that the receiver
never confirmed the transfer, carry the error it already has, and its numbers
must not contradict its status. Decide and document what the receiver's row says
in this case — a session cancelled after every file was published is not the
same event as a user cancelling mid-transfer, and the log already has the
material to say so.

**Constraints:** Keep the best-effort `cancel` (SPEC 5.5) and keep the receiver
free to refuse a cancel while `finishing`. Keep `partial` meaning "some files did
not arrive" for the case it was made for. Do not resurrect the pre-`fc535fa`
behaviour of reporting a failed finish as `done`. Published files stay published
whatever happens. New strings go into all three locales.

**Tests to add:** In `test/finish_response_test.dart`: a send where every file
verifies but `finish` answers 500 must end in the terminal error status, carry a
non-null `error`, and produce a row subtitle that does not claim a partial
outcome; a send where one file failed *and* `finish` fails must still say so;
the receiver's session after such a cancel must keep its published files and
report the outcome the fix settles on.

---

### 8. P2 [FIXED afbaaef] — Files copied into the cache by the picker are never deleted, and a Move deletes the copy instead of the user's file

**Affected components:**
`android/app/src/main/kotlin/a/a/easysend/MainActivity.kt` (`copyToCache`,
`resolveToPath`), `lib/net_sender.dart` (`_deleteSource`), `lib/home_screen.dart`
(`_addShared`, `_pickFiles`), SPEC 3.1, SPEC 7.

**Current behavior and reproduction:** `resolveToPath` returns a real path only
for documents on primary external storage under the
`com.android.externalstorage.documents` authority. Everything else — a provider
that only exposes a stream — goes through `copyToCache`, which writes a full copy
into `cacheDir/picked/<display name>` and hands Dart that path. Nothing in the
app ever deletes that directory: grep for `picked` finds exactly one occurrence,
the one that creates it. Sending a 2 GB video from a cloud or gallery provider
leaves a 2 GB copy behind, and repeated picks accumulate until Android decides
to reclaim the cache.

The second half is worse. `_deleteSource` deletes `item.sourcePath` — for those
picks, the cache copy. The user ticks "Delete originals", the transfer succeeds,
the log says `Deleted here`, and the file the user actually meant is untouched.
The same applies to anything arriving through the share menu whose plugin hands
back a cache path.

Confidence: the cache growth and the "the deleted path is the copy" mechanics are
certain code facts. *How often* a pick lands on the copy path rather than the
primary-storage path is an empirical question about which providers a given phone
uses — verify on a device before sizing the fix.

**Root cause:** A temporary working copy is given the same standing as a user
file. It is never cleaned up, and it is treated as deletable by a feature whose
entire promise is that it deletes the original.

**Required outcome:** Two separate things. First, copies made by
`copyToCache` must be cleaned up — at the latest when the app starts, and
ideally once the transfer that used them ends. Second, a file whose source is
one of those copies must never be offered as a Move: either the tick refuses
such a batch with a sentence, or the deletion is skipped for it and the log says
plainly that the original was not ours to delete. Silently deleting a copy and
reporting `Deleted here` is the one outcome that must not remain.

**Constraints:** Keep the primary-storage fast path that avoids copying
altogether — it is why `resolveToPath` exists. Keep the picker working across an
Activity destruction (the whole reason `pickFiles` is native). Do not delete a
cache copy while a transfer is still streaming it. Any new user-facing string
goes into all three locales, punctuation in code.

**Tests to add:** Dart-side, in `test/move_after_send_test.dart`: a `FileItem`
whose `sourcePath` is marked as a temporary copy must not be deleted by the move,
and must log the "not deleted" line instead. Kotlin has no test harness here, so
state the cache-cleanup behaviour in `SPEC.md` 7 and verify it by hand on a
device.

---

### 9. P3 [FIXED 3ce4d74] — The receive banner outlives the failure it describes until an unrelated tick repaints the screen

**Affected components:** `lib/net_server.dart` (`start()`, the
`if (running && boundPort == currentPort)` early return that clears
`readinessFailure` and `readinessError` without calling `serverStateChanged()`),
`lib/home_screen.dart` (`_netTicks`, `_buildReceiveBanner`),
`test/receive_readiness_test.dart`.

**Current behavior and reproduction:** Every other path out of `start()` ends in
`serverStateChanged()`; this one does not. So when a transition fails somewhere
other than the listener — `noteTransitionFailure()` sets
`ReceiveReadinessFailure.transition` and paints the banner — and the next
transition succeeds while the HTTP server is still bound to the same port, the
failure is cleared in the model but nothing tells the screen. The banner stays up
until some other listenable fires. In practice `DiscoveryService._tick` calls
`devicesChanged()` every 5 s and `_netTicks` merges it, so the banner clears
within about five seconds; with discovery stopped it can persist much longer.

**Root cause:** One early return out of a state-changing method skips the
notification the other returns make. A stale banner is exactly the failure mode
tofix4 finding 11 was written to prevent.

**Required outcome:** Any change to `readinessFailure` / `readinessError` must
notify, including the already-bound early return. The cheapest correct shape is
to notify only when the value actually changed, so a resume that finds
everything already fine does not bump the tick on every lifecycle event.

**Constraints:** Do not rebind a server that is already listening on the right
port — that early return exists to keep an incoming transfer alive across a
resume, and must stay. Do not make `serverStateChanged()` fire unconditionally
on every `start()`.

**Tests to add:** In `test/receive_readiness_test.dart`: after
`noteTransitionFailure()`, a `start()` that takes the already-bound path must
clear the failure *and* bump `serverTick`; a `start()` that changes nothing must
not bump it.

---

### 10. P3 [FIXED 309f884] — A successful Retry leaves the retried files sitting in the selection

**Affected components:** `lib/home_screen.dart` (`_retryTransfer`,
`_pruneSentFiles`), `lib/file_helpers.dart` (`restoreFileSnapshot` mints new
`FileItem` ids), SPEC 3.3, SPEC 5.6.1.

**Current behavior and reproduction:** `_pruneSentFiles` clears the selection by
identity — it removes the `FileItem` objects that the send marked `done`, which
works because `_send` passes the very objects held in `_selected`. `_retryTransfer`
instead rebuilds the batch through `restoreFileSnapshot`, which mints fresh
`FileItem`s with new ids. Those are the objects the retry marks `done`; the
originals still in `_selected` keep `done == false` and stay in the list. After
a retry that delivers everything, the main screen still shows the files as
waiting to be sent, and pressing Send sends them a second time.

**Root cause:** Two paths clear the selection by two different rules — object
identity in one, nothing at all in the other — for the same underlying question,
"has this file reached the peer".

**Required outcome:** A file the peer has confirmed must leave the selection
whichever path delivered it. Match on what identifies a picked file across a
rebuild — its source path — rather than on object identity, in the one place
that prunes.

**Constraints:** Do not clear the selection after a *failed* or *cancelled*
retry: SPEC keeps the failed files in the list precisely so they can be tried
again. Keep Retry itself never deleting sources (SPEC 3.1). Keep `_lastSent`
and the Restore button behaving as they do.

**Tests to add:** A widget-free test over the pruning rule, extracted from
`_pruneSentFiles` into a pure function so it can be reached: given a selection
and a finished transfer whose delivered items share source paths but not ids,
the delivered ones are removed and the failed ones stay.

---

### 11. P3 — Nothing ever builds `HomeScreen`, so every rule is tested and none of the wiring is

**Affected components:** `test/` as a whole; `lib/home_screen.dart`
(`_syncManualPolling`, `_dropDelivered`, `_pruneSentFiles`,
`didChangeAppLifecycleState`, `_applyNetworkState`, `_exitApp`,
`_handleAndroidServiceState`); `lib/settings_screen.dart` (`_receiving`,
`_editRecvFolder`). Existing widget-test harness to copy:
`test/accept_dialog_test.dart`, `test/refused_names_dialog_test.dart`.

**Current behavior and reproduction:** The suite tests rules and real servers.
Widget tests exist, but only two, and both pump a bare `MaterialApp` host to
exercise a dialog function — `grep -rn HomeScreen test/` returns nothing at all.
Neither `HomeScreen` nor `SettingsScreen` is ever built.

Everything those screens decide has therefore been pushed out into pure
functions that tests can reach — `networkDesiredFor`, `lifecycleNetworkDecision`,
`manualPollingWanted`, `sendButtonMode`, `sortPickedFiles`, `withoutDelivered`,
`receiveBannerText` — and every one of them is well covered. What no test touches
is whether the screen calls them, calls them with the right arguments, or calls
them at all. Four fixes in this very audit landed in exactly that state: finding
3's rule is proven, but that `didChangeAppLifecycleState` invokes
`_syncManualPolling` is not; finding 5's `receiveSlotHeld` is proven, but that
`_editRecvFolder` reads it is not; finding 9's notification is proven, but that
the banner is rebuilt from `serverTick` is not; finding 10's `withoutDelivered`
is proven, but that `_retryTransfer` calls it afterwards is not.

A deletion of any one of those call sites would leave the whole suite green.

**Root cause:** `HomeScreen.initState` starts the network, subscribes to the
share intent stream and attaches the Android service, all of which reach the
platform, so building it in a test needs those edges stubbed — and no harness for
that exists. The pure-function habit is right and should stay; it has simply been
carrying the whole burden, and it cannot carry this part.

**Required outcome:** A harness that pumps `HomeScreen` with its platform edges
stubbed — method channels answered by fakes, `ReceiveServer`/`DiscoveryService`/
`ManualPoller`/`SendService` replaceable — and a small number of tests that
assert the wiring rather than the rules. The point is not coverage of the widget
tree; it is that a call site cannot be deleted without something going red.

**Constraints:** Keep the pure functions and their tests exactly as they are —
this is in addition, not instead. Do not add test seams to production code beyond
the `@visibleForTesting` fields already used for `askUser`, `notifyFinished` and
`pickedCopiesRootOf`; the singletons (`receiveServer`, `discovery`,
`manualPoller`, `sender`) are the awkward part and may need injecting, which is a
design change worth its own decision. The app must start identically. Do not make
these tests depend on wall-clock timing.

**Tests to add:** Backgrounding the app stops manual polling and returning to it
starts polling again, with background receiving on — driven through the widget's
own lifecycle callback, not by calling the rule. Opening the receive folder
picker while the receiver's slot is held is refused. A finished retry leaves the
picked list without the files it delivered. Clearing the readiness failure
repaints the banner away. Each of these should fail if its single call site is
removed, which is the check to run when writing them.

---

## Checked and found sound

Recorded so the next audit does not spend the time again:

- Path safety: `sanitizeRelPath` + `resolveInside` + `ensureSafeDestination` +
  `publishVerifiedFile`'s exclusive-create claim hold up against `..`, absolute
  paths, backslashes, reserved names, trailing dot/space, symlinked parents, and
  a name taken between the check and the rename.
- Incomplete-session ownership: the registry under the config directory is
  unreachable from a transfer, `sweepOrphanSessionsOnce()` runs before the
  receive server can open a session (`_applyNetworkState`), and
  `_removeOwnedSessionDirectory` refuses anything that is not a real directory
  under the prefix.
- Progress monotonicity: `noteProgress`'s clamp plus `progressOffsets` keeps the
  bar, speed and ETA monotone across retries on both sides.
- Receive teardown: `stop()` closes the listener with `force: true` *before*
  awaiting the active operation, so a stalled sender cannot hold an exit for the
  idle timeout; `_abort`'s await of `activeOperation` correctly sequences
  publication before cleanup.
- Settings persistence: the temp-file + rename transaction, the Windows
  two-rename fallback with its `.old` recovery, and `_validSetting` /
  `_validDevice` rejection of every stored key.
- `SerialQueue` swallowing failures rather than poisoning its tail, and the
  `_networkEpoch` / `_stillWantsNetwork` protocol around abandoned transitions.

## Known and deliberately not fixed

- `ADD/tofix4.md` finding 3 (Move can delete a replacement installed after its
  final fingerprint check) remains `[ACCEPTED 2026-08-13]`. Finding 8 above
  touches the same deletion site; keep the two cross-referenced.
- Sender spoofing over UDP and over `prepare` is accepted by SPEC 9. Finding 4
  is filed not as a spoofing problem but because a *declined* request writes
  persistent state.
- Finding 8 covers only the copies EasySend makes itself, under
  `<cache>/picked`. Content arriving through the share menu is copied by
  `receive_sharing_intent` into a directory of its own, which this code does not
  know and did not probe, so a Move of a shared item may still delete a copy
  instead of the user's file. Verify on a device before deciding: if the plugin's
  directory is stable, `isAppOwnedCopy` takes a second root and the rest of
  finding 8 already handles it.
- `ManualPoller.addByAddress` cannot accept an IPv6 literal: `lastIndexOf(':')`
  splits inside the address. SPEC covers IPv4 only, so this is left as is —
  written down here so it is not rediscovered as a bug.
