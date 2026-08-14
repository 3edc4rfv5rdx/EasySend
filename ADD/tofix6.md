# EasySend deep code audit — 2026-08-14

This audit reads `lib/` in full (7,900 lines), the Kotlin under
`android/app/src/main/kotlin/`, `AndroidManifest.xml`, `assets/locales.json` and
the test suite, against `SPEC.md`, `README.md` and the resolved prompts in
`ADD/tofix1.md` … `ADD/tofix5.md`. Findings already filed there are not repeated;
where an earlier repair narrowed a problem without closing it, the remaining
window is stated.

Two findings (1 and 3) were **probed** with a throw-away test driving the real
`ReceiveServer` over HTTP, not merely reasoned about; the probe output is quoted
inside them. Finding 2 rests on documented Android platform behaviour that
cannot be exercised from this machine and says so. Everything else is a code
fact with a file and an expression.

Baseline: commit `a6cca6a` (build 96), working tree clean, 244 tests green.

## System model and invariants

- `HomeScreen` owns the desired network state and serializes every transition
  through `_networkQueue` + `_networkEpoch`. `ReceiveServer`, `SendService`,
  `DiscoveryService` and `ManualPoller` own their own mutable workflows and do
  not know about each other. On Android the Dart isolate lives in an
  `Application`-owned Flutter engine and outlives any Activity.
- A send is prepare → (upload → verify) per file, strictly sequential → finish.
  The receiver holds exactly one consent/session slot and one file operation at a
  time, and tracks a per-file phase (`ready`, `uploading`, `awaitingVerification`,
  `verifying`, `finishing`, `cancelled`). A file becomes real only when its CRC
  matches and it is renamed out of the session's incomplete directory.
- **The two directions are independent.** `SendService` and `ReceiveServer` share
  no state, so this device can be sending to one peer while receiving from
  another, and `xvTransfers` can hold two running sessions at once.
