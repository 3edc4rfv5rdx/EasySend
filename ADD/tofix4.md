# EasySend deep code audit — 2026-08-12

This post-fix audit treats `README.md`, `SPEC.md`, the executable tests, the
locked Flutter/Android toolchain, and current runtime code as the product
contract. It does not repeat the resolved prompts in `ADD/tofix1.md` through
`ADD/tofix3.md`; where a previous repair still leaves the original invariant
breakable, the narrower remaining failure window is stated explicitly.

## System model and invariants

- `HomeScreen` coordinates selection and desired network lifecycle.
  `ReceiveServer`, `SendService`, `DiscoveryService`, and `ManualPoller` own
  their mutable workflows; Android keeps their Dart isolate in one
  Application-owned engine.
- A send is prepare -> sequential upload -> verify per file -> finish. The
  receiver reserves one consent/session slot and one file operation at a time.
- Untrusted HTTP/UDP data crosses into peer state, consent UI, progress, and
  filesystem writes. Settings and incomplete-session state cross restart
  boundaries. Move crosses the destructive boundary from verified remote
  delivery to local deletion.
- Critical invariants are: recovery deletes only state EasySend actually owns;
  finalization never replaces an unrelated entry; Move deletes only the exact
  object streamed; every name accepted before sending works on every supported
  receiver; declared limits bound work before allocation; terminal operations
  are serialized and exception-safe; and all advertised UI/spec text remains
  true in every locale.

## Findings

### 1. P0 [FIXED fc24945] — A transferred user directory that matches the public recovery marker is deleted at next startup

**Affected components:** `lib/file_helpers.dart`
(`incompleteDirPrefix`, `_incompleteOwnerMagic`,
`ensureIncompleteSessionDirectory`, `cleanupOrphanParts`),
`test/session_recovery_test.dart`, SPEC section 7.

**Current behavior and reproduction:** Transfer a folder containing
`.easysend-incomplete-user-data/.owner`, where `.owner` contains exactly
`EasySend incomplete transfer v1\n`, plus any other files in that directory.
The folder is a legal final user directory. On the next startup,
`cleanupOrphanParts()` sees the public prefix and fixed marker and recursively
deletes the entire directory. A focused audit probe created that shape, added a
user file, called cleanup, and confirmed the user file was deleted. The current
test protects only a lookalike without the marker.

**Root cause:** A forgeable name-and-content convention is treated as proof of
ownership. The new directory scheme avoids confusing a legal filename suffix
with temporary state, but it still cannot distinguish a final user directory
with the same perfectly transferable bytes from a directory EasySend created
for an interrupted session.

**Required outcome:** Startup recovery must delete only incomplete state whose
ownership is established independently of transferable user-controlled names
and contents. A remote manifest must not be able to manufacture something the
next startup classifies as internal state.

**Constraints:** Keep crash cleanup, recursive removal of genuine incomplete
sessions, hidden non-final writes, no symlink following, and CRC-before-final
publication. Do not reserve or reject an otherwise portable user folder name
merely to preserve a filename-based ownership heuristic.

**Acceptance tests:** Receive a folder with the exact current prefix/marker and
assert it survives cleanup byte-for-byte. Repeat with nested lookalikes and
multiple prefix copies. Create genuine interrupted sessions, restart, and
assert only those are removed. Keep the external-symlink cleanup test.

### 2. P0 [FIXED f20f953] — A file created in the last finalization window is still silently overwritten

**Affected components:** `lib/net_server.dart` `_verify`,
`lib/file_helpers.dart` (`ensureSafeDestination`, `uniquePath`), late-collision
tests.

