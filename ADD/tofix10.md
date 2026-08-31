# EasySend — audit of the new work: ZIP, clipboard, conflict modes, screen lock, 2026-08-31

Scope was named by the user: the work that has landed since the last audit —
`ADD/tofix9.md`, commit `46f8260` — that is, everything from `15c4f28` to
`7d51784`:

- sending the batch as one archive (`lib/zip_packer.dart`, `_packBatch` and the
  move bookkeeping in `lib/net_sender.dart`, the ZIP latch in
  `lib/home_screen.dart`);
- a move that no longer hashes (`SourceFingerprint`, `_deleteSource`);
- the clipboard as a file (`clipboard*` in `lib/file_helpers.dart`,
  `_pickClipboard`, `clipboardArrival` and the finish handler in
  `lib/net_server.dart`);
- "Keep the screen on" and the two-owner screen lock (`ScreenWake`);
- what to do with names the receive folder already holds — the three answers,
  the `skip` field, `ConflictMode` end to end.

Every file those touch was read in full, together with `lib/globals.dart`,
`lib/models.dart`, `lib/file_helpers.dart`, `lib/net_server.dart`,
`lib/net_sender.dart`, `lib/home_screen.dart`, `lib/ui_helpers.dart`,
`lib/android_helpers.dart`, `lib/settings_helpers.dart`,
`lib/settings_screen.dart`, `lib/net_discovery.dart`, `lib/main.dart`,
`lib/log_screen.dart`, `lib/control_body.dart` and `assets/locales.json`.