- Untrusted input crosses into the receiver at `/api/v1/*` (manifest paths,
  sizes, ids, names), at UDP discovery (announce/query), and on Android at the
  document picker (display names chosen by another app's provider).
- Persistent state is `settings.json` (settings, manual + trusted devices) and
  the incomplete-session registry under the config directory. Transfers and
  their logs are memory-only by design.

Invariants this audit measured against:

1. Both ends of a transfer describe the same outcome, and neither reports a file
   as lost that the other has published (SPEC 3.3).
2. A retry never creates a second copy of a file that already arrived.
3. A transport failure costs one transfer, never the process (SPEC 7).
4. What the user picked is what gets sent: the bytes that travel under a name are
   the bytes of the file that had that name.
5. Every control the SPEC puts on screen exists, and acts on the object it sits
   next to.
6. A log line names what actually happened, with the code that caused it.

## Findings

### 1. P1 [FIXED bab2525] — A lost `verify` answer makes the two ends disagree, and Retry then plants a duplicate

**Affected components:** `lib/net_sender.dart` `_sendFile` (lines 528–562) and
`_sendOneByOne` (lines 355–387); `lib/net_server.dart` `_upload` (lines 600–610)
and `_verify` (lines 765–777); `lib/home_screen.dart` `_canRetry` /
`_retryTransfer` (lines 1444–1474); SPEC 3.3 ("Обе стороны видят одно и то же"),
SPEC 5.6.1; `test/receive_finish_test.dart`, `test/network_timeout_test.dart`.

**Current behavior and reproduction:** the sender sends a file's body, then a
separate tiny `POST /verify`. If that request is sent and its **answer** is lost
— the read is bounded by `headerTimeout` (5 s) in `_post` — the receiver has
already published the file and marked it done, while the sender takes any
non-200 as a reason to try the whole file again:

```dart
final _ProtocolResponse verify = await _post(_url(peer, 'verify', {...}));
item.crc32 = crc;
if (verify.status == HttpStatus.ok) { ... return _FileResult.sent; }
transfer.log('Checksum did not match', file: item.relativePath, failure: true);
return _FileResult.retry;                       // net_sender.dart:562
```

The retry re-posts `upload`, and the receiver refuses it because the file is
already done:

```dart
if (session.phase != _ReceivePhase.ready || item.done) {   // net_server.dart:600
  ... return _json(req, {'reason': 'out-of-order'}, status: HttpStatus.conflict);
}
```

Probed against the real server (prepare → upload → verify 200 → upload again):

```
PROBE A re-upload -> 409 {reason: out-of-order}
PROBE A file on disk: true
PROBE A finish -> 200, status=TransferStatus.done, done=1, failed=0
```

All three attempts hit the same 409, so `_sendOneByOne` sets `item.failed = true`
and logs `Not sent`. End state: the **receiver** row says `Done: 1`, the
**sender** row says `Sent 0/1, failed: 1` and offers **Retry**. Retry rebuilds
the batch from disk and opens a new session, so the receiver publishes the same
file a second time as `name (1).ext` — `uniquePath` is doing exactly what it
should, with a manifest that should never have been sent.

The same trap catches a lost `upload` **response**: the receiver is then in
`awaitingVerification` for that very file, and the repeated upload is refused by
the same guard, so a file whose bytes all arrived is thrown away and reported as
failed by both ends.

**Root cause:** the receiver's per-file phase is not resynchronizable. `409
out-of-order` is returned for three different situations — a protocol violation,
a file that is already published, and a file waiting to be verified — and the
sender, which reads only the status code, cannot tell the recoverable ones from
the broken one. Invariant 1 and 2 are both unenforced: nothing makes the sender's
per-file verdict agree with the receiver's, and nothing stops a retry duplicating
a published file.

**Required outcome:**

- A repeated `upload` for a file the receiver has **already verified and
  published** is answered distinguishably (a reason the sender can act on, e.g.
  `already-verified`, with a status the sender does not treat as a transport
  failure). The sender counts that file as delivered — the receiver's copy is the
  one that was verified — and does not mark it failed.
- A repeated `upload` for the file the session is currently **awaiting
  verification** for restarts that file: the earlier `.part` is discarded and the
  upload proceeds, so a lost `upload` answer costs one file's bytes and not the
  file.
- A repeated `verify` for a file already published under this session answers
  the same way it answered the first time, so a lost answer is repairable at all.
- The sender acts on the answer's `reason`, not only on the status code. Every
  genuine `out-of-order` stays a failure.

**Constraints:** publication must remain the only thing that makes a file real,
and a re-uploaded file must never replace a published one (SPEC 5.6). A file
verified once and reported delivered must stay eligible for a `move` deletion,
since it did arrive. Progress must stay monotone on both sides (SPEC 3.3): a
restarted file re-walks its own manifest interval and never rewinds the bar.
Nothing here may weaken the refusal of a genuinely out-of-order request from a
misbehaving peer.

**Tests to add:** (a) upload → verify 200 → upload again: the answer identifies
the file as already verified, the published file is untouched, and the transfer
finishes `done` on both sides with `failed: 0` on the sender; (b) upload → (drop
the answer) → upload again: the second upload is accepted, verification succeeds,
and exactly one file lands in the receive folder; (c) a genuine out-of-order
request (verify for a file that was never uploaded) still gets 409; (d) an
end-to-end send whose first `verify` answer is discarded ends with the same
counts on both sides and leaves one file, not two, in the receive folder.

---

### 2. P1 [FIXED 9a0e2e2] — An unguarded `startForeground()` turns a refused foreground service into a process crash

**Affected components:** `android/app/src/main/kotlin/a/a/easysend/TransferService.kt`
`onStartCommand` (lines 59–99) and `startForegroundWith` (lines 101–155);
`lib/android_helpers.dart` `AndroidService._push` (lines 467–508); SPEC 7
("сервис немедленно снимает locks и уведомление и останавливается **без падения
процесса**").

**Current behavior and reproduction:** every start of the service ends in

```kotlin
if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
    startForeground(NOTIFICATION_ID, notification, foregroundType(progress))   // :151
} else {
    startForeground(NOTIFICATION_ID, notification)
}
```

with no `try` anywhere in `onStartCommand`. `startForeground()` is documented to
throw `ForegroundServiceStartNotAllowedException` (API 31+) when the app is no
longer allowed to hold a foreground service at the moment the service calls it,
and `SecurityException` / `InvalidForegroundServiceTypeException` (API 34+) when
the requested type is refused. An exception thrown out of `onStartCommand` kills
the process — mid-transfer, with the receive server, discovery and any partially
written `.part` file going with it.

The caller side is already defended: `EasySendApplication.handle` wraps
`startForegroundService()` in `try/catch (e: Exception)` (lines 65–71) and Dart
turns that into a caught `PlatformException`. The service side has no equivalent,
so the one failure mode that happens *after* the intent is delivered is the one
that is fatal. The Dart guard `if (_dataSyncTimedOut && !appInForeground) return;`
(`android_helpers.dart:419`) narrows the Android 15 quota case but cannot cover a
start that races the app leaving the foreground.

This is **reasoned from documented platform behaviour, not probed**: it needs a
device and a quota state this machine cannot produce. What is a plain code fact
is that there is no handler.

**Root cause:** invariant 3 is unenforced on the native side — a refused
platform request is allowed to escape as an exception instead of being reported.

**Required outcome:** a refused `startForeground()` leaves the app running. The
service releases its locks, drops any notification it managed to post, stops
itself, and tells Dart the same thing `onTimeout` tells it, so `backgroundReady`
turns false, the UI says background readiness is unavailable, and the user's
"Receive in background" intent is preserved (SPEC 7). A transfer in flight is
allowed to continue or is cancelled — pick one and say which — but the process
does not die.

**Constraints:** the `onTimeout` path and its SharedPreferences hand-off must
keep working unchanged. Do not catch so widely that a programming error in
notification building disappears silently — log what was caught. Nothing may
start a foreground service from the background as a "recovery".

**Tests to add:** a Kotlin unit test is not practical for this; add a Dart-side
contract test in `test/android_service_channel_test.dart` asserting that a
`start`/`update` call which the channel answers with a `PlatformException`
leaves `backgroundReady` false and does not throw out of `AndroidService.sync()`,
and record in the finding that the native guard itself is verified by inspection.

---

### 3. P2 [FIXED fc1f2df] — A receive cancelled on the receiving device is never told to the sender

**Affected components:** `lib/net_server.dart` `cancelCurrent` (lines 943–951),
`_abort` (lines 953–978), `_sessionOf` (lines 986–991) and the `_status(req,
HttpStatus.badRequest)` answers in `_upload`/`_verify`/`_finish`/`_cancel`;
`lib/net_sender.dart` `_sendFile` (lines 530–538) and `_sendOneByOne` (lines
347–387); SPEC 3.3 ("Любая из сторон может отменить передачу", "Обе стороны
видят одно и то же").

**Current behavior and reproduction:** pressing Stop on the **receiving** device
calls `receiveServer.cancelCurrent()`, which aborts locally and clears
`_current`. Nothing is sent to the sender. Every later request then falls through
`_sessionOf` returning null and is answered with a bare `400` and an empty body.
Probed:

```
PROBE B after receiver cancel: upload=400 {} verify=400 {} finish=400 {}
```

The sender treats a non-200 upload as a transport hiccup and retries the file
three times before moving to the next one, so a cancelled 3,000-file transfer
costs 9,000 pointless round-trips, 6,000 failure lines in a log capped at 500 —
which then starts dropping non-routine lines and counting them in
`droppedLines` — and a progress bar that keeps advancing over files nobody is
receiving. The same holds for a session that died on the receiver's 60-second
inactivity timeout. The user's own transfer row on the sending side goes on
saying "active" for the whole walk.

**Root cause:** the receiver has no way to say "this session is over" that the
sender can distinguish from "that request was malformed", and the sender has no
terminal reading of any per-file failure. Invariant 1 is unenforced for the one
event both sides are supposed to agree on immediately.

**Required outcome:**

- A request naming a session this receiver no longer has is answered with a
  status and a `reason` that mean exactly that, distinct from a malformed
  request.
- The sender treats that answer as terminal for the whole transfer: it stops the
  queue at once, records why (cancelled by the receiver / session gone), and does
  not retry the file or walk the remaining manifest.
- A receiver-side cancel remains best-effort in the other direction too: nothing
  new may block the receiver's own teardown on reaching the sender.

**Constraints:** a `finish` arriving for a session already published in full must
keep its current meaning (SPEC 5.5 and `ADD/tofix5.md` finding 7 — do not turn
that path into "session gone"). Files already published on the receiver stay
published (SPEC 5.6), and sources already delivered stay eligible for the `move`
rules in `net_sender.dart:166–206`. The sender must still handle a receiver that
answers nothing at all — the existing `SocketException` path.

**Tests to add:** (a) prepare a three-file session, upload one file, call
`server.cancelCurrent()`, then assert the next `upload` carries the
session-gone reason; (b) an end-to-end send whose receiver cancels after the
first file makes exactly one further request, not `3 × remaining`, and ends
`cancelled`/`failed` with a single explanatory log line; (c) the session-gone
answer is not produced for a `finish` on a fully published session.

---

### 4. P2 [FIXED f4b58f3] — Two documents picked under the same display name overwrite each other, and the survivor carries the wrong content

**Affected components:**
`android/app/src/main/kotlin/a/a/easysend/MainActivity.kt` `copyToCache` (lines
144–157) and `displayName` (lines 159–168); `lib/home_screen.dart`
`sortPickedFiles` (lines 180–211); `lib/file_helpers.dart` `pickedCopiesRoot`,
`isAppOwnedCopy` (lines 604–630); SPEC 3.1.

**Current behavior and reproduction:** a document that is not on primary storage
— a cloud provider, an SD card, anything that only exposes a stream — is copied
into the app's cache under the provider's own display name, with no uniquing:

```kotlin
val target = File(cacheDir, "picked").apply { mkdirs() }.let { File(it, name) }
contentResolver.openInputStream(uri)?.use { input ->
    target.outputStream().use { output -> input.copyTo(output) }
}
```

Pick two files called `report.pdf` from two different provider folders in one
multi-select and the second copy overwrites the first. Both entries then come
back with the **same** path, so `sortPickedFiles` folds them:

```dart
final bool newSource = source == null || knownSources.add(source);
...
if (!newSource || !newTarget) { duplicates++; continue; }
```

The user sees "Duplicates skipped: 1", one row in the selection, and sends a file
whose name came from the first document and whose bytes came from the second.
Nothing anywhere says so. A `move` is safe here only by accident: `isAppOwnedCopy`
keeps the app from deleting either original.

**Root cause:** the cache copy uses an attacker-or-provider-chosen name as a
unique key, which it is not. Invariant 4 is unenforced: the identity of a picked
file is its content, and two different documents are given one identity.

**Required outcome:** every copy the picker makes lands on a path of its own, so
two documents with the same display name produce two selection rows with the
content each of them had. The name shown to the user and sent on the wire stays
the document's own display name — the uniqueness belongs to the cache path, not
to the transferred name. Copies stay under the one root `isAppOwnedCopy` and
`sweepPickedCopiesOnce` know about, so a move still refuses to delete them and
the next run still sweeps them.

**Constraints:** `pickedCopiesDirName` is the contract between the Kotlin and
`file_helpers.dart` — whatever layout is chosen must keep `isAppOwnedCopy`
answering true for every copy and `sweepPickedCopiesOnce` deleting all of them.
Two entries that really are the same file on disk must still fold into one
(SPEC 3.1 duplicate handling). A failed copy still returns null and drops that
one document, not the pick.

**Tests to add:** Dart-side, a test that two `FileItem`s with different source
paths and the same relative path are still refused as duplicate targets (current
behaviour, must not regress) and that two entries with different source paths and
different names both survive. Native-side, note in the finding that the collision
is verified by inspection; add an instrumented check only if the project ever
grows one.

---

### 5. P2 — With a transfer running in each direction there is one Stop button and it acts on whichever started first

**Affected components:** `lib/home_screen.dart` `_buildTransferTile` (lines
1403–1421), `_running` (lines 1551–1556), `_stop` (lines 1560–1568),
`sendButtonMode` (lines 124–131); `lib/android_helpers.dart` `_syncNow` (lines
407–413); SPEC 4 п.4 ("Активные передачи — свои и входящие — показываются здесь
же … скорость, оставшееся время **и кнопка отмены**"), SPEC 3.3.

**Current behavior and reproduction:** the receive server accepts a `prepare`
regardless of what `SendService` is doing, so this device can be uploading to one
peer while another peer uploads to it, and both rows show as running. The row
itself carries no cancel control — the slot beside the bar is deliberately empty
while the transfer runs:

```dart
child: t.isRunning
    ? null
    : IconButton( ... icon: Icon(Icons.close ...) ... ),   // home_screen.dart:1406