**Current behavior and reproduction:** Prepare and upload `photo.jpg`. Let
`_verify()` finish its `FileSystemEntity.type`, `uniquePath`, and
`ensureSafeDestination` checks, then create a regular file at the selected
destination before line 746 executes. `part.rename(dest)` removes the late file
and replaces it with the incoming bytes. A focused audit probe confirmed this
rename behavior. It is also the documented Dart contract: if a `File.rename`
destination is an existing file or link, that entity is removed first
([Dart API](https://api.dart.dev/dart-io/File/rename.html)). The existing test
creates the collision before `uniquePath()` and therefore misses this final
check-to-rename race.

`uniquePath()` has a second path into the same unsafe primitive: after 9,999
numbered candidates it returns a timestamp name without checking the
filesystem or adding it to `reserved`. A full receive folder or a concurrent
creator can therefore hand finalization an already occupied fallback too.

**Root cause:** The repair rechecks and reallocates names, but publication is
still a check-then-overwriting-rename sequence. Neither the safety check nor
the allocator makes an exclusive filesystem claim that the final operation
honors.

**Required outcome:** Publishing a verified part must have atomic no-clobber
semantics. If the chosen name becomes occupied at any point, preserve that
entry and safely allocate another name or fail the incoming file. Every
allocator return must be checked, reserved, and subject to the same final
no-replace guarantee.

**Constraints:** Preserve same-filesystem atomic publication, whole-manifest
reservation, Windows case folding, the ` (n)` convention, symlink containment,
and successful retries using their planned destination when it remains free.

**Acceptance tests:** Inject a collision immediately before the publication
primitive and assert both files survive. Repeat with a regular file, symlink,
Windows case-only name, two concurrent contenders, and allocator exhaustion
past 9,999 candidates. The pre-existing late-collision test must continue to
pass, but it is not sufficient by itself.

### 3. P0 [ACCEPTED 2026-08-13] — Move can still delete a replacement installed after its final fingerprint check

*Decided not to fix, on the product's threat model: a single-user app on a home
machine, with no hostile local process to win the race. Closing it properly
needs deletion by filesystem identity, which `dart:io` cannot express —
`FileStat` carries no inode and there is no `unlinkat` — so it would mean an FFI
implementation per platform for a window of microseconds. The digest check that
`ADD/tofix3.md` finding 4 added stays as the last guard. Related: finding 2's
publication takes variant A (exclusive create, not `renameat2`) for the same
reason, so both accept the same class of local race.*


**Affected components:** `lib/net_sender.dart` `_deleteSource`, Move tests,
platform-specific filesystem identity support.

**Current behavior and reproduction:** Complete a file with Move enabled. Let
`_deleteSource()` hash the source and finish its second `file.stat()` at lines
330-331. Before `deleteQuietly(file)` deletes the pathname, rename the original
away and install a replacement at the same path. `deleteQuietly()` separately
awaits `exists()` and then calls `delete()` by pathname, so the replacement is
deleted even though it was never streamed. The digest repair closes the much
wider verify-response window covered by `test/move_after_send_test.dart`, but
there is still no identity-preserving delete operation.

**Root cause:** Object validation and pathname deletion remain separate
filesystem operations with asynchronous scheduling points between them. A
cryptographic fingerprint proves what was at the path during validation; it
does not bind the later delete to that same filesystem object.

**Required outcome:** Destructive Move cleanup must delete only the exact
filesystem object that was streamed and fingerprinted. A replacement at any
time before deletion must survive and produce a clear per-file cleanup failure.

**Constraints:** Keep non-cancelled file-level Move behavior, preserve all
sources on cancellation, leave empty directories, never delete a replacement
as cleanup, and keep the remainder of the batch moving. Isolate any native
identity/delete implementation behind a cross-platform tested contract.

**Acceptance tests:** Add a deterministic hook immediately after the final
identity check, replace the path, and assert the replacement survives. Cover
same-size/same-content replacements, renamed hard links where supported,
unchanged originals, missing originals, and Linux/Android/Windows semantics.

### 4. P1 [FIXED fbd6a3e] — Validated Unicode names can exceed Linux and Android filesystem byte limits

**Affected components:** `lib/file_helpers.dart` (`maxPathComponentChars`,
`sanitizeRelPath`, `isPathTooLong`), pick/refusal UI,
`test/file_name_validation_test.dart`, `ADD/tofix2.md` finding 22.

**Current behavior and reproduction:** Pick a Linux file whose component is
255 Cyrillic characters, or send such a manifest from another implementation.
`sanitizeRelPath()` accepts it because Dart `String.length` is 255 UTF-16 code
units. Its UTF-8 name is 510 bytes, so creating it on ext4 fails with
`ENAMETOOLONG`; the audit probe confirmed the sanitizer accepted the value and
the local write threw `FileSystemException`. Linux ext4 directory entries cap a
filename at 255 bytes, not 255 UTF-16 units
([kernel documentation](https://docs.kernel.org/filesystems/ext4/directory.html)).
The existing test asserts the opposite and therefore codifies the failure.

**Root cause:** One cross-platform rule uses the Windows-style UTF-16 unit
limit and incorrectly describes it as ext4's unit too. Whole-path UTF-8 is
bounded, but each component is not bounded in the encoding used by Linux and
typical Android filesystems.

**Required outcome:** A name accepted by the sender and wire validator must be
creatable on every supported destination. Validate every component against all
relevant platform limits (including UTF-8 bytes and Windows UTF-16 units), and
reject it at pick/prepare time with the existing specific long-name UX.

**Constraints:** Preserve international filenames up to the actual portable
boundary, do not truncate or silently rename them, and keep the 4,096-byte
whole relative-path/depth limits.

**Acceptance tests:** Cover ASCII, Cyrillic, CJK, emoji/surrogate pairs, and
combining sequences at one unit below, exactly at, and one unit above each byte
and UTF-16 boundary. For every accepted case, actually create the component on
Linux and exercise Windows-specific validation separately.

### 5. P1 [FIXED 148e806] — Picking a large folder ignores the 3,000-file bound until the whole tree is retained

**Affected components:** `lib/file_helpers.dart` `collectFiles`,
`lib/home_screen.dart` `_addPaths`, folder-pick/share/drop flows.

**Current behavior and reproduction:** Pick or drop a generated tree with
hundreds of thousands of ordinary files (for example, a large dependency or
cache tree). `collectFiles()` recursively walks every entry and appends one
`FileItem` per file. Only after that future returns does `_addPaths()` compare
the list with `maxManifestFiles` and reject it. The declared 3,000-file limit
therefore bounds the network manifest but not the expensive filesystem scan,
memory growth, stats, or wait before the UI can answer.

**Root cause:** Resource enforcement is placed after collection rather than in
the producer. The collector has no maximum, early termination result, progress,
or cancellation path.

**Required outcome:** Stop folder collection as soon as it is known that the
selection cannot fit the remaining file-count or declared-size budget, release
the directory subscription, and report the same clear limit failure without
retaining the rest of the tree.

**Constraints:** Keep recursive folder structure, do not follow links, retain
per-file unreadable-entry handling, and do not silently send an arbitrary first
3,000-file subset as though it were the requested folder.

**Acceptance tests:** Generate a tree far beyond 3,000 entries and assert the
collector stops at a small bounded overrun, returns promptly, and the selection
remains unchanged. Cover an existing partial selection, total-byte overflow,
an error while traversing, cancellation/disposal during collection, and an
ordinary folder exactly at the limit.

### 6. P1 [FIXED 121c712] — Receive finish is neither exception-safe nor serialized against cancel

**Affected components:** `lib/net_server.dart` (`_finish`, `_cancel`, `_abort`),
`lib/android_helpers.dart` `notifyTransferFinished`, terminal state tests.

**Current behavior and reproduction:** On Android in the background, revoke
notification permission or inject a notification-plugin failure after the last
verify and call `/finish`. `_finish()` sets phase `finishing` and the transfer's
terminal status, then awaits `notifyTransferFinished()` before cleanup,
clearing `_current`, or responding. The notification helper does not catch the
failure, so the outer request handler returns 500 while the receive slot remains
in `finishing` until a best-effort sender cancel or the 60-second session timer.

A user pressing Stop while the finish notification is awaited exposes the
same missing serialization: `_cancel()` accepts every phase, `_abort()` marks
the row cancelled and clears `_current`, then `_finish()` can resume, clean and
answer success for the already-cancelled session. A completion notification,
sender outcome, and receiver row can disagree.

**Root cause:** Finish is marked as a phase but not represented by
`activeOperation`, guarded by try/finally, or given one committed state
transition. A fallible side effect occurs before session release, while cancel
has no legal-phase check for `finishing`.

**Required outcome:** Make finish/cancel one serialized terminal decision.
Session cleanup and release must occur exactly once even when notification or
response writing fails, and notification failure must not change verified file
facts or strand readiness. A concurrent cancel must have a deterministic
documented winner and matching outcomes.

**Constraints:** Keep finish responses bounded, notifications best-effort,
verified files intact, cancellation responsive during uploads, and the next
prepare immediately reusable after terminal cleanup.

**Acceptance tests:** Inject notification success, throw, and delay; race local
and remote cancel at each finish await; disconnect the finish client; and fire
the inactivity timer. Assert one terminal status/log, one cleanup, no stale
timer, no misleading completion notification, and immediate acceptance of a
new prepare.

### 7. P2 [FIXED f51cae1] — Repairing backslashes can bypass the total-selection size check

**Affected components:** `lib/home_screen.dart` `_addPaths` and `_addRepaired`,
selection-limit tests.

**Current behavior and reproduction:** Build a selection just below
`maxDeclaredTransferBytes`, then pick a large sparse file whose only invalid
feature is a backslash in its relative name and choose Fix. `_addPaths()` checks
the total using only `picked.fresh`; the refused file is absent. `_addRepaired()`
checks file count but never checks total bytes, so it adds the repaired item and
can create a selection the receiver is guaranteed to reject with `total-size`.

**Root cause:** The repair path duplicates only part of the normal admission
pipeline instead of reusing its complete count-and-size transaction.

**Required outcome:** Every path that adds files must atomically enforce the
same source, destination, component, file-count, per-file-size, and total-size
rules against the current selection.

**Constraints:** Preserve explicit consent before renaming a backslash, do not
drop already selected files, and keep duplicate/refusal counts truthful.

**Acceptance tests:** Repair a file that fits, one that crosses only the total
limit, one that collides after repair, and concurrent add/share events. Assert
the selection is unchanged on whole-operation rejection and never exceeds any
wire limit.

### 8. P2 [FIXED 1efc9eb] — Finish failures show an untranslated marker in Russian and Ukrainian logs

**Affected components:** `lib/net_sender.dart` `_finishRemote`,
`assets/locales.json`, localization coverage.

**Current behavior and reproduction:** Use Russian or Ukrainian, let all files
verify, and make `/finish` return 409, 500, timeout, disconnect, or an oversized
body. `_finishRemote()` logs `The receiver did not finish the transfer`, and
`formatTransferEvent()` passes it to `lw()`. That key is absent from
`assets/locales.json`, so the visible transfer log contains
`(( The receiver did not finish the transfer ))` instead of an explanation in
the selected language.

**Root cause:** The finish-response fix added a user-visible log key without
adding its locale entries, and current locale tests validate existing JSON
entries rather than every literal consumed by `lw()`/`TransferSession.log()`.

**Required outcome:** Add accurate Russian and Ukrainian text and make
localization coverage fail when any static user-visible translation key used by
code is absent or lacks a supported locale.

**Constraints:** Keep raw HTTP/system details untranslated and preserve the
intentional visible marker for genuinely missing dynamic keys.

**Acceptance tests:** Render/copy each finish failure log in `en`, `ru`, and
`ua`; assert the sentence is localized, details remain exact, and a static
code-to-locale key inventory has no omissions.

### 9. P2 [FIXED d0a36cc] — SPEC still promises file opening for a tap that now opens the transfer log

**Affected components:** `SPEC.md` section 7, SPEC section 4,
`README.md`, `lib/home_screen.dart` `_openTransferLog`.

**Current behavior and reproduction:** SPEC section 7 says that clicking a
completed Linux/Windows transfer opens the file or its folder. The current UI,
README, changelog, and SPEC section 4 say a tap on every transfer opens its log,
while the Transfers header opens the receive folder. An implementer following
the platform section can therefore reintroduce the old asymmetric behavior the
log feature deliberately removed.

**Root cause:** The feature change updated the primary UI section but left a
second platform-specific statement unchanged.

**Required outcome:** Reconcile the platform section with the one-log-screen
behavior and identify the receive-folder header as the supported file-manager
entry point.

**Constraints:** This is documentation repair, not authorization to change the
current UI or restore tap-to-open.

**Acceptance tests:** A documentation consistency check or review must find one
unambiguous mapping: transfer-row tap -> log on all platforms; header folder
button -> receive folder.

### 10. P2 [FIXED fc24945] — Changing the receive folder leaves the new one unswept until the app is restarted

*Added 2026-08-13, while verifying the `ADD/tofix3.md` repairs against the
current code. Belongs to the same recovery mechanism as finding 1 above; fix
them in one reading.*

*Resolved by the same commit as finding 1, by a different mechanism than the one
asked for here. Ownership records live in the settings directory and hold an
absolute path, so the startup sweep no longer walks the receive folder at all
and no longer depends on which folder is current: a leftover in a folder that
stopped being the receive folder is deleted at the next start. What is
deliberately not covered is a leftover whose record was lost — a cleared app
data directory, a reinstall, a directory created by another installation. Those
are no longer recognisable as ours, and inventing a marker that would recognise
them is exactly what finding 1 forbids.*

**Affected components:** `lib/file_helpers.dart` (`_orphansSwept`,
`sweepOrphanPartsOnce`, `cleanupOrphanParts`), `lib/home_screen.dart`
`_applyNetworkState`, `test/session_recovery_test.dart`.

**Current behavior and reproduction:** Start the app with the receive folder at
its default. `_applyNetworkState()` calls `sweepOrphanPartsOnce(xvRecvDir)`,
which sets the file-level `_orphansSwept` flag and sweeps that folder. Now point
the receive folder at another directory in settings. The restart path runs
`_applyNetworkState()` again with the new `xvRecvDir`, but
`sweepOrphanPartsOnce()` returns immediately because the flag is already set and
does not depend on the directory it was set for. Any incomplete-session
directory a crash left in the new folder — including one left there by an
earlier run of this same app, when that folder was the receive folder — survives
every later transfer and is removed only after the process is restarted.

**Root cause:** The once-per-run guard was written for the cost of the walk, not
for its subject. It records that a sweep happened, not what was swept, so a
changed target is indistinguishable from a repeated call for the same target.

**Required outcome:** Every directory that becomes the receive folder is swept
once per run, and a folder already swept in this run is not walked again. The
guard must key on the resolved directory rather than on a single boolean.

**Constraints:** Keep the walk off the resume path — it must not run on every
return to the foreground — and keep it non-recursive, marker-only, and tolerant
of an unreadable or not-yet-permitted folder. Do not sweep a folder the app has
not been given storage permission for.

**Acceptance tests:** Sweep folder A, switch to folder B holding a genuine
marked incomplete-session directory, and assert it is removed without a restart.
Switch back to A and assert A is not walked a second time. Assert two switches
to the same folder produce one walk. Cover a folder that cannot be listed, and
assert a later switch to a readable folder still sweeps.

### 11. P2 — A failed network transition is silent in a release build and leaves the screen saying nothing went wrong

*Added 2026-08-13, from verifying finding 12 of `ADD/tofix3.md`. That repair is
what makes this visible: the queue no longer freezes, so a failure now passes
without any trace at all.*

**Affected components:** `lib/globals.dart` (`SerialQueue.add`, `myPrint`),
`lib/home_screen.dart` (`_queueNetworkTransition`, `_applyNetworkState`),
`lib/net_server.dart` `start` (`readinessFailure`, `readinessError`),
`test/network_lifecycle_test.dart`.

**Current behavior and reproduction:** Make a step of `_applyNetworkState()`
throw somewhere other than inside `receiveServer.start()` — a failing
`sweepOrphanPartsOnce()`, a throwing `discovery.stop()` during a port restart, a
platform channel error while the app resumes. `SerialQueue.add` catches it and
calls `myPrint`, which follows `kDebugMode` and therefore prints nothing in a
release build; releases are the only builds this project ships. The queue stays
runnable, which is what finding 12 asked for, but the transition did not finish:
discovery may be stopped while the UI still shows the device list it had, or the
receiver may never have started while nothing on screen says so.
`receiveServer.start()` has the only user-visible failure surface there is
(`readinessFailure`/`readinessError` feed the banner), and it covers a busy port
and an unusable folder — not a failure anywhere else in the transition.

**Root cause:** Error handling ends at a logger that is compiled out of the
shipped build, and the state the user reads is derived from a component that
never learned the transition failed. Recovering the queue was treated as the
whole repair, leaving no honest answer to "is this device receiving right now".

**Required outcome:** A network transition that fails must leave the interface
telling the truth: readiness reads as not ready, and the reason reaches the
user through the surface that already exists for the busy-port case. The queue
must still stay runnable, and a later successful transition must clear the
state again.

**Constraints:** Do not show a dialog per failed transition — a transient
lifecycle error must not become a spam of modals; the banner and the readiness
state are the surfaces. Keep the cancelled-epoch path silent: an epoch that was
superseded on purpose is not a failure. Do not make releases log peer addresses
or paths, which is why `myPrint` is compiled out in the first place.

**Acceptance tests:** Inject a throw at each awaited step of
`_applyNetworkState()` and assert readiness reads false, the banner carries a
reason, the queue runs the next transition, and a following successful
transition clears both. Assert a superseded epoch produces no banner. Assert the
existing busy-port and unusable-folder cases still produce exactly one banner
each, and that nothing new is printed in a release build.

## Validation performed

- `./05-Lint.sh`: passed with no analyzer issues.
- `./06-Test.sh`: all 177 tests passed.
- `android/./gradlew :app:compileDebugKotlin`: passed; only upstream/deprecation
  warnings were emitted.
- `bash -n` passed for all numbered build, test, tag, upload, install, and key
  scripts. `git diff --check` passed.
- A temporary focused Flutter test proved three filesystem premises: marker-
  shaped user data is deleted by cleanup, a sanitizer-approved 255-Cyrillic-
  character component fails on this ext4 filesystem, and `File.rename`
  overwrites an occupied destination. The probe was removed afterwards.
- Reconciled the complete repository inventory, README, SPEC, changelog, all
  three previous audit files, Dart/Kotlin sources, protocol and lifecycle tests,
  manifests, Gradle configuration, locale data, and release scripts.
- Confirmed rename replacement semantics against the current official Dart API
  and ext4's 255-byte component limit against Linux kernel documentation.

## Areas not exercised

- No Android hardware/instrumentation run was performed, so notification
  delivery/revocation, Doze, service-type transitions, Activity recreation, and
  Wi-Fi multicast behavior remain device acceptance work.
- Windows runtime no-clobber, file-identity, case-folding, and path behavior were
  inspected but not executed on Windows.
- Linux AppImage packaging and external release upload were inspected and
  syntax-checked but not built or invoked; no external state was changed.
- The large-folder and 9,999-collision cases were established from bounded code
  paths rather than by creating a production-scale fixture during the audit.