Product contract: `SPEC.md` as of this commit (3.1 the ZIP button and the move,
3.2 conflict modes and the arriving clipboard, 3.3 progress, 5.5 the protocol,
5.6 integrity, 5.7 the receiver's mandatory checks, 7 the screen lock), plus
`README.md`, and `ADD/tofix1.md`…`ADD/tofix9.md`, whose findings are all marked
fixed, accepted or measured. No finding filed there is repeated here; where the
new work reopens a window an earlier repair closed, the finding says which one.

**Not read, and why.** The Kotlin under `android/app/src/main/kotlin/`, the
manifest and every shell script in the root: `git log --since=2026-08-18 --
android/` is empty and no script has changed since `ADD/tofix9.md` read them at
`46f8260`. Nothing in this audit rests on them.

Baseline: working tree clean at `7d51784` (build 133), `flutter test` 449 tests
green, `assets/locales.json` complete in all three locales (192 entries, no gap).

**Probed, not merely reasoned about.** Findings 1, 2 and 3 were driven against a
real `ReceiveServer` over HTTP with a throw-away test; the output is quoted
inside each. Findings 4, 5, 6 and 7 are code facts read off the source, with the
file, the line and the expression named. Finding 7 additionally rests on an
empirical assumption about tap timing and says so in place.

## System model and invariants

- `HomeScreen` owns the selection, the ZIP latch, the move tick, the desired
  network state and the exit. `SendService`, `ReceiveServer`, `DiscoveryService`
  and `ManualPoller` own their own mutable workflows; `ZipPacker` owns one
  spawned isolate for the length of one pack; `ScreenWake` owns the single
  wakelock two independent callers want.
- A send is now: verify the peer's identity → (optionally) pack the whole batch
  into one archive in an isolate → prepare → sequential upload + verify per file
  → finish → (optionally) delete the originals. Packing replaces the session's
  file list with the archive (`repackedAs`), so from that point the session is
  about one file and the picked list is what a move deletes.
- A receive is: prepare (parse → build the destination plan → ask → rebuild the
  plan if the answer was not `copies` → install the session) → upload → verify →
  publish → finish. The receive slot is held from the first byte of prepare
  through the consent question.
- Untrusted input crossing in: the manifest (ids, paths, sizes), the sender's
  name and port, UDP announces — and, new in this work, the `skip` list crossing
  the other way, from receiver to sender.
- Invariants the product depends on:
  1. A file the receiver did not write is never counted as stored, and a move
     never deletes an original whose copy is not on the far side.
  2. A name the user was not asked about is never written over. The three
     answers are about the names the dialog counted, and nothing else.
  3. The picked list is the queue: what got there leaves it, what did not stays.
  4. A transfer the user accepted either runs or fails for a reason the user can
     act on; it does not die on a refusal the receiver's own dialog invited.
  5. The clipboard of the receiving device is only ever written from text that
     actually arrived in this transfer.
  6. Cached state about a platform resource is only committed once the platform
     call that changes it has succeeded (`ADD/tofix6.md` finding 7).

## 1. P1 [FIXED 91bb3fe] — Answering "Replace" writes over every later arrival, not just the names that were counted

**Verdict: real, probed** against the live server (output below).

**Affected components.** `lib/net_server.dart:1062` (`replace: session.mode ==
ConflictMode.replace`), `_verify`; `lib/file_helpers.dart` `publishVerifiedFile`
(the `if (replace)` branch); `SPEC.md` 3.2.3; `test/conflict_modes_test.dart`,
`test/manifest_plan_test.dart`. Reopens the window closed by `ADD/tofix3.md`
finding 2 and narrowed by `ADD/tofix4.md` finding 2.

**Related.** Finding 3 touches the same set — `DestinationPlan.occupied` and what
the receiver does with it. Both fixes want that set carried onto the session
per file, the way `kept` already is; do them in an order that leaves one set of
occupied names, not two.

**Current behavior and reproduction.** The conflict answer is stored on the
session and applied to every file of the manifest:

```dart
replace: session.mode == ConflictMode.replace,
```

`publishVerifiedFile` then takes the `replace` branch for each file, which
renames the verified part straight onto the planned name without the exclusive
create that normally claims it:

```dart
if (replace) {
  if (!await accept(planned)) return null;
  try { await part.rename(planned); return planned; }
```

`File.rename` is a clobbering operation. So for every file of the manifest —
including the ones whose destination was free when the plan was built and which
the dialog therefore never counted — anything that appears at that destination
between prepare and verify is destroyed.

Probed against the live server: a manifest of `asked.txt` (already here, counted,
the user answers Replace) and `latecomer.txt` (free at prepare). After prepare
answered, `latecomer.txt` was created by another writer. Result:

```
PROBE3 verify f1 -> 200 {ok: true}
PROBE3 verify f2 -> 200 {ok: true}
PROBE3 latecomer.txt now: "the new one"
PROBE3 files in folder: [latecomer.txt, asked.txt]
```

The file written after prepare is gone, with no ` (1)` copy beside it. Under any
other answer the same manifest leaves it alone and takes `latecomer (1).txt`,
which is what `test/manifest_plan_test.dart` "a file created in the claim window
keeps its place" pins for the default mode.

**Empirical note.** How often something creates a file at exactly a manifest
destination during one transfer is an assumption, not a measurement. On the
single-user home machine this app is written for it is rare — which is also
what `ADD/tofix4.md` finding 3 accepted for the move. It is filed at P1 anyway
because it is silent destruction of a file the user was never asked about, and
because the two earlier audits closed exactly this window on purpose.

**Root cause.** Invariant 2. `ConflictMode.replace` is a property of the
session, while the question it answers is a property of the individual names the
plan found occupied. The session already carries the per-file set for the other
answer — `_Incoming.kept` — and nothing equivalent for this one.

**Required outcome.** Replacing applies only to the files whose names the plan
counted as occupied and the user was therefore asked about. Every other file of
that same manifest publishes the way it does in `copies` mode: it claims its
name first and steps aside to the next free one if something else already holds
it. A name that was occupied at prepare and is *still* occupied at verify is
still written over in one step, after the checksum, as SPEC 3.2.3 requires.

**Constraints.** The replacement must stay a single `rename`, with no moment in
which neither file exists. The existing fallback — a directory or a refusing
filesystem at the target gives the arriving file a free name rather than losing
it — must survive. `copies` and `keep` must not change at all.

**Tests to add.** A manifest of two files under `ConflictMode.replace`, one name
occupied at prepare and one free; a file is created at the free destination
after prepare answers; that file must still be there afterwards and the arriving
one must land beside it under a free name, while the occupied one is written
over. The test must fail on the current code.

## 2. P2 [FIXED d7ea3fb] — A clipboard the receiver refused to save is pasted anyway, out of the receiver's own old file

**Verdict: real, probed** against the live server (output below).

**Affected components.** `lib/net_server.dart:1124-1129` (the `kept` branch of
`_finish`), `:557` (`file.destinationPath = finalPaths[file.id]`), `:1141`
(`clipboardArrival`), `lib/file_helpers.dart` `copyArrivedClipboard`,
`clipboardArrival`; `SPEC.md` 3.2.3 and 3.2.4; `test/clipboard_send_test.dart`,
`test/conflict_modes_test.dart`.

**Related.** Finding 4 is the same confusion on the sending side: `done` is read
where `done && stored` was meant. Whoever fixes either should read both — the
question "did this file actually land on that disk" now has two answers in two
places, and neither side asks it the same way twice.

**Current behavior and reproduction.** `_prepare` gives every file of the
manifest the destination the plan resolved for it. Under `keep` that destination
is the path of the user's *existing* file:

```dart
for (final FileItem file in files) {
  file.destinationPath = finalPaths[file.id];
}
```

A file whose name was occupied is answered in the `skip` list, so a current
sender never sends it. At finish it is counted as arrived, and its
`destinationPath` is left pointing at the file that was already here:

```dart
if (session.kept.contains(f.id)) {
  f.done = true;
  f.failed = false;
  transfer.log('Already here, not saved', file: f.relativePath);
  continue;
}
```

`clipboardArrival` then finds it — `file.done && isClipboardFile(...)` — and the
receiver reads that pre-existing file into its own clipboard.

Probed: the receiver already holds `clipboard/x.20260831-120000.txt` containing
`OLD TEXT ALREADY HERE`; a sender offers a file of the same name; the user
answers "Keep what is here".

```
PROBE2 prepare -> 200 {sessionId: …, skip: [f1]}
PROBE2 finish -> 200; clipboard read from: …/receive/clipboard/x.20260831-120000.txt
PROBE2 log: [Already here, not saved, Copied to the clipboard]
PROBE2 content that would be pasted: "OLD TEXT ALREADY HERE"
```

Nothing arrived, nothing was written, and the receiving device's clipboard was
replaced with the contents of a file it already had — while the transfer log and
the finished-transfer notification both say "Copied to the clipboard".

The two paths through the same feature disagree: an older sender that sends the
file anyway reaches the `kept` branch of `_verify`, which does
`item.destinationPath = null`, and `copyArrivedClipboard` then refuses it. Only
the new `skip` path leaves the stale path in place.

**Root cause.** Invariant 5. `done` on the receiver has come to mean two
different things — "this file was written here" and "this file needs nothing
further" — and `destinationPath` is only cleared on one of the two paths that
produce the second meaning.

**Required outcome.** A file the receiver deliberately did not write has no
destination of its own on this device: nothing reads it, nothing pastes it,
neither the log line nor the notification tail claims a clipboard was filled.
The file the user chose to keep stays untouched on disk, and their clipboard
keeps whatever was in it.

**Constraints.** A clipboard that really does arrive — under a fresh name, or as
` (1)` in `copies` mode, or written over in `replace` mode — must still be
pasted and still say so. The skipped file must go on counting as arrived for the
progress bar and for `finish` (SPEC 3.2.3): this is about what is read, not
about what is counted.

**Tests to add.** A receive under `ConflictMode.keep` whose only file is a
clipboard name the folder already holds: `copyClipboard` must not be called, the
log must not carry "Copied to the clipboard", and the existing file must be
unchanged. Then the same case in `copies` mode, where the arriving text *is*
pasted, so the fix cannot be a blanket refusal.

## 3. P2 [FIXED 34e80d8] — "Replace" or "Keep" over a name a folder holds refuses the whole transfer with HTTP 400

**Verdict: real, probed** against the live server (output below).

**Affected components.** `lib/net_server.dart:509-524` (the plan rebuilt after
consent and its containment loop), `lib/file_helpers.dart:691-694`
(`ensureSafeDestination`), `buildDestinationPlan`'s non-`copies` branch;
`SPEC.md` 3.2.3; `test/conflict_modes_test.dart`.

**Related.** Finding 1 changes what `occupied` is allowed to authorise; this one
changes what may go into it. A directory or a link must end up in neither the
replaced set nor the kept set, so read both findings before touching
`buildDestinationPlan`.

**Current behavior and reproduction.** The plan built before the question counts
a name as occupied whenever `uniquePath` could not hand it back unchanged — and
a directory or a symlink holds a name exactly as a file does. So the dialog says
"Such files are already here: 1" and offers all three answers. Probed:

```
PROBE4 asked about 1 names; prepare -> 200 {sessionId: …}
```

Once the answer is `replace` or `keep`, the plan is rebuilt to aim at the name
itself, and every destination is put through `ensureSafeDestination`, which
refuses a final component that is a directory or a link:

```dart
if (finalType == FileSystemEntityType.link ||
    finalType == FileSystemEntityType.directory) {
  return false;
}
```

The refusal is thrown as a `DestinationPlanException` and the whole manifest —
every other file in it included — is answered `400`:

```
PROBE1 ConflictMode.replace -> 400 {reason: unsafe filesystem component}
PROBE1 ConflictMode.keep    -> 400 {reason: unsafe filesystem component}
```

The sender shows `Error: HTTP 400` (`_prepare`'s unnamed-refusal branch), which
names nothing the user can act on, and a batch of any size is lost to a single
folder that happens to share a name with one file. The same manifest under
`copies` goes through untouched.

This also makes SPEC 3.2.3 unreachable: it promises that a replacement which
cannot be put on top — "каталог с таким именем, отказ файловой системы" — gives
the arriving file a free name instead. `publishVerifiedFile` implements exactly
that fallback, and prepare refuses the transfer before it can ever run.

**Root cause.** Invariant 4. Two rules answer the same question — "can this
name be the destination of an arriving file?" — by different standards: the plan
treats a directory as an occupied name the user may decide about, and the
containment check treats it as an unsafe destination that voids the manifest.

**Required outcome.** A manifest that only collides with a directory or a link
is accepted under all three answers. Whatever the mode, such a file lands under
a free name — the answer "replace" cannot be honoured against a folder, and
losing the arriving file over it is worse than renaming it. The other files of
the manifest are unaffected either way. Rejecting the manifest outright stays
the answer for what it is meant for: a path that escapes the receive folder.

**Constraints.** The refusal must stay for genuinely unsafe destinations —
`..`, absolute paths, a symlinked intermediate directory pointing outside the
root — which is what `ADD/tofix1.md` findings 1 and 2 put there. Nothing may be
written through a link. `copies` mode must keep behaving exactly as it does now.

**Tests to add.** A receive whose manifest names a file that a directory already
holds, driven through all three answers: each must give `200` for prepare, and
the file must arrive under a free name with the directory untouched. A second
case with a symlink at the destination, which must still never be written
through.

## 4. P2 [FIXED 9b9e825] — A ZIP batch the receiver kept its own copy of still empties the picked list

**Verdict: real**, read off the source; not probed — it needs a peer that
answers `stored: false` to a ZIP send, which is a test to write rather than a
probe to run. `test/zip_send_test.dart:151` ("the picked files count as
delivered") covers only the stored case, and `test/move_after_send_test.dart:291`
covers `stored: false` for a plain send, so nothing existing contradicts it.

**Affected components.** `lib/net_sender.dart:220-224` (the post-send marking of
the picked items) against `:232-241` (the move's `delivered` list),
`lib/home_screen.dart` `_pruneSentFiles`; `SPEC.md` 3.1.5 and 3.2.3;
`test/zip_send_test.dart`, `test/move_after_send_test.dart`.

**Related.** Finding 5 is a second defect in the very same four lines, and
finding 2 is the same `done`-versus-`stored` confusion on the receiving side.
Fix 4 and 5 together or the second one will rewrite the first one's lines.

**Current behavior and reproduction.** A file the receiver asked not to be sent
is marked delivered but not stored:

```dart
item.done = true;
item.failed = false;
item.stored = false;
```

For a ZIP send the session holds exactly one file, the archive. If the receiver
already has a file of that name — `Photos.zip` from the same folder sent as an
archive before, which is the ordinary way to reach this — and the user answers
"Keep what is here", that one file comes back `done` and `stored == false`.

The picked list is then pruned on `done` alone:

```dart
if (asZip && transfer.files.every((FileItem item) => item.done)) {
  for (final FileItem item in files) {
    if (!item.failed) item.done = true;
  }
}
```

Every picked file is marked done, `_pruneSentFiles` drops the lot, and the row
reads as a clean send — over a receiver that wrote nothing at all. Ten lines
below, the move gets the same question right:

```dart
? (transfer.files.every((FileItem item) => item.done && item.stored)
```

so the originals are correctly left alone; only the queue is emptied.

**Root cause.** Invariant 3. Two consumers of the same outcome ask different
questions of it, and the one that decides what stays in the queue forgot the
half of the answer the protocol added.

**Required outcome.** When the far end did not store the archive, the batch that
went into it stays in the picked list, exactly as it does after a cancelled or
failed ZIP send: nothing got there, so the queue still holds it. The transfer
row and log still say what happened — the archive was not saved because that
name is taken over there.

**Constraints.** A ZIP send the receiver did store must go on clearing the whole
batch from the list (that is what those lines were added for), and a file that
could not be packed must go on staying in it. The move's own behaviour must not
change.

**Tests to add.** A ZIP send whose archive comes back `stored: false`: the
picked list must still hold every file of the batch afterwards, and no original
may be deleted under a move. The existing "a delivered archive empties the list"
case must keep passing.

## 5. P3 [FIXED d44902d] — A file left `failed` by an earlier send is delivered inside an archive and stays in the picked list

**Verdict: real**, read off the source; not probed. The data-flow claim rests on
`grep` over the whole of `lib/`: the only writes to `FileItem.failed` on the
sending side are `net_sender.dart:388` (sets true, never clears) and `:660`
(assigns per file, and the ZIP path does not reach it).

**Affected components.** `lib/net_sender.dart:222` (`if (!item.failed) item.done
= true;`), `:388` (`item?.failed = true` in `_packBatch`), `:660`
(`item.failed = !item.done` in `_sendOneByOne`); `lib/home_screen.dart`
`_pruneSentFiles`.

**Related.** Finding 4 rewrites the same block; take them as one piece of work.

**Current behavior and reproduction.** `FileItem.failed` is a field of the
picked item, and the sender writes it on the caller's own objects — the session
copies the list, not the items. Nothing ever clears it at the start of a send:
`grep` over `lib/` finds exactly one place that sets it true on the sending side
(`_packBatch`) and one that assigns it per file (`_sendOneByOne`), which the ZIP
path does not go through.

So: a plain send in which `report.pdf` fails leaves `report.pdf.failed == true`
in the picked list, which is what keeps it in the queue. The user presses ZIP and
Send again. The file packs and travels inside the archive, the archive is
delivered — and the marking loop skips it because its `failed` flag is still
standing from the previous attempt. It stays in the list, and the next Send
sends it to the same device a second time.

The same happens after a pack that could not read one file, once the reason it
could not be read is gone.

**Root cause.** State that describes one attempt outliving that attempt: `failed`
is per-transfer news kept on a per-selection object, and only the plain path
happens to overwrite it every time.

**Required outcome.** What a send says about a picked file describes that send.
A file delivered inside the archive leaves the picked list whatever an earlier
attempt said about it; a file that could not be packed in *this* attempt stays.

**Constraints.** A file that genuinely failed this time must still stay in the
list, and the pruning must go on ignoring files delivered by an unrelated
transfer (`withoutDelivered` is scoped to one batch on purpose — `ADD/tofix5.md`
finding 10).

**Tests to add.** Mark a picked item `failed`, then run a successful ZIP send
over a batch containing it, and assert that it is marked delivered and leaves the
list. A pack that skips a file in the current attempt must still leave that one
behind.

## 6. P3 [FIXED 4d99c25] — The screen lock records the state it wanted before the call that may refuse it

**Verdict: real**, read off the source; not probed — the failing platform call
cannot be produced from this desktop, and the claim is about the assignment
order, which is visible in the expression below.

**Affected components.** `lib/android_helpers.dart:626-635` (`ScreenWake._apply`);
`test/screen_wake_test.dart`. The same shape as `ADD/tofix6.md` finding 7, which
was fixed for `_dataSyncTimedOut`.

**Current behavior and reproduction.**

```dart
final bool wanted = _transfer || _openApp;
if (wanted == _held) return;
_held = wanted;
try {
  await WakelockPlus.toggle(enable: wanted);
} catch (e) {
  myPrint('wakelock failed: $e');
}
```

`_held` is committed before the platform call, and the failure is swallowed —
into `myPrint`, which is compiled out of the release builds this project ships.
The cached state then disagrees with the device, and because every later call
returns early on `wanted == _held`, nothing ever tries again. A release that
fails leaves the screen held awake for the rest of the run with both owners
believing they let go; an acquire that fails leaves a transfer running under the
lock-screen timeout SPEC 7 says it must not.

**Root cause.** Invariant 6.

**Required outcome.** The remembered state is what the platform actually did.
A call that throws leaves the previous state recorded, so the next request for
the same state tries again rather than being answered from a cache that was
never true.

**Constraints.** The two owners must keep sharing one lock, and neither may take
it from the other (SPEC 7). The rate at which this is called — every lifecycle
event and every transfer tick — means a successful no-op must stay a no-op.

**Tests to add.** A `ScreenWake` whose toggle throws: `held` must still report
the old state, and the next call asking for the same state must reach the
platform again. Existing behaviour with a toggle that succeeds must not change.

## 7. P3 — The Clipboard button can be entered twice and add the same text twice

**Verdict: real as a missing guard, unproven as a symptom.** That nothing
prevents a second entry is a code fact — `onPressed: _pickClipboard` with no
in-flight flag, and four awaits before `_selected` grows. That a real double tap
outruns those awaits is an assumption; see the empirical note below.

**Affected components.** `lib/home_screen.dart:815` (`_pickClipboard`), `:1341`
(the button that calls it); `lib/file_helpers.dart` `clipboardAlreadyPicked`,
`writeClipboardFile`; `test/clipboard_send_test.dart`.

**Current behavior and reproduction.** `_pickClipboard` is handed straight to
`OutlinedButton.onPressed` with nothing guarding a second entry, and it awaits
four times before the selection grows: the clipboard read (a platform channel
round trip), `clipboardAlreadyPicked` (which reads files off disk), the write,
and `collectFiles`. A second press inside that window asks
`clipboardAlreadyPicked` against a selection the first press has not added to
yet, so the duplicate check answers no; `writeClipboardFile` then walks the stamp
a second forward to avoid the name it just wrote, and the same text lands in the
selection twice, travels twice, and stays in the clipboard folder for good —
which is exactly what commit `1a81ccf` set out to prevent, by a route that
commit does not cover.

The File and Folder buttons cannot be entered twice: both open modal system UI.
The Clipboard button shows nothing at all until the row appears, which is what
makes a second press natural.

**Empirical note.** Whether an ordinary double tap outruns those four awaits
depends on the device: the work is a few platform round trips and two or three
small file operations, plausibly tens of milliseconds, against a double tap of
roughly 100–250 ms. It has not been reproduced on hardware — this desktop is not
the phone the button is pressed on. The defect is that nothing prevents it, not
a measurement of how often it happens.

**Root cause.** A check-then-act over a shared list, with the check reading state
the act has not yet written.

**Required outcome.** However many times the button is pressed while one press is
still working, one clipboard is added. The user is told the same "Duplicates
skipped" for the second press that a genuinely repeated clipboard gets, or
nothing at all — a second press must not produce a second file, a second entry
or a second transfer.

**Constraints.** Genuinely different text must still be admitted as a second
clipboard, one press after another (SPEC 3.1.1). The button must not be left
disabled if the work fails or the user backs out.

**Tests to add.** Drive two `_pickClipboard` calls whose awaits interleave — the
rule is worth lifting out of the widget so a test can reach it, the way
`sortPickedFiles` and `sendsAsZip` already are — and assert one file on disk and
one item in the selection.

## What was read and found sound

Listed so the next pass does not spend the time again.

- **`ZipPacker` and `_packWorker`.** The isolate contract holds on every exit
  path: `onExit`/`onError` both feed the same port, a cancel that arrives before
  the spawn returns still kills the isolate, `_finish` completes the pending
  future exactly once, and a killed pack is reported as cancelled rather than
  failed. Fingerprints are removed again for a file that threw after its stat.
  `zipStoresAsIs` keeps a video out of the in-memory deflate, as SPEC 3.1.2 asks.
  Two entries can never share a name inside the archive: `targetKey` already
  refuses a selection that would.
- **The move without a hash.** `SourceFingerprint.matches` compares type, size,
  both timestamps and the mode, taken in the same place for both paths — the
  upload's own `stat` and the packer's. The one remaining window is the one
  `ADD/tofix4.md` finding 3 accepted, and it has not widened.
- **The `skip` protocol.** Bounded and shape-checked on the way in
  (`whereType<String>()`), applied by id, and honoured identically by both the
  move (`item.stored`) and the receiver's `finish`. An older sender that does not
  know the field still ends up with the same outcome by the `_verify` route, and
  an older receiver that does not send it costs only wire.
- **The consent question with three answers.** The timeout is started outside the
  builder, so a rebuild cannot leave a second deadline behind; `cancelled` and
  the 60 s timer both close it with the safe answer; a trusted sender is asked
  about names without the trust row, and silently accepted when there is nothing
  to ask (SPEC 3.2.3); the notification path deliberately keeps `copies`.
- **`_prepare` after the question.** Generation and outgoing-transfer checks are
  both re-asked after the await, and the `finally` only releases the slot it
  still owns.
- **Locales.** All 192 entries carry `ru` and `ua`; the new strings of this work
  — the three conflict answers, the clipboard lines, the packing and deleting
  states — are complete, and the existing coverage test walks them.
- **The screen-lock ownership rule itself.** Two owners, one lock, released only
  when neither wants it; the setting is applied at once from the settings screen
  and only while the app is in front. Finding 6 is about the bookkeeping around
  it, not the rule.
- **Progress across skipped files.** Checked because the manifest offsets look
  like they could stall the bar for a file nobody sends; they do not — the offset
  of the following file credits the skipped one, and a skipped last file is
  followed immediately by `finish`. The hypothesis was dropped, not softened.