```

The only control is the bottom button, which resolves the target by taking the
first running transfer in `xvTransfers`:

```dart
TransferSession? get _running {
  for (final TransferSession t in xvTransfers) { if (t.isRunning) return t; }
  return null;
}
```

So with two transfers running the user can stop the older one, and only then the
newer one — with no way to tell from the button which is about to die, and no way
to choose. The Android notification has the same blind spot: `_syncNow` picks the
first running transfer for its title, progress and its own Stop button.

**Root cause:** a control that acts on "the transfer" in a model that allows two.
Invariant 5 is unenforced; SPEC 4 promises a cancel button per row and the code
has one button for the screen.

**Required outcome:** every running transfer row carries its own cancel control
that stops that transfer and nothing else — incoming rows through
`receiveServer.cancelCurrent()`, outgoing through `sender.cancel()`. The bottom
button keeps its current job for the single-transfer case; decide and state what
it does when two are running (stop both, or return to `Send` and leave stopping
to the rows) rather than leaving it to list order. The notification says which
transfer it is describing when more than one is running.

**Constraints:** the row must not shift or resize when the control appears — the
32×24 slot exists for exactly that reason (see the comment at line 1401). A
finished row keeps its ✕ (remove from list), and the two must not be confusable.
Cancelling an incoming transfer must not touch an outgoing one and vice versa.
`sendButtonMode`'s `stopping` state stays: it exists because `sender.busy`
outlives the cancelled status.

**Tests to add:** with one incoming and one outgoing session in `xvTransfers`,
the resolver behind each row's cancel returns that row's own transfer; a pure
function for "what the bottom button does with N running transfers" with cases
for 0, 1 and 2, tested directly (the rule can be named, so it belongs outside
`build()`).

---

### 6. P3 — Every failed `verify` is written into the log as a checksum mismatch, without the code that caused it

**Affected components:** `lib/net_sender.dart` `_sendFile` (lines 556–562);
SPEC 4 ("лог отвечает, что случилось с каждым файлом: принят или нет, **коды
ответов**, причины отказов"); `test/transfer_log_test.dart`.

**Current behavior and reproduction:** the branch that handles a non-200 answer
to `verify` names one specific cause and drops the evidence:

```dart
transfer.log('Checksum did not match', file: item.relativePath, failure: true);
return _FileResult.retry;
```

A `400` (session gone, finding 3), a `409 out-of-order` (finding 1) and a `500`
all read as "Checksum did not match" in the log the user is asked to copy into a
bug report. The neighbouring upload branch does it right —
`detail: 'HTTP ${resp.statusCode}'` at line 534 — so the two halves of the same
function disagree about what a log line owes the reader.

**Root cause:** a message chosen for the expected case is used for every case,
and the one fact that would tell them apart is discarded. Invariant 6.

**Required outcome:** a `409` with the CRC reason still reads "Checksum did not
match"; anything else names the refusal generically and carries the status code
(and the reason from the body, when there is one) in `detail`, exactly as the
upload branch does.

**Constraints:** the message stays a localization key translated at display time
(`TransferEvent.message`), and every new key is added to all three locales in
full (SPEC 8). The `detail` is never translated. Retry counting must not change:
one line per attempt is what tells the reader how many there were.

**Tests to add:** a send whose `verify` answers `500` produces a log line that is
not the checksum message and contains `500`; a send whose `verify` answers `409`
with a CRC reason still produces the checksum message.

---

### 7. P3 — `_dataSyncTimedOut` is cleared before the push that may fail, so lost background readiness reports itself as recovered

**Affected components:** `lib/android_helpers.dart` `_syncNow` (lines 415–438 vs
lines 442–459), `backgroundReady` (line 292); `lib/globals.dart`
`exitKeepsReceiving` (lines 117–123); SPEC 7.

**Current behavior and reproduction:** the two branches of `_syncNow` clear the
timeout flag by different rules. The idle branch waits for evidence:

```dart
// specialUse has no dataSync quota. Once the idle listener is really up, ...
if (_serviceUp) _dataSyncTimedOut = false;      // :458
```

The transfer branch assumes it:

```dart
_dataSyncTimedOut = false;                      // :423
final bool enteringTransfer = !_transferMode;
await _keepScreenOn(true);
...
await _push(... starting: !_serviceUp ...);
```

`_push` swallows both `PlatformException` and `MissingPluginException` and leaves
`_serviceUp` false, so a start that Android refused ends with
`backgroundReady == true` and no service. `exitKeepsReceiving` then lets ✕ close
the screen and "keep receiving" with nothing holding the process up, and the
receiver dies silently a moment later — the exact outcome SPEC 7 wrote that flag
to prevent.

**Root cause:** drift between two branches of one method answering the same
question ("is the foreground service really up?") by different rules.

**Required outcome:** background readiness is restored only by evidence that the
service is up, in both branches. A push that failed leaves the flag as it was.

**Constraints:** the guard at line 419 must keep letting a transfer continue
without the service when the quota is exhausted and the app is off screen — a
refused service is not a reason to stop transferring. The screen wakelock keeps
following the transfer, not the service.

**Tests to add:** in `test/android_service_channel_test.dart`, a transfer sync
whose channel throws leaves `backgroundReady` false; a transfer sync that
succeeds after a timeout restores it; the idle branch keeps its current
behaviour.

---

### 8. P3 — The sender bounds its selection by count and bytes, but never by the size of the manifest it will have to send

**Affected components:** `lib/file_helpers.dart` `selectionLimitBroken` (lines
299–314); `lib/home_screen.dart` `_refuseOverLimit` (lines 676–687);
`lib/net_sender.dart` `_prepare` (lines 282–297); `lib/globals.dart`
`maxPrepareBodyBytes` (line 54); `test/protocol_limits_test.dart:106`.

**Current behavior and reproduction:** the receiver refuses a prepare body over
4 MiB. The sender checks the file count and the total byte size of the payload,
and nothing about the JSON it is about to write. A path may be up to
`maxPathUtf8Bytes` (4096) with up to `maxPathDepth` (64) segments, so 3,000 legal
entries can encode to far more than 4 MiB and come back as a bare
`HTTP 413` — shown to the user as "The receiver refused the transfer: HTTP 413",
which names nothing they can act on. The existing test pins only that a
*realistic* camera-roll manifest fits (`bytes, lessThan(maxPrepareBodyBytes)`).

**Weak by construction, and labelled as such:** this needs deep trees with very
long names — roughly 1,300 characters of path per file averaged over 3,000 files.
It is filed because the check is one line and the failure it prevents is
unreadable, not because it is likely.

**Root cause:** the sender enforces two of the receiver's three admission limits.

**Required outcome:** the selection is refused at pick time, with the reason said
in words, when the manifest it would produce cannot fit the body limit the
receiver enforces. The check lives beside the other two in
`selectionLimitBroken` so all three are asked in one place.

**Constraints:** the check must not serialize the whole manifest on every pick of
a normal folder — measure the encoded length incrementally or bound it by the sum
of path lengths plus a fixed per-entry overhead. `maxPrepareBodyBytes` stays the
one constant both sides read (SPEC 10, no duplication).

**Tests to add:** a selection of legal-but-long paths that would exceed
`maxPrepareBodyBytes` is refused with the size reason; the full realistic
manifest of `protocol_limits_test.dart:106` is still accepted.

---

## Checked and found sound

Recorded so the next audit does not spend the time again:

- Localization: all 162 keys of `assets/locales.json` are translated in both `ru`
  and `ua`; every `lw('…')` literal in `lib/` and every `TransferEvent.message`
  key passed to `.log(` exists in the file. No English placeholders remain.
- The receiver's phase machine is exception-safe on the paths it does cover:
  `_upload`'s and `_verify`'s `finally` blocks restore `ready` and complete
  `activeOperation` exactly once, and `_abort` sequences publication before
  cleanup. Finding 1 is about which situations the phases can *express*, not
  about their bookkeeping.
- `stop()` during `finishing` leaves the outcome alone and `_finish`'s `finally`
  still clears `_current`; the slot is free for the next sender.
- The network state machine: `_setNetworkDesired` only transitions on a real
  change, `_transferBusy` defers a teardown or a port rebind until the sockets
  are idle, and `_pruneSentFiles` re-queues the deferred transition after
  `sender.busy` has already gone false (the sender's `finally` ticks
  `transfersChanged()` last).
- Foreground-service timeout recovery: `reportServiceTimeout` persists the fact
  in SharedPreferences and `_restoreTimeoutAndSync` consumes it on the next
  attach, so a timeout that happened while the process was gone is still
  reported. A timeout the surviving process saw is repaired on the next resume by
  `reassert()` (`specialUse` has no quota), so no user-facing state is left
  claiming a receiver that is not there — apart from finding 7's window.
- Path safety, session-directory ownership, progress monotonicity, settings
  persistence and `SerialQueue` failure isolation were re-checked against the
  same expressions `ADD/tofix5.md` validated; nothing has regressed.

## Known and deliberately not fixed

- **`_touchDevice` rewrites a manual device's address in memory only.**
  `lib/net_discovery.dart:349–356` overwrites `name`, `platform`, `address` and
  `port` of any matching device — manual and trusted ones included — from an
  unauthenticated announce, and never calls `saveSettings()`. Two consequences,
  both accepted: an announce can redirect a trusted device's address, which
  SPEC 9 already concedes for an unencrypted LAN and which grants an attacker
  nothing they could not get by reading the wire; and the refreshed address is
  lost on restart, costing at most one announce interval (5 s) of a device
  showing offline. Cross-referenced from finding 5's neighbourhood: anything that
  starts persisting device state from discovery must revisit the eviction limits
  in `_admitNewPeer`.
- **`sweepPickedCopiesOnce()` is ordered against the network transition, not
  against the first pick.** It runs in `_applyNetworkState` behind
  `await ensureStoragePermission()` (`home_screen.dart:498–524`), which can sit on
  a system permission screen. In theory a document picked before that returns
  could be swept out from under the selection; in practice the permission screen
  is on top of the app, so there is nobody to pick with. Left as is; if the
  storage-permission flow ever becomes non-modal, this becomes real.
- `ADD/tofix4.md` finding 3 (Move can delete a replacement installed after its
  final fingerprint check) remains `[ACCEPTED 2026-08-13]`. Finding 1 above
  touches the same delivered-file bookkeeping: if a file is ever counted as
  delivered on the strength of the receiver's word rather than the sender's own
  200, the fingerprint check in `_deleteSource` is what still has to hold.
- `ManualPoller.addByAddress` cannot accept an IPv6 literal (`lastIndexOf(':')`
  splits inside the address). SPEC covers IPv4 only; carried over from
  `ADD/tofix5.md` so it is not rediscovered as a bug.
- `ADD/tofix5.md` finding 11 (`HomeScreen` itself is never built by any test)
  remains `[ACCEPTED 2026-08-13]`. Findings 5 and 7 above both add rules that
  belong outside `build()` for exactly that reason.
